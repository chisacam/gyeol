#!/usr/bin/env sh
# gyeol PostToolUse hook — mark session as substantive
#
# Touches a per-session flag file whenever a meaningful edit happens
# (Write, Edit, or git commit). The Stop hook later reads this flag to
# decide whether to demand a daily episode log.
#
# Input: PostToolUse hook JSON on stdin (contains session_id).

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

INPUT=$(cat)
SESSION_ID=$(printf '%s' "$INPUT" | jq -r '.session_id // empty')

[ -n "$SESSION_ID" ] || exit 0

touch "/tmp/gyeol_session_${SESSION_ID}.substantive" 2>/dev/null || true

# Always emit an empty JSON object so harnesses that treat stdout as
# JSON (Gemini CLI: "Silence is Mandatory", Codex: PostToolUse ignores
# non-JSON) never see a parse warning.
echo '{}'
exit 0
