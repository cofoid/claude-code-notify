#!/usr/bin/env python3
"""Describe the request Claude Code is currently blocked on.

Usage: describe-request.py <transcript_path>

The Notification payload only ever says "Claude needs your permission" — it
never names the tool, and a question box is indistinguishable from a tool
approval. The transcript has the detail, but reading it naively is wrong: the
newest tool_use is often the PREVIOUS, already-completed call.

The discriminator is tool_result. Every completed call has one; a call that is
blocked waiting on you does not. So: look at the newest tool_use, and only
describe it if it is still unresolved. Otherwise print nothing and let the
caller fall back to neutral wording.

This matters because a wrong tool name is worse than no tool name — it is
specific, plausible, and believed.

Prints one line, or nothing. Never raises.
"""

import json
import sys

# Enough for the last few turns without reading a multi-MB transcript on every
# notification. Results are written close after their tool_use, so a window this
# size reliably contains both halves of a pair.
TAIL_BYTES = 400_000
MAX_LEN = 140

# Per-tool: which input field actually says what the tool will do.
SALIENT = {
    "Bash": ("description", "command"),
    "Read": ("file_path",),
    "Write": ("file_path",),
    "Edit": ("file_path",),
    "NotebookEdit": ("notebook_path",),
    "Glob": ("pattern",),
    "Grep": ("pattern",),
    "WebFetch": ("url",),
    "WebSearch": ("query",),
    "Task": ("description",),
    "Agent": ("description",),
    "Skill": ("skill",),
}


def scan(path):
    """Return (newest tool_use block, set of resolved tool_use ids)."""
    try:
        with open(path, "rb") as fh:
            try:
                fh.seek(-TAIL_BYTES, 2)
            except OSError:
                fh.seek(0)  # file shorter than the tail window
            chunk = fh.read().decode("utf-8", "replace")
    except OSError:
        return None, set()

    newest, resolved = None, set()
    for line in chunk.splitlines():
        line = line.strip()
        if not line.startswith("{"):
            continue  # a seek mid-file can leave a partial first line
        try:
            row = json.loads(line)
        except ValueError:
            continue
        content = (row.get("message") or {}).get("content")
        if not isinstance(content, list):
            continue
        for block in content:
            if not isinstance(block, dict):
                continue
            if block.get("type") == "tool_use":
                newest = block
            elif block.get("type") == "tool_result":
                resolved.add(block.get("tool_use_id"))
    return newest, resolved


def describe(block):
    name = block.get("name") or "Tool"
    inp = block.get("input") or {}

    # A question box carries its own text, which beats any generic label.
    if name == "AskUserQuestion":
        questions = inp.get("questions") or []
        if questions and isinstance(questions[0], dict):
            q = questions[0]
            text = q.get("question") or q.get("header") or ""
            if text:
                extra = f" (+{len(questions) - 1} more)" if len(questions) > 1 else ""
                return f"{text}{extra}"
        return "Claude has a question"

    for key in SALIENT.get(name, ()):
        value = inp.get(key)
        if isinstance(value, str) and value.strip():
            return f"{name}: {value.strip()}"

    return name


def main():
    if len(sys.argv) < 2:
        return
    newest, resolved = scan(sys.argv[1])
    if not newest:
        return
    # Already finished => it is not what you are being asked about. Say nothing.
    if newest.get("id") in resolved:
        return
    text = " ".join(describe(newest).split())
    if len(text) > MAX_LEN:
        text = text[: MAX_LEN - 1] + "…"
    print(text)


if __name__ == "__main__":
    try:
        main()
    except Exception:
        pass  # degrade to neutral wording rather than break the hook
