#!/usr/bin/env sh
# Test update-gyeol.sh's harness opt-out against a synthetic machine.
#
# The bug this guards was found on a machine that dropped gyeol from pi and
# kept it in Claude Code. Deleting ~/.pi/agent/AGENTS.md and
# ~/.pi/agent/extensions/gyeol was not enough: the reconciliations are gated
# on whether the harness directory exists, and ~/.pi/agent/extensions outlives
# the deletion because it still holds the harness's other extensions. The next
# check reinstated everything. So the control case below is not decoration —
# it is the only thing that shows the gate is live and the skip is what stops
# it, rather than the fixture simply being inert.
#
# Everything happens inside a temp HOME; no real GYEOL_HOME is touched.
#
# Usage: sh scripts/test-harness-opt-out.sh

set -u

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$SCRIPT_DIR/.." && pwd)

command -v curl > /dev/null 2>&1 || { echo "SKIP  curl is not installed."; exit 0; }

TMP=$(mktemp -d) || exit 1
trap 'rm -rf "$TMP"' EXIT

# The reconcile paths fetch through curl; file:// is how they are driven here.
echo probe > "$TMP/probe.txt"
curl -fsSL "file://$TMP/probe.txt" > /dev/null 2>&1 || {
  echo "SKIP  this curl does not support file:// URLs."
  exit 0
}

passed=0
failed=0

check() {
  label=$1; got=$2; want=$3
  if [ "$got" = "$want" ]; then
    passed=$((passed + 1)); echo "PASS  $label"
  else
    failed=$((failed + 1)); echo "FAIL  $label (got '$got', want '$want')"
  fi
}

# --- one synthetic machine per case -----------------------------------------

# Builds a HOME with two harnesses installed: Claude Code, and pi carrying a
# neighbouring extension and skill so the directory-exists gate stays true
# after gyeol's own directory is gone.
setup_machine() {  # setup_machine <name> [disabled-harness]
  home="$TMP/$1"
  rm -rf "$home"
  mkdir -p "$home/.pi/agent/extensions/other-ext" "$home/.pi/agent/skills/other-skill"
  mkdir -p "$home/.claude/skills/other-skill"
  printf '<!-- gyeol:begin -->\nSTALE\n<!-- gyeol:end -->\n' > "$home/.pi/agent/AGENTS.md"
  printf '# user own line\n<!-- gyeol:begin -->\nSTALE\n<!-- gyeol:end -->\n' \
    > "$home/.claude/CLAUDE.md"

  gh="$home/.config/gyeol"
  mkdir -p "$gh/scripts"
  cp "$REPO/VERSION" "$gh/VERSION"
  cp "$REPO/SOUL.md" "$REPO/MEMORY_SYSTEM.md" "$gh/"
  cp "$REPO/scripts/update-gyeol.sh" "$gh/scripts/"
  if [ "$#" -ge 2 ]; then
    printf '# dropped on purpose\n%s\n' "$2" > "$gh/.disabled-harnesses"
  fi
}

# VERSION is copied from the repo, so this always takes the already-up-to-date
# branch — the one that runs unattended on the 7-day check and needs no
# confirmation prompt.
update() {  # update <name>
  HOME="$TMP/$1" GYEOL_HOME="$TMP/$1/.config/gyeol" GYEOL_REPO_URL="file://$REPO" \
    sh "$TMP/$1/.config/gyeol/scripts/update-gyeol.sh" > "$TMP/$1.out" 2>&1
}

exists() { [ -e "$1" ] && echo yes || echo no; }
refreshed() { grep -q STALE "$1" && echo no || echo yes; }

# --- control: nothing opted out, so pi is reinstated ------------------------

setup_machine control
update control

check "control: the pi extension is installed" \
  "$(exists "$TMP/control/.pi/agent/extensions/gyeol/index.ts")" yes
check "control: the skill is installed into pi" \
  "$(exists "$TMP/control/.pi/agent/skills/gyeol-capture/SKILL.md")" yes
check "control: pi's instructions block is refreshed" \
  "$(refreshed "$TMP/control/.pi/agent/AGENTS.md")" yes

# --- pi opted out -----------------------------------------------------------

setup_machine dropped pi
update dropped

check "the pi extension stays gone" \
  "$(exists "$TMP/dropped/.pi/agent/extensions/gyeol/index.ts")" no
check "the skill is not installed into pi" \
  "$(exists "$TMP/dropped/.pi/agent/skills/gyeol-capture/SKILL.md")" no
check "a stale pi block is left alone rather than refreshed" \
  "$(refreshed "$TMP/dropped/.pi/agent/AGENTS.md")" no

# Dropping one harness must not touch the one that kept gyeol, and must not
# touch the opted-out harness's neighbours either.
check "the harness that kept gyeol still gets the skill" \
  "$(exists "$TMP/dropped/.claude/skills/gyeol-capture/SKILL.md")" yes
check "the harness that kept gyeol still gets the block" \
  "$(refreshed "$TMP/dropped/.claude/CLAUDE.md")" yes
check "splicing the block preserves the user's own content" \
  "$(grep -c '^# user own line$' "$TMP/dropped/.claude/CLAUDE.md")" 1
check "pi's neighbouring extension is untouched" \
  "$(exists "$TMP/dropped/.pi/agent/extensions/other-ext")" yes
check "pi's neighbouring skill is untouched" \
  "$(exists "$TMP/dropped/.pi/agent/skills/other-skill")" yes

# --- the marker file is parsed as whole lines -------------------------------

# Pull the real function in rather than restating it: a copy that drifts from
# update-gyeol.sh is a test that reports on itself.
eval "$(sed -n '/^harness_disabled() {$/,/^}$/p' "$REPO/scripts/update-gyeol.sh")"
mkdir -p "$TMP/marker"
DISABLED_FILE="$TMP/marker/.disabled-harnesses"

ask() {  # ask <file-body> <harness>
  printf '%b' "$1" > "$DISABLED_FILE"
  harness_disabled "$2" && echo disabled || echo active
}

check "a plain id disables it"                  "$(ask 'pi\n' pi)" disabled
check "...and leaves every other harness alone" "$(ask 'pi\n' claude)" active
check "surrounding whitespace is ignored"       "$(ask '  pi  \t\n' pi)" disabled
check "a commented-out id does not disable"     "$(ask '# pi\n' pi)" active
check "a trailing comment is stripped"          "$(ask 'pi # dropped\n' pi)" disabled
check "several ids can be listed"               "$(ask 'pi\ncodex\n' codex)" disabled
check "matching is on the whole line"           "$(ask 'pilot\n' pi)" active
check "an empty marker file disables nothing"   "$(ask '' pi)" active

DISABLED_FILE="$TMP/marker/no-such-file"
check "no marker file means nothing is disabled" \
  "$(harness_disabled pi && echo disabled || echo active)" active

echo ""
echo "$passed passed, $failed failed"
[ "$failed" -eq 0 ] || exit 1
