#!/usr/bin/env sh
# Test the machine id, and the daily-log split that depends on it.
#
# The bug this guards against is not a crash. It is a machine id that quietly
# changes with the network: `hostname -s` on a laptop behind an office VPN
# reported `ip-172-16-1-2`, and the same two machines then signed one memory
# tree under five names. So the load-bearing case here is the boring one —
# the id is the same on two runs with different environments.
#
# Everything happens inside a synthetic GYEOL_HOME; no real memory is touched.
#
# Usage: sh scripts/test-machine-id.sh

set -u

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$SCRIPT_DIR/.." && pwd)

TMP=$(mktemp -d) || exit 1
trap 'rm -rf "$TMP"' EXIT

passed=0
failed=0

check() {  # check <label> <got> <want>
  if [ "$2" = "$3" ]; then
    passed=$((passed + 1)); echo "PASS  $1"
  else
    failed=$((failed + 1)); echo "FAIL  $1 (got '$2', want '$3')"
  fi
}

check_not() {  # check_not <label> <got> <unwanted>
  if [ "$2" != "$3" ]; then
    passed=$((passed + 1)); echo "PASS  $1"
  else
    failed=$((failed + 1)); echo "FAIL  $1 (got '$2', wanted anything else)"
  fi
}

GH="$TMP/gyeol"
mkdir -p "$GH/scripts" "$GH/memory/episodes/daily"
cp "$REPO/scripts/machine-id.sh" "$REPO/scripts/stop-check-daily.sh" "$GH/scripts/"

id() { GYEOL_HOME="$GH" sh "$REPO/scripts/machine-id.sh"; }

# --- 1. the override ---------------------------------------------------------

printf 'lab-desktop\n' > "$GH/.machine-id"
check "an explicit id is used verbatim" "$(id)" "lab-desktop"

printf '# which machine this is\n\n   lab-desktop  \n' > "$GH/.machine-id"
check "comments and surrounding whitespace are ignored" "$(id)" "lab-desktop"

printf "chiyak's MacBook Pro\n" > "$GH/.machine-id"
check "spaces and quotes become filename-safe" "$(id)" "chiyak-sMacBookPro"

printf 'first-machine\nsecond-machine\n' > "$GH/.machine-id"
check "only the first entry is read" "$(id)" "first-machine"

# --- 2. falling through ------------------------------------------------------
#
# Control: a comment-only file must not read as "the id is empty string". An
# empty id would collapse every machine's daily log back onto one path, which is
# the collision the whole change exists to prevent.

printf '# only a comment\n' > "$GH/.machine-id"
FELL_THROUGH=$(id)
check_not "a comment-only override falls through to the OS" "$FELL_THROUGH" ""

rm -f "$GH/.machine-id"
check "with no override at all, the OS name is used" "$(id)" "$FELL_THROUGH"
check_not "and it is never empty" "$(id)" ""

# --- 3. the property that matters: it does not move with the network ---------
#
# The old `hostname -s` failed exactly here. HOSTNAME and a changed hostname
# lookup order must not reach the answer.

A=$(HOSTNAME=ip-172-16-1-2 id)
B=$(HOSTNAME=ip-192-168-0-160 id)
check "the id is stable across a changed HOSTNAME" "$A" "$B"
check_not "...and is not the network-assigned name" "$A" "ip-172-16-1-2"

# --- 4. the daily log path the Stop hook enforces ----------------------------
#
# Control: the hook must pass once the file it names exists, and must still be
# asking for a log when only *another* machine's log is present.

command -v jq > /dev/null 2>&1 || {
  echo "SKIP  jq is not installed; skipping the Stop hook cases."
  echo
  echo "$passed passed, $failed failed"
  [ "$failed" -eq 0 ] || exit 1
  exit 0
}

MACHINE=$(id)
TODAY=$(date +%Y-%m-%d)
DAILY="$GH/memory/episodes/daily/${TODAY}.${MACHINE}.md"
SID="machine-id-test-$$"
SUBSTANTIVE="/tmp/gyeol_session_${SID}.substantive"
trap 'rm -rf "$TMP"; rm -f "/tmp/gyeol_session_'"$SID"'."*' EXIT

# Each case is a fresh session: the hook nags hard once and softly after that,
# so a leftover nagged flag would turn a genuine block into a "pass" and hide
# the very thing being asserted.
hook() {
  rm -f "/tmp/gyeol_session_${SID}.nagged"
  touch "$SUBSTANTIVE"
  printf '{"session_id":"%s"}' "$SID" \
    | GYEOL_HOME="$GH" sh "$REPO/scripts/stop-check-daily.sh" \
    | jq -r '.decision // "pass"'
}

check "a substantive session with no log is blocked" "$(hook)" "block"

printf -- '---\ndate: %s\n---\n' "$TODAY" > "$GH/memory/episodes/daily/${TODAY}.other-machine.md"
check "another machine's log does not satisfy this machine" "$(hook)" "block"

printf -- '---\ndate: %s\n---\n' "$TODAY" > "$DAILY"
check "this machine's own log passes" "$(hook)" "pass"

rm -f "$DAILY"
printf -- '---\ndate: %s\n---\n' "$TODAY" > "$GH/memory/episodes/daily/${TODAY}.md"
check "a pre-split unsuffixed log still passes" "$(hook)" "pass"

echo
echo "$passed passed, $failed failed"
[ "$failed" -eq 0 ] || exit 1
