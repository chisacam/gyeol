#!/usr/bin/env sh
# gyeol Stop hook — enforce daily episode log
#
# Logic:
#   1. If today's daily log exists  -> pass (clean up session flags).
#   2. If session was not substantive (no Write/Edit/git commit)
#      -> pass silently.
#   3. If already nagged once this session -> pass with soft
#      systemMessage reminder (avoid infinite loop).
#   4. Otherwise -> decision: block, with a reason telling Claude to
#      write today's daily log before stopping. Mark session as nagged
#      so subsequent Stops don't loop.
#
# LIMIT (by design): case 1 checks whether *today's daily log exists*, not
# whether *this* session is recorded in it. With parallel sessions across repos
# and harnesses, the first session of the day to write the log satisfies this
# check for every later session, so their work can pass unrecorded. That
# per-session gap is the salience/tool-bias leak the 2026-05 audit found. It is
# intentionally NOT closed here (per-session coverage scanning is costly and
# noisy); the backstop is the periodic, harness-spanning reconcile-sessions.py
# plus monthly-reflection triage. See MEMORY_SYSTEM.md "Coverage Reconciliation".
#
# The gap stops at the machine boundary, though: the log is per-machine
# (`{date}.{machine}.md`), so another machine writing its own log does not
# satisfy this one. Two machines appending to a single dated file is what made
# every same-day log a merge conflict; separate paths cannot conflict.
#
# Input: Stop hook JSON on stdin (contains session_id).

set -eu

GYEOL_HOME="${GYEOL_HOME:-$HOME/.config/gyeol}"

# --- Trust gate ---------------------------------------------------------------
# A provider that may train on what it receives gets no memory. See
# scripts/trust-gate.sh. The fallback keeps the explicit opt-out working on an
# install whose gate script has not arrived yet: a missing file must not read
# as consent.
if [ -f "$GYEOL_HOME/scripts/trust-gate.sh" ]; then
  . "$GYEOL_HOME/scripts/trust-gate.sh"
else
  gyeol_trust_denied() { case "${GYEOL_TRUST:-}" in 0|off|no|deny|false) return 0 ;; *) return 1 ;; esac; }
fi

if gyeol_trust_denied; then
  echo '{}'
  exit 0
fi

# Decision keyword for the blocking JSON payload. Default is "block" which is
# what Claude Code's Stop hook and Codex's Stop hook expect. Gemini CLI's
# AfterAgent hook (the closest pre-exit analog) uses "deny" instead — set
# GYEOL_BLOCK_DECISION=deny in the Gemini hook command.
BLOCK_DECISION="${GYEOL_BLOCK_DECISION:-block}"

# If gyeol is not installed on this machine, no-op.
if [ ! -d "$GYEOL_HOME/memory" ]; then
  echo '{}'
  exit 0
fi

INPUT=$(cat)
SESSION_ID=$(printf '%s' "$INPUT" | jq -r '.session_id // empty')

TODAY=$(date +%Y-%m-%d)

# One log per machine per day. `hostname` is not a machine's name — a VPN
# rewrites it — so the id comes from scripts/machine-id.sh, with a fallback for
# an install that has not received it yet.
if [ -f "$GYEOL_HOME/scripts/machine-id.sh" ]; then
  MACHINE=$(sh "$GYEOL_HOME/scripts/machine-id.sh" 2>/dev/null || echo unknown)
else
  MACHINE=$(hostname -s 2>/dev/null || echo unknown)
fi
[ -n "$MACHINE" ] || MACHINE=unknown

DAILY_LOG="$GYEOL_HOME/memory/episodes/daily/${TODAY}.${MACHINE}.md"
# Written before the split, by this machine, on a day that straddles the change.
LEGACY_LOG="$GYEOL_HOME/memory/episodes/daily/${TODAY}.md"
SUBSTANTIVE_FLAG="/tmp/gyeol_session_${SESSION_ID}.substantive"
RECOVERY_FLAG="/tmp/gyeol_session_${SESSION_ID}.recovery"
NAGGED_FLAG="/tmp/gyeol_session_${SESSION_ID}.nagged"

# Case 1: this machine's daily log exists — clean up and pass. The legacy
# unsuffixed name counts too, so the day the split lands is not logged twice.
if [ -f "$DAILY_LOG" ] || [ -f "$LEGACY_LOG" ]; then
  rm -f "$SUBSTANTIVE_FLAG" "$RECOVERY_FLAG" "$NAGGED_FLAG" 2>/dev/null || true
  echo '{}'
  exit 0
fi

# Case 2: session was not substantive — pass silently.
if [ ! -f "$SUBSTANTIVE_FLAG" ]; then
  echo '{}'
  exit 0
fi

# Build the recovery hint if the recovery flag is set.
RECOVERY_HINT=""
if [ -f "$RECOVERY_FLAG" ]; then
  RECOVERY_HINT=" A git-based recovery event was detected this session (git show HEAD: or git checkout HEAD --). Add an 'Incidents' subsection to the daily log capturing what was recovered, why, and what it taught you — this is exactly the type of save-worthy moment that 2026-04-14 feedback memory warns gets erased by post-recovery relief."
fi

# Case 3: already nagged — soft reminder only.
if [ -f "$NAGGED_FLAG" ]; then
  jq -n --arg log "$DAILY_LOG" --arg hint "$RECOVERY_HINT" '{
    systemMessage: ("gyeol reminder: today\u2019s daily log " + $log + " is still missing." + $hint)
  }'
  exit 0
fi

# Case 4: hard block, mark nagged.
touch "$NAGGED_FLAG" 2>/dev/null || true

jq -n --arg log "$DAILY_LOG" --arg machine "$MACHINE" --arg hint "$RECOVERY_HINT" --arg dec "$BLOCK_DECISION" '{
  decision: $dec,
  reason: (
    "gyeol memory circuit: this session was substantive (Write/Edit/commit detected) but today\u2019s daily log is missing at " + $log + ". Before stopping, write the daily log now: what you worked on, what decisions you made, what you learned, any open threads. Use the format from $GYEOL_HOME/memory/episodes/daily/ (frontmatter with date + sessions count, then Session sections with What Happened / Decisions Made / Artifacts). Write that exact path \u2014 the log is per-machine so two machines never append to one file; do not drop the machine suffix. Also update this machine\u2019s episodes/_recent." + $machine + ".md (create it with last_updated frontmatter and a Daily Index section if missing): append a one-line entry under today\u2019s date in the Daily Index (pointing at the daily log \u2014 it is a navigation index, not a content store), update last_updated, and prune entries now older than 7 days. Then reconcile Still Open in the shared episodes/_recent.md (add new unresolved items, drop resolved ones, each tagged with source date). Never edit another machine\u2019s _recent.{machine}.md." + $hint + " This enforcement exists because task framing silently suppressed automatic memory capture on 2026-04-14 — see feedback_session_bootstrap.md. Do not treat this as optional."
  )
}'
