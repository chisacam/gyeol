#!/usr/bin/env python3
"""Test scan_pi against synthetic pi session ledgers.

pi's real ledger on any given machine may never exercise the file-editing
path (a session that only reads and runs read-only commands is not
substantive), so the interesting branches are covered here with fixtures
instead of live data.

Runs with a temporary HOME; nothing outside it is touched.

Usage: python3 scripts/test-reconcile-pi.py
"""

from __future__ import annotations

import importlib.util
import json
import os
import tempfile
from datetime import date
from pathlib import Path

HERE = Path(__file__).resolve().parent

spec = importlib.util.spec_from_file_location("rs", HERE / "reconcile-sessions.py")
rs = importlib.util.module_from_spec(spec)
spec.loader.exec_module(rs)

SINCE, UNTIL = date(2026, 1, 1), date(2026, 12, 31)
TS = "2026-06-15T02:00:00.000Z"

passed = failed = 0


def check(label: str, got, want) -> None:
    global passed, failed
    if got == want:
        passed += 1
        print(f"PASS  {label}")
    else:
        failed += 1
        print(f"FAIL  {label} (got {got!r}, want {want!r})")


def session(home: Path, name: str, cwd: str, entries: list[dict]) -> None:
    """Write one pi session file: a header line plus the given entries."""
    d = home / ".pi" / "agent" / "sessions" / "--project--"
    d.mkdir(parents=True, exist_ok=True)
    header = {"type": "session", "version": 3, "id": name, "timestamp": TS, "cwd": cwd}
    lines = [header] + entries
    (d / f"2026-06-15T02-00-00-000Z_{name}.jsonl").write_text(
        "\n".join(json.dumps(e) for e in lines) + "\n", encoding="utf-8"
    )


def user_text(text: str) -> dict:
    return {
        "type": "message",
        "timestamp": TS,
        "message": {"role": "user", "content": [{"type": "text", "text": text}]},
    }


def tool_call(name: str, arguments: dict) -> dict:
    return {
        "type": "message",
        "timestamp": TS,
        "message": {
            "role": "assistant",
            "content": [{"type": "toolCall", "id": "tc1", "name": name, "arguments": arguments}],
        },
    }


def scan(home: Path) -> dict[str, dict]:
    os.environ["HOME"] = str(home)
    return {s["session_id"]: s for s in rs.scan_pi(SINCE, UNTIL)}


def main() -> int:
    original_home = os.environ.get("HOME")
    with tempfile.TemporaryDirectory() as tmp:
        home = Path(tmp)

        session(home, "readonly", "/repo/alpha", [
            user_text("explain this project"),
            tool_call("read", {"path": "README.md"}),
            tool_call("bash", {"command": "git status"}),
        ])
        session(home, "edited", "/repo/beta", [
            user_text("fix the typo"),
            tool_call("edit", {"path": "a.py"}),
        ])
        session(home, "wrote", "/repo/beta", [
            user_text("add a file"),
            tool_call("write", {"path": "b.py"}),
        ])
        session(home, "committed", "/repo/gamma", [
            user_text("ship it"),
            tool_call("bash", {"command": "git commit -m 'ship'"}),
        ])
        session(home, "signalled", "/repo/gamma", [
            user_text("open the PR"),
            tool_call("bash", {"command": "gh pr create"}),
            {"type": "message", "timestamp": TS, "message": {
                "role": "assistant",
                "content": [{"type": "text",
                             "text": "opened https://github.com/o/r/pull/42"}]}},
        ])
        session(home, "injected", "/repo/delta", [
            {"type": "message", "timestamp": TS, "message": {
                "role": "user",
                "content": [{"type": "text",
                             "text": "=== gyeol session bootstrap (MANDATORY) ===\n"
                                     "git commit was mentioned in _recent.md, and so was "
                                     "https://github.com/o/r/pull/99"}]}},
            user_text("what were we doing?"),
        ])

        found = scan(home)

        check("every session in the ledger is scanned", len(found), 6)
        check("the header id is preferred over the filename", "edited" in found, True)
        check("cwd comes from the header", found["edited"]["cwd"], "/repo/beta")
        check("repo is derived from cwd", found["edited"]["repo"], "beta")
        check("the harness is labelled", found["edited"]["harness"], "pi")

        check("a read-only session is not substantive", found["readonly"]["substantive"], False)
        check("an edit tool call is substantive", found["edited"]["substantive"], True)
        check("a write tool call is substantive", found["wrote"]["substantive"], True)
        check("git commit in a shell call is substantive", found["committed"]["substantive"], True)

        check("a PR url is collected as a signal", found["signalled"]["signals"], {"#42"})
        check("the first user turn becomes the summary", found["readonly"]["summary"],
              "explain this project")

        # The injected bootstrap quotes _recent.md. Crediting it would invent both
        # substantiveness and coverage signals the session never earned.
        check("an injected bootstrap does not make a session substantive",
              found["injected"]["substantive"], False)
        check("an injected bootstrap contributes no signals",
              found["injected"]["signals"], set())
        check("an injected bootstrap is not mistaken for the prompt",
              found["injected"]["summary"], "what were we doing?")

        # A ledger that does not exist must not raise.
        os.environ["HOME"] = str(home / "no-such-home")
        check("a missing pi ledger yields nothing", list(rs.scan_pi(SINCE, UNTIL)), [])

    if original_home is not None:
        os.environ["HOME"] = original_home

    print(f"\n{passed} passed, {failed} failed")
    return 1 if failed else 0


if __name__ == "__main__":
    raise SystemExit(main())
