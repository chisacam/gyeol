#!/usr/bin/env sh
# Test sync-memory.sh against two simulated machines sharing one bare remote.
#
# Everything happens inside a temp directory; no real GYEOL_HOME is touched.
#
# Usage: sh scripts/test-sync-memory.sh

set -u

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
SYNC="$SCRIPT_DIR/sync-memory.sh"

command -v git > /dev/null 2>&1 || { echo "SKIP  git is not installed."; exit 0; }

TMP=$(mktemp -d) || exit 1
trap 'rm -rf "$TMP"' EXIT

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

check_contains() {
  label=$1; haystack=$2; needle=$3
  case "$haystack" in
    *"$needle"*) passed=$((passed + 1)); echo "PASS  $label" ;;
    *) failed=$((failed + 1)); echo "FAIL  $label (missing '$needle' in: $haystack)" ;;
  esac
}

git_q() { git -C "$1" -c user.name=test -c user.email=test@example.com "${@:-}" ; }

# --- machine helpers --------------------------------------------------------

setup_machine() {  # setup_machine <name>
  home="$TMP/$1"
  mkdir -p "$home/memory/episodes/daily"
  git -C "$home/memory" init --quiet --initial-branch=main
  git -C "$home/memory" config user.name "test-$1"
  git -C "$home/memory" config user.email "$1@example.com"
  git -C "$home/memory" remote add origin "$TMP/remote.git"
}

sync() {  # sync <machine> <mode>
  GYEOL_HOME="$TMP/$1" sh "$SYNC" "$2" 2>/dev/null
}

# --- unconfigured installs must be silent no-ops ----------------------------

mkdir -p "$TMP/bare-install/memory"
out=$(GYEOL_HOME="$TMP/bare-install" sh "$SYNC" pull 2>/dev/null)
check "a memory dir that is not a repo is a no-op" "$out" "{}"
check "...and exits 0" "$?" "0"

out=$(GYEOL_HOME="$TMP/no-such-home" sh "$SYNC" pull 2>/dev/null)
check "a missing GYEOL_HOME is a no-op" "$out" "{}"

mkdir -p "$TMP/no-remote/memory"
git -C "$TMP/no-remote/memory" init --quiet --initial-branch=main
out=$(GYEOL_HOME="$TMP/no-remote" sh "$SYNC" pull 2>/dev/null)
check "a repo with no remote is a no-op" "$out" "{}"

# --- two machines, one remote -----------------------------------------------

git init --quiet --bare --initial-branch=main "$TMP/remote.git"
setup_machine alpha
setup_machine beta

printf -- '---\nname: Test\n---\n' > "$TMP/alpha/memory/IDENTITY.md"
out=$(sync alpha push)
check "the first push is silent" "$out" "{}"

out=$(sync beta pull)
check "the second machine pulls silently" "$out" "{}"
check "identity arrives on the second machine" \
  "$(test -f "$TMP/beta/memory/IDENTITY.md" && echo yes || echo no)" "yes"

# --- work on one machine reaches the other ----------------------------------

echo "alpha day one" > "$TMP/alpha/memory/episodes/daily/2026-06-01.md"
sync alpha push > /dev/null
sync beta pull > /dev/null
check "a daily log written on alpha reaches beta" \
  "$(cat "$TMP/beta/memory/episodes/daily/2026-06-01.md" 2>/dev/null)" "alpha day one"

# --- uncommitted work is never lost to a pull -------------------------------

echo "beta uncommitted" > "$TMP/beta/memory/episodes/daily/2026-06-02.md"
echo "alpha day three" > "$TMP/alpha/memory/episodes/daily/2026-06-03.md"
sync alpha push > /dev/null
sync beta pull > /dev/null
check "beta's uncommitted file survives a pull" \
  "$(cat "$TMP/beta/memory/episodes/daily/2026-06-02.md" 2>/dev/null)" "beta uncommitted"
check "and alpha's new file arrived in the same pull" \
  "$(cat "$TMP/beta/memory/episodes/daily/2026-06-03.md" 2>/dev/null)" "alpha day three"
check "beta's file was committed, not left dirty" \
  "$(git -C "$TMP/beta/memory" status --porcelain | wc -l | tr -d ' ')" "0"

# --- a push that races another machine still lands --------------------------

sync beta push > /dev/null
echo "alpha day four" > "$TMP/alpha/memory/episodes/daily/2026-06-04.md"
echo "beta day five" > "$TMP/beta/memory/episodes/daily/2026-06-05.md"
sync alpha push > /dev/null
out=$(sync beta push)
check "a rejected push integrates and retries" "$out" "{}"
sync alpha pull > /dev/null
check "both machines' work survives the race" \
  "$(cat "$TMP/alpha/memory/episodes/daily/2026-06-05.md" 2>/dev/null)" "beta day five"

# --- the critical case: a conflict must never land in a memory file ---------

