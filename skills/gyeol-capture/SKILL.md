---
name: gyeol-capture
description: Record an orchestrated run (epic/auto/chain implementation, ship, release preparation, hardening) into gyeol episodic memory. Invoke yourself as the final step whenever such a run completes, aborts, or is interrupted. Installed and managed by gyeol; modifies no other skill.
---

# gyeol Run Capture

Why this exists: delegated runs execute through hands (subagents, a second harness) whose experience never reaches episodic memory by itself. The 2026-07 retrospective found 145 unrecorded delegated sessions and 8 false "not started" state claims in `_recent.md`; recording at the moment the run ends, when context is richest, is the fix. This step has the same status as technical reports: part of the run, not optional post-work.

This skill is wired non-invasively: the gyeol session instructions say to follow it at run end **when it is installed** and to skip when it is not. No orchestration skill references it explicitly, so treat the end of any orchestrated run as the trigger, without waiting to be asked.

## When

- After an orchestrated run's final announcement/summary, before ending the turn.
- On abort or interruption: capture what completed so far and mark the cut point explicitly.
- SKIP only when running as a dispatched unit inside a wave/orchestration run (e.g. a wave-runner unit). The orchestrator records the whole run; per-unit entries would duplicate it.

## What to write

1. Append one compressed section to `$GYEOL_HOME/memory/episodes/daily/{YYYY-MM-DD}.md` (create the file with `date`/`sessions` frontmatter if missing):
   - Heading: `## {repo}: {command as invoked} ({outcome})`.
   - 3-8 bullets: units → PRs with merge state, key decisions, defects found, deviations from the plan, open follow-ups.
   - **Verify merge/close states with `gh` at write time; do not write from recall.** A state claim ("merged", "not started", "waiting") written from memory can be false before the day ends, so prefer resolvable facts (PR numbers, states) over judgments.
   - Do not invent introspection for delegated work. Record facts and the reports received; mark reconstructed gaps rather than filling them.
2. Update `$GYEOL_HOME/memory/episodes/_recent.md`:
   - Add a one-line Daily Index entry pointing at the daily log.
   - Reconcile Still Open: add new unresolved items (tagged with source date), remove items this run resolved.
   - Refresh the `last_updated` frontmatter.

## Style

- Match the language of the existing daily logs; keep issue/PR titles in their original language.
- Compressed and factual. The daily log is not a transcript; 3-8 bullets is the target.
