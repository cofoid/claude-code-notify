#!/usr/bin/env python3
"""Post notifications spooled by Claude Code sessions running elsewhere.

Usage: notify-watch.py [--interval SECONDS] [--listen SOCKET] [<spool-path> ...]
       notify-watch.py --self-check

A container has no Notification Center and no route to the host's. What it does
have is a bind-mounted ~/.claude, which is a host directory — so notify.sh
finishes the notification inside the container and appends it there as one JSON
line. This drains those files on the host and hands each line to alert.sh, the
same delivery path a host session uses.

An SSH session has no shared filesystem, so there is nothing to drain. What it
has instead is the connection itself: --listen binds a unix socket that ssh
forwards to the remote (RemoteForward), and the remote writes the same one JSON
line into it. Different transport, identical payload and delivery — which is
the whole reason the notification is finished before it travels.

With --interval it stays resident and polls; without it, it drains once and
exits. Resident is what the launchd agent uses, and the reason is measured:
under WatchPaths + StartInterval=5 the same spool line took 9.4–10.4s to post
across three trials, because launchd will not respawn a job more than once
every ten seconds no matter which of the two is asking. A resident process is
not throttled, and it also retires the open question of whether a write through
a Docker bind mount raises a host FSEvent at all — polling never asks.

Reading is offset-based and never writes to the spool while a container might
be appending to it: the only mutation is a truncate, and only when the file is
both fully consumed and has been untouched for a while.
"""

import json
import os
import select
import socket
import subprocess
import sys
import time

ALERT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "alert.sh")

# Bound the spool. Lines are ~300 bytes, so this is a few hundred notifications
# of slack before a reclaim — high enough that truncating is rare, low enough
# that an unattended week cannot grow the file without limit.
SPOOL_MAX = 256 * 1024

# Only truncate a spool nothing has touched for this long. A container appending
# in the microseconds between the mtime check and the truncate would lose a
# line; requiring the file to be demonstrably idle first makes that vanishingly
# unlikely without a lock the container side would also have to honour.
# ponytail: idle-window heuristic, not a lock. Revisit only if lines go missing.
QUIET_SECONDS = 60

FIELDS = ("title", "subtitle", "message", "sound", "group", "name", "cwd")

# A forwarded socket is a channel into your Notification Center from another
# machine, so it is worth locking down. The DIRECTORY mode is the control that
# matters: ssh(1) warns that "not all operating systems honor the file mode on
# Unix-domain socket files", and bind() honours the umask (0755 in practice, not
# the 0600 ssh itself defaults to). A 0700 parent is enforced everywhere.
SOCKET_DIR_MODE = 0o700
SOCKET_MODE = 0o600


def log(msg):
    print(f"[{time.strftime('%Y-%m-%d %H:%M:%S')}] {msg}", file=sys.stderr, flush=True)


def deliver(rec):
    """Hand one spooled notification to the shared macOS delivery path."""
    subprocess.run([ALERT] + [str(rec.get(f, "")) for f in FIELDS], check=False)


def read_offset(path):
    try:
        with open(path) as fh:
            return int(fh.read().strip() or 0)
    except (OSError, ValueError):
        return 0


def write_offset(path, offset):
    try:
        with open(path, "w") as fh:
            fh.write(str(offset))
    except OSError as exc:
        log(f"could not record offset {path}: {exc}")


def handle(raw, source, deliver_fn=deliver):
    """Deliver one JSON line. Returns 1 if delivered, 0 if it was skipped.

    Shared by both transports so a malformed line is treated the same way
    whether it arrived through a spool file or the SSH socket.
    """
    if not raw.strip():
        return 0
    try:
        rec = json.loads(raw.decode("utf-8", "replace"))
    except ValueError:
        log(f"skipping unparseable line in {source}: {raw[:120]!r}")
        return 0
    # Valid JSON that is not an object (a list, string, number) would raise out
    # of deliver() before the offset is written, so the next poll re-reads the
    # same bytes and redelivers every line before it, once per interval,
    # forever. Skip it like any other bad line.
    if not isinstance(rec, dict):
        log(f"skipping non-object line in {source}: {raw[:120]!r}")
        return 0
    deliver_fn(rec)
    return 1


def drain(spool, deliver_fn=deliver):
    """Deliver every complete unread line in one spool. Returns how many."""
    off_path = spool + ".offset"
    try:
        size = os.path.getsize(spool)
    except OSError:
        return 0  # not created yet: the container has not notified since install

    offset = read_offset(off_path)
    # Shorter than our offset means the file was truncated or replaced under us.
    if offset > size:
        offset = 0

    delivered = 0
    if offset < size:
        with open(spool, "rb") as fh:
            fh.seek(offset)
            data = fh.read()

        # Stop at the last newline. A trailing partial line means we caught a
        # writer mid-append; leaving it unconsumed costs one poll interval and
        # is the only way not to deliver half a notification and then skip the
        # rest of it forever.
        end = data.rfind(b"\n") + 1

        for raw in data[:end].splitlines():
            delivered += handle(raw, spool, deliver_fn)

        offset += end
        write_offset(off_path, offset)

    # Reclaim the file once it is fully read and demonstrably idle.
    if offset == size and size > SPOOL_MAX:
        try:
            if time.time() - os.path.getmtime(spool) > QUIET_SECONDS:
                with open(spool, "w"):
                    pass
                write_offset(off_path, 0)
                log(f"truncated {spool} ({size} bytes, fully consumed)")
        except OSError as exc:
            log(f"could not truncate {spool}: {exc}")

    return delivered


