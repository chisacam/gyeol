#!/usr/bin/env sh
# gyeol PostToolUse hook — conditionally mark session as substantive
#
# Variant of post-mark-substantive.sh that only fires when the shell
# command contains a mutating git/gh operation. Needed for harnesses
# whose tool-use hook matcher can filter only by tool name (e.g. Codex
# PostToolUse "^Bash$", Gemini CLI AfterTool "run_shell_command"), not
# by command content.
#
# The pattern set is deliberately wider than "git commit" alone: on
# Codex, file edits go through apply_patch which bypasses hooks
# entirely, so an orchestration run's only hookable tells are the
# shell-side mutations (commit, push, PR create/merge, issue create,
# release create). The 2026-07 audit found the Stop gate fired only 3
# times across 548 Codex sessions because delegation runs commit in
# sub-rollouts; they do, however, merge and file through gh in the
# top-level session, which this set catches.
#
# Claude Code has an `if` condition on the hook entry itself, so it
# uses the unconditional post-mark-substantive.sh with
# `if: "Bash(git commit:*)"`. For Codex, Gemini and similar, use this.
#
# Input: hook JSON on stdin (session_id + tool_input.command).

set -eu

INPUT=$(cat)
SESSION_ID=$(printf '%s' "$INPUT" | jq -r '.session_id // empty')
CMD=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty')

[ -n "$SESSION_ID" ] || exit 0

case "$CMD" in
  *"git commit"*|*"git push"*|*"gh pr merge"*|*"gh pr create"*|*"gh issue create"*|*"gh release create"*)
    touch "/tmp/gyeol_session_${SESSION_ID}.substantive" 2>/dev/null || true
    ;;
esac

echo '{}'
exit 0
