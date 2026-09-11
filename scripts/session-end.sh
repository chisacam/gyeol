#!/usr/bin/env sh
# gyeol SessionEnd hook
#
# Records session-end metadata so the next SessionStart bootstrap can detect
# sessions that ended without a daily-log update and surface them to the
# agent as evidence to retrospect on.
#
# Why a separate evidence-recording hook (instead of, say, blocking exit
# the way Stop / AfterAgent do): SessionEnd fires AFTER the agent has
# stopped, so it cannot make the agent do work. Stop / AfterAgent already
# handle the "block exit when today's daily log is missing AND the session
# was substantive" case. SessionEnd handles the complementary case: the
# session ended cleanly (or the substantive-flag path failed, or the user
# /clear'd, or the harness crashed mid-session) and the next session needs
# to know the gap exists.
#
# The evidence file (~/.config/gyeol/.session-log.jsonl) is consumed by
# session-bootstrap.sh / session-bootstrap-json.sh's staleness check, which
# directs the agent to retrospect, write missing daily logs, then truncate
# this file as part of the procedure.
#
# Idempotency / safety: append-only, never blocks session shutdown.
#
# Harness compatibility:
#   - Claude Code:  SessionEnd hook supported. Register with this script.
#   - Gemini CLI:   SessionEnd exists but is documented as "cannot block
#                   exit and cannot inject context". The evidence-only
#                   role this script plays is still useful — the next
#                   SessionStart bootstrap reads the file regardless of
#                   which harness wrote it. Safe to register.
#   - OpenAI Codex: No session_end event exists. Do not register.

GYEOL_HOME="${GYEOL_HOME:-$HOME/.config/gyeol}"

# If gyeol is not installed on this machine, stay silent.
[ -d "$GYEOL_HOME" ] || exit 0

LOG="$GYEOL_HOME/.session-log.jsonl"

# --- Trust gate ---------------------------------------------------------------
# Unlike the other hooks this one still runs when memory is withheld, and
# deliberately: "my notes do not have it" and "it did not happen" are different
# facts, and the session did happen. What changes is the record — it is marked,
# so a later backfill knows there is no recoverable content behind it and does
# not invent any. See scripts/trust-gate.sh.
if [ -f "$GYEOL_HOME/scripts/trust-gate.sh" ]; then
  . "$GYEOL_HOME/scripts/trust-gate.sh"
else
  gyeol_trust_denied() { case "${GYEOL_TRUST:-}" in 0|off|no|deny|false) return 0 ;; *) return 1 ;; esac; }
fi

TRUST_FIELD=""
if gyeol_trust_denied; then
  TRUST_FIELD=',"trust":"denied"'
fi

ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
# Escape backslashes and double quotes in cwd for JSON safety.
cwd_escaped=$(printf '%s' "${PWD:-unknown}" | sed 's/\\/\\\\/g; s/"/\\"/g')

printf '{"end":"%s","cwd":"%s"%s}\n' "$ts" "$cwd_escaped" "$TRUST_FIELD" >> "$LOG" 2>/dev/null || true

exit 0
