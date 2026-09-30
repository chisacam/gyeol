#!/usr/bin/env python3
"""Test maintain-recent.py against a synthetic episodes/ directory.

The recent index is a shared `_recent.md` plus one `_recent.{machine}.md` per
machine. What matters is who writes what: this machine prunes its own file and
any pre-split Daily Index left in the shared one, never another machine's file,
and `--active` lists what the bootstrap should emit.

Runs with a temporary GYEOL_HOME; nothing outside it is touched.

Usage: python3 scripts/test-maintain-recent.py
"""

from __future__ import annotations

import contextlib
import importlib.util
import io
import os
import tempfile
from datetime import date, timedelta
from pathlib import Path

HERE = Path(__file__).resolve().parent

spec = importlib.util.spec_from_file_location("mr", HERE / "maintain-recent.py")
mr = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mr)

TODAY = date.today()
FRESH = (TODAY - timedelta(days=1)).isoformat()
STALE = (TODAY - timedelta(days=10)).isoformat()

passed = failed = 0


def check(label: str, got, want) -> None:
    global passed, failed
    if got == want:
        passed += 1
        print(f"PASS  {label}")
    else:
        failed += 1
        print(f"FAIL  {label}\n      got:  {got!r}\n      want: {want!r}")


def machine_file(machine: str, updated: str) -> str:
    return (
        f'---\nlast_updated: "{updated}"\n---\n\n# Recent Activity — {machine}\n\n'
        "## Daily Index (last 7 days)\n\n"
        f"- **{FRESH}**\n  - fresh work → `daily/{FRESH}.{machine}.md`\n"
        f"- **{STALE}**\n  - old work → `daily/{STALE}.{machine}.md`\n"
    )


SHARED = (
    "# Recent Activity\n\n"
    "## Daily Index (last 7 days)\n\n"
    f"- **{STALE}**\n  - pre-split entry → `daily/{STALE}.md`\n\n"
    "## Still Open\n\n### area\n- an open item — *2026-09-01*\n\n"
    f"## Weekly Checkpoint\n\n### Week of {FRESH}\n- Surprised: nothing\n"
)


def run(*argv: str) -> str:
    out = io.StringIO()
    with contextlib.redirect_stdout(out):
        mr.main(list(argv))
    return out.getvalue()


def main() -> int:
    original = os.environ.get("GYEOL_HOME")
    with tempfile.TemporaryDirectory() as tmp:
        os.environ["GYEOL_HOME"] = tmp
        ep = Path(tmp) / "memory" / "episodes"
        ep.mkdir(parents=True)
        (ep / "_recent.md").write_text(SHARED, encoding="utf-8")
        (ep / "_recent.mine.md").write_text(machine_file("mine", FRESH), encoding="utf-8")
        other = machine_file("other", FRESH)
        (ep / "_recent.other.md").write_text(other, encoding="utf-8")
        (ep / "_recent.dormant.md").write_text(machine_file("dormant", STALE), encoding="utf-8")

        check("maintenance prints nothing when nothing is stale or bloated", run("--machine", "mine"), "")

        mine = (ep / "_recent.mine.md").read_text(encoding="utf-8")
        check("this machine's stale entry is pruned", STALE in mine, False)
        check("this machine's fresh entry is kept", FRESH in mine, True)
        check("another machine's file is never written", (ep / "_recent.other.md").read_text(encoding="utf-8"), other)

        shared = (ep / "_recent.md").read_text(encoding="utf-8")
        check("a pre-split Daily Index in the shared file is still pruned", "pre-split entry" in shared, False)
        check("Still Open in the shared file is untouched", "an open item" in shared, True)

        active = [Path(p).name for p in run("--active", "--machine", "mine").split()]
        check("--active lists this machine first, then active others, not dormant ones",
              active, ["_recent.mine.md", "_recent.other.md"])

        # A machine that has not written its file yet still sees the others.
        active = [Path(p).name for p in run("--active", "--machine", "newcomer").split()]
        check("--active without an own file lists the active machines", active, ["_recent.mine.md", "_recent.other.md"])

        # The shared file carries no last_updated after the split; that is not bloat.
        (ep / "_recent.md").write_text("# Recent Activity\n\n## Still Open\n", encoding="utf-8")
        check("a shared file without frontmatter raises no bloat directive", run("--machine", "mine"), "")

        (ep / "_recent.mine.md").write_text('---\nlast_updated: "x"\nnotes: dump\n---\n', encoding="utf-8")
        check("bloat in the machine file is named by that file",
              run("--machine", "mine").startswith("_recent.mine.md maintenance:"), True)

    if original is None:
        os.environ.pop("GYEOL_HOME", None)
    else:
        os.environ["GYEOL_HOME"] = original

    print(f"\n{passed} passed, {failed} failed")
    return 1 if failed else 0


if __name__ == "__main__":
    raise SystemExit(main())
