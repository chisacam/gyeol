#!/usr/bin/env sh
# Test reconcile_claude_hooks in update-gyeol.sh: the Claude Code settings it
# rewrites are the user's own file, so every rewrite needs a row that shows what
# it changes, a row that shows it is idempotent, and a row that shows what it
# must leave alone.
#
# Two migrations live there:
# - a legacy single `session-bootstrap-json.sh` SessionStart command becomes the
#   `--part=soul` / `--part=memory` pair;
# - the SessionEnd `sync-memory.sh push` hook gets its own `timeout`, because
#   Claude Code cancels a SessionEnd hook after 1.5 s otherwise and the push
#   needs a git round trip.
#
# Everything happens inside a synthetic HOME; no real settings are touched.
#
# Usage: sh scripts/test-claude-hooks.sh

set -u

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$SCRIPT_DIR/.." && pwd)

command -v curl > /dev/null 2>&1 || { echo "SKIP  curl is not installed."; exit 0; }
command -v jq > /dev/null 2>&1 || { echo "SKIP  jq is not installed."; exit 0; }

TMP=$(mktemp -d) || exit 1
trap 'rm -rf "$TMP"' EXIT

echo probe > "$TMP/probe.txt"
curl -fsSL "file://$TMP/probe.txt" > /dev/null 2>&1 || {
  echo "SKIP  this curl does not support file:// URLs."
  exit 0
}

passed=0
failed=0

check() {  # check <label> <got> <want>
  if [ "$2" = "$3" ]; then
    passed=$((passed + 1)); echo "PASS  $1"
  else
    failed=$((failed + 1)); echo "FAIL  $1 (got '$2', want '$3')"
  fi
}

LEGACY='{
  "model": "opus",
  "hooks": {
    "SessionStart": [{"hooks": [
      {"type": "command", "command": "sh \"$HOME/.config/gyeol/scripts/sync-memory.sh\" pull 2>/dev/null || echo '"'"'{}'"'"'"},
      {"type": "command", "command": "sh \"$HOME/.config/gyeol/scripts/session-bootstrap-json.sh\" 2>/dev/null || echo '"'"'{}'"'"'"}
    ]}],
    "SessionEnd": [{"hooks": [
      {"type": "command", "command": "sh \"$HOME/.config/gyeol/scripts/session-end.sh\" 2>/dev/null || true"},
      {"type": "command", "command": "sh \"$HOME/.config/gyeol/scripts/sync-memory.sh\" push 2>/dev/null || true"}
    ]}],
    "Stop": [{"hooks": [{"type": "command", "command": "echo other-tool"}]}]
  }
}'

setup_machine() {  # setup_machine <name> <settings-json> [disabled-harness]
  home="$TMP/$1"
  rm -rf "$home"
  mkdir -p "$home/.claude" "$home/.config/gyeol/scripts"
  printf '%s\n' "$2" > "$home/.claude/settings.json"
  gh="$home/.config/gyeol"
  cp "$REPO/VERSION" "$gh/VERSION"
  cp "$REPO/SOUL.md" "$REPO/MEMORY_SYSTEM.md" "$gh/"
  cp "$REPO/scripts/update-gyeol.sh" "$gh/scripts/"
  if [ "$#" -ge 3 ]; then
    printf '%s\n' "$3" > "$gh/.disabled-harnesses"
  fi
}

# VERSION is copied from the repo, so this takes the already-up-to-date branch,
# which still runs reconcile_claude_hooks.
update() {  # update <name>
  HOME="$TMP/$1" GYEOL_HOME="$TMP/$1/.config/gyeol" GYEOL_REPO_URL="file://$REPO" \
    sh "$TMP/$1/.config/gyeol/scripts/update-gyeol.sh" > "$TMP/$1.out" 2>&1
}

settings() { cat "$TMP/$1/.claude/settings.json"; }
push_timeout() {
  settings "$1" | jq -r '[.hooks.SessionEnd[].hooks[] | select(.command | test("sync-memory.sh.*push")) | .timeout // "none"] | join(",")'
}
end_timeout() {
  settings "$1" | jq -r '[.hooks.SessionEnd[].hooks[] | select(.command | test("session-end.sh")) | .timeout // "none"] | join(",")'
}
bootstrap_parts() {
  settings "$1" | jq -r '[.hooks.SessionStart[].hooks[] | select(.command | test("session-bootstrap-json.sh")) | (.command | capture("--part=(?<p>[a-z]+)").p // "single")] | join(",")'
}

# --- a legacy install gets both migrations ----------------------------------

setup_machine legacy "$LEGACY"
update legacy
check "the push hook gets its own timeout" "$(push_timeout legacy)" "15"
check "session-end.sh keeps the default (it is fast)" "$(end_timeout legacy)" "none"
check "the single bootstrap is split into soul and memory" "$(bootstrap_parts legacy)" "soul,memory"
check "a neighbouring tool's hook is untouched" \
  "$(settings legacy | jq -r '.hooks.Stop[0].hooks[0].command')" "echo other-tool"
check "unrelated settings are untouched" "$(settings legacy | jq -r '.model')" "opus"

# --- idempotent ---------------------------------------------------------------

before=$(settings legacy)
update legacy
check "a second run changes nothing" "$(settings legacy)" "$before"

# --- a timeout the user chose is theirs ---------------------------------------

custom=$(printf '%s' "$LEGACY" | jq '(.hooks.SessionEnd[0].hooks[1].timeout) = 40')
setup_machine custom "$custom"
update custom
check "an existing timeout is left as the user set it" "$(push_timeout custom)" "40"

# --- an opted-out Claude Code is not rewritten --------------------------------

setup_machine optout "$LEGACY" claude
before=$(settings optout)
update optout
check "with claude in .disabled-harnesses the file is untouched" "$(settings optout)" "$before"

echo ""
echo "$passed passed, $failed failed"
[ "$failed" -eq 0 ]