def listen(path):
    """Bind the socket ssh forwards to remote sessions. Returns the listener."""
    directory = os.path.dirname(path) or "."
    os.makedirs(directory, exist_ok=True)
    os.chmod(directory, SOCKET_DIR_MODE)
    # An unclean exit leaves the socket file behind, and bind() on an existing
    # path fails with EADDRINUSE — which would take the watcher down on the
    # first reboot after a crash. Nothing else owns this path, so reclaim it.
    if os.path.exists(path):
        os.unlink(path)
    srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    srv.bind(path)
    os.chmod(path, SOCKET_MODE)
    srv.listen(16)
    return srv


def accept(srv, deliver_fn=deliver):
    """Deliver every complete line from one connection. Returns how many."""
    conn, _ = srv.accept()
    chunks = []
    try:
        while True:
            block = conn.recv(65536)
            if not block:
                break
            chunks.append(block)
    finally:
        conn.close()

    data = b"".join(chunks)
    # Same rule as the spool: stop at the last newline. A remote that died
    # mid-write should not turn into half a notification.
    delivered = 0
    for raw in data[: data.rfind(b"\n") + 1].splitlines():
        delivered += handle(raw, "socket", deliver_fn)
    return delivered


def self_check():
    """Exercise the offset, partial-line, and truncate paths. No notifications."""
    import tempfile

    with tempfile.TemporaryDirectory() as tmp:
        spool = os.path.join(tmp, "notify-spool.jsonl")
        seen = []

        def fake(rec):
            seen.append(rec["title"])

        def append(text):
            with open(spool, "a") as fh:
                fh.write(text)

        # Nothing there yet.
        assert drain(spool, fake) == 0

        # Two complete lines, then nothing new on a second pass.
        append('{"title":"one"}\n{"title":"two"}\n')
        assert drain(spool, fake) == 2, seen
        assert drain(spool, fake) == 0
        assert seen == ["one", "two"], seen

        # A partial line is held back, then delivered once completed.
        append('{"title":"three"')
        assert drain(spool, fake) == 0, seen
        append("}\n")
        assert drain(spool, fake) == 1, seen
        assert seen[-1] == "three", seen

        # A junk line — unparseable, or valid JSON that is not an object — is
        # skipped without stalling the ones after it.
        append('not json\n[1,2]\n"str"\n{"title":"four"}\n')
        assert drain(spool, fake) == 1, seen
        assert seen[-1] == "four", seen

        # Truncation resets the offset rather than skipping past the new content.
        with open(spool, "w"):
            pass
        append('{"title":"five"}\n')
        assert drain(spool, fake) == 1, seen
        assert seen[-1] == "five", seen

        # An oversized, fully-read, idle spool is reclaimed.
        append('{"title":"pad"}\n' + "#" * SPOOL_MAX + "\n")
        drain(spool, fake)
        old = time.time() - QUIET_SECONDS - 5
        os.utime(spool, (old, old))
        drain(spool, fake)
        assert os.path.getsize(spool) == 0, os.path.getsize(spool)
        assert read_offset(spool + ".offset") == 0

        # The SSH transport: same payload, same bad-line handling, and the
        # permissions setup is expected to apply rather than to be pasted.
        sock_path = os.path.join(tmp, "notify.d", "sock")
        srv = listen(sock_path)
        try:
            import stat

            assert stat.S_IMODE(os.stat(sock_path).st_mode) == SOCKET_MODE
            assert (
                stat.S_IMODE(os.stat(os.path.dirname(sock_path)).st_mode)
                == SOCKET_DIR_MODE
            )

            client = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            client.connect(sock_path)
            client.sendall(b'{"title":"six"}\nnot json\n[1,2]\n{"title":"seven"}\n')
            client.close()
            assert select.select([srv], [], [], 5)[0], "listener saw no connection"
            assert accept(srv, fake) == 2, seen
            assert seen[-2:] == ["six", "seven"], seen

            # A rebind over a leftover socket file must not raise: that is the
            # state a crash leaves behind, and it would break every restart.
            listen(sock_path).close()
        finally:
            srv.close()

    print("self-check passed")


def drain_all(spools):
    for spool in spools:
        try:
            drain(spool)
        except Exception as exc:  # one bad spool must not stop the others
            log(f"error draining {spool}: {exc}")


def main():
    args = sys.argv[1:]
    if args and args[0] == "--self-check":
        self_check()
        return

    interval, sock_path = None, None
    while len(args) >= 2 and args[0] in ("--interval", "--listen"):
        if args[0] == "--interval":
            interval = float(args[1])
        else:
            sock_path = args[1]
        args = args[2:]
    if not args and sock_path is None:
        print(__doc__.strip().splitlines()[2], file=sys.stderr)
        sys.exit(2)

    # One-shot drain, for a spool-only invocation with nothing to wait on.
    if interval is None and sock_path is None:
        drain_all(args)
        return
    if interval is None:
        interval = 1.0  # --listen has to stay resident to hold the socket

    srv = listen(sock_path) if sock_path else None
    log(f"watching {len(args)} spool(s) every {interval}s"
        + (f", listening on {sock_path}" if srv else ""))
    try:
        while True:
            drain_all(args)
            if srv is None:
                time.sleep(interval)
                continue
            # select doubles as the sleep: an SSH notification is delivered the
            # moment it arrives instead of waiting out the poll interval, and an
            # idle pass still costs one stat per spool.
            if select.select([srv], [], [], interval)[0]:
                try:
                    accept(srv)
                except OSError as exc:  # one bad connection must not kill the loop
                    log(f"socket error: {exc}")
    finally:
        if srv is not None:
            srv.close()
            try:
                os.unlink(sock_path)
            except OSError:
                pass


if __name__ == "__main__":
    main()
