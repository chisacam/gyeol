#!/usr/bin/env sh
# gyeol PostToolUse hook — mark session as having a recovery event
#
# Fires when a Bash command matches git show HEAD: or git checkout HEAD --
# (both are file-restoration patterns). Touches a per-session recovery
# flag. The Stop hook adds an Incidents-section reminder to the daily log
# demand when this flag is present.
#
# Why: 2026-04-14 the debian/changelog restoration event was a save-worthy
# moment that got erased by post-recovery relief. This flag ensures the
# memory system notices the incident even if meta-cognition doesn't.

set -eu

INPUT=$(cat)
SESSION_ID=$(printf '%s' "$INPUT" | jq -r '.session_id // .conversationId // empty')
CMD=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // .toolCall.args.CommandLine // empty')

[ -n "$SESSION_ID" ] || exit 0

if [ -z "$CMD" ]; then
  TRANSCRIPT=$(printf '%s' "$INPUT" | jq -r '.transcriptPath // empty')
  if [ -n "$TRANSCRIPT" ] && [ -f "$TRANSCRIPT" ]; then
    CMD=$(tail -n 20 "$TRANSCRIPT" 2>/dev/null | jq -r 'select(.tool_calls != null) | .tool_calls[] | select(.name == "run_command") | .args.CommandLine // empty' 2>/dev/null | tail -n 1 || true)
  fi
fi

case "$CMD" in
  *"git show HEAD:"*|*"git show HEAD^:"*|*"git checkout HEAD --"*|*"git checkout HEAD~"*)
    touch "/tmp/gyeol_session_${SESSION_ID}.recovery" 2>/dev/null || true
    ;;
esac

echo '{}'
exit 0