printf 'alpha self\n' > "$TMP/alpha/memory/SELF.md"
sync alpha push > /dev/null
printf 'beta self\n' > "$TMP/beta/memory/SELF.md"
out=$(sync beta pull)
check_contains "a conflicting pull is reported" "$out" "conflicts"
check_contains "...and names the file to fix by hand" "$out" "by hand"
check "SELF.md has no conflict markers" \
  "$(grep -c '<<<<<<<\|>>>>>>>' "$TMP/beta/memory/SELF.md" | tr -d ' ')" "0"
check "SELF.md still holds this machine's version" \
  "$(cat "$TMP/beta/memory/SELF.md")" "beta self"
check "the repo is not left mid-merge" \
  "$(test -f "$TMP/beta/memory/.git/MERGE_HEAD" && echo merging || echo clean)" "clean"

# --- an unreachable remote degrades to local-only ---------------------------

git -C "$TMP/alpha/memory" remote set-url origin "$TMP/gone.git"
echo "offline work" > "$TMP/alpha/memory/episodes/daily/2026-06-06.md"
out=$(sync alpha pull)
check_contains "an unreachable remote is reported, not fatal" "$out" "could not reach"
check "offline work is still committed locally" \
  "$(git -C "$TMP/alpha/memory" status --porcelain | wc -l | tr -d ' ')" "0"

# --- join: the dangerous one ------------------------------------------------

# A machine that has never run gyeol adopts the tree wholesale.
mkdir -p "$TMP/fresh/memory"
out=$(GYEOL_HOME="$TMP/fresh" sh "$SYNC" join "$TMP/remote.git" 2>&1)
check_contains "a fresh machine joins" "$out" "Joined"
check "identity arrives, so First Activation will not run" \
  "$(test -f "$TMP/fresh/memory/IDENTITY.md" && echo yes || echo no)" "yes"
check_contains "...and join says so explicitly" "$out" "First Activation will not run"

# A machine with its own history keeps it. This is the case that destroys
# memory if it is done with a clone.
mkdir -p "$TMP/hadwork/memory/episodes/daily"
echo "local only work" > "$TMP/hadwork/memory/episodes/daily/2026-07-07.md"
out=$(GYEOL_HOME="$TMP/hadwork" sh "$SYNC" join "$TMP/remote.git" 2>&1)
check_contains "a machine with existing memory joins" "$out" "Joined"
check "its own daily log survives the join" \
  "$(cat "$TMP/hadwork/memory/episodes/daily/2026-07-07.md" 2>/dev/null)" "local only work"
check "and the remote's identity arrived alongside it" \
  "$(test -f "$TMP/hadwork/memory/IDENTITY.md" && echo yes || echo no)" "yes"
check "the joined machine can then push" \
  "$(GYEOL_HOME="$TMP/hadwork" sh "$SYNC" push 2>/dev/null)" "{}"

# Joining twice must not re-plumb anything.
out=$(GYEOL_HOME="$TMP/hadwork" sh "$SYNC" join "$TMP/other.git" 2>&1)
check_contains "joining an already-joined machine is refused" "$out" "Already joined"
check "...and the original remote is untouched" \
  "$(git -C "$TMP/hadwork/memory" remote get-url origin)" "$TMP/remote.git"

# A conflicting join must change nothing.
mkdir -p "$TMP/clash/memory"
printf 'clash self\n' > "$TMP/clash/memory/SELF.md"
out=$(GYEOL_HOME="$TMP/clash" sh "$SYNC" join "$TMP/remote.git" 2>&1)
check_contains "a conflicting join is refused" "$out" "conflicts"
check "the local file is left exactly as it was" \
  "$(cat "$TMP/clash/memory/SELF.md")" "clash self"
check "no conflict markers were written" \
  "$(grep -c '<<<<<<<' "$TMP/clash/memory/SELF.md" | tr -d ' ')" "0"

# A remote that cannot be reached must not leave a half-configured repo.
mkdir -p "$TMP/badurl/memory"
out=$(GYEOL_HOME="$TMP/badurl" sh "$SYNC" join "$TMP/nope.git" 2>&1)
check_contains "an unreachable remote is refused" "$out" "Could not fetch"
check "...leaving no remote configured" \
  "$(git -C "$TMP/badurl/memory" remote get-url origin 2>/dev/null || echo none)" "none"

check "join without a url is a usage error" \
  "$(GYEOL_HOME="$TMP/fresh2" sh "$SYNC" join > /dev/null 2>&1; echo $?)" "2"

# --- status -----------------------------------------------------------------

out=$(GYEOL_HOME="$TMP/beta" sh "$SYNC" status 2>/dev/null)
check_contains "status reports the remote" "$out" "remote:"
check_contains "status reports the branch" "$out" "branch:"

echo ""
echo "$passed passed, $failed failed"
[ "$failed" -eq 0 ] || exit 1
