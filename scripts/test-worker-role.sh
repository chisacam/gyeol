#!/usr/bin/env sh
# Test the worker role: does GYEOL_ROLE=worker make every hook a no-op?
#
# A worker is a session an orchestrator started for one task. It needs no
# memory, and what the hooks cost (the memory part of the bootstrap alone was
# 41,194 characters on 2026-10-16, plus a sync round trip at each end) is paid
# again by every worker. So with GYEOL_ROLE=worker each hook must print what its
# harness expects and do nothing else: no memory, no git call, no file written.
#
# Every row has a control. A hook that is silent for a worker proves nothing
# unless the same hook, in the same home, is not silent for a normal session.
#
# git is replaced on PATH by a stub that logs its arguments and fails, so a git
# call is counted whether or not it would have succeeded.
#
# Everything happens inside a synthetic GYEOL_HOME; no real memory is touched.
#
# Usage: sh scripts/test-worker-role.sh

set -u

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$SCRIPT_DIR/.." && pwd)

command -v jq > /dev/null 2>&1 || { echo "SKIP  jq is not installed."; exit 0; }

TMP=$(mktemp -d) || exit 1
SID="worker-role-$$"
trap 'rm -rf "$TMP"; rm -f "/tmp/gyeol_session_${SID}."*' EXIT

# The controls must not inherit the runner's role or provider: this test is
# likely to be run from inside a worker session.
unset GYEOL_ROLE
GYEOL_TRUST=1
export GYEOL_TRUST

passed=0
failed=0

check() {  # check <label> <got> <want>
  if [ "$2" = "$3" ]; then
    passed=$((passed + 1)); echo "PASS  $1"
  else
    failed=$((failed + 1)); echo "FAIL  $1 (got '$2', want '$3')"
  fi
}

# --- a synthetic home with just enough memory to notice a leak ---------------

GH="$TMP/gyeol"
mkdir -p "$GH/memory/episodes/daily" "$GH/scripts"
cp "$REPO/scripts/"*.sh "$REPO/scripts/"*.py "$GH/scripts/" 2>/dev/null
SECRET="CANARY-PRIVATE-MEMORY-STRING"
printf '# SOUL\n%s soul\n' "$SECRET" > "$GH/SOUL.md"
printf -- '---\nname: "test"\n---\n# Identity\n%s identity\n' "$SECRET" > "$GH/memory/IDENTITY.md"
printf -- '---\nlast_updated: "2999-01-01"\n---\n# Self\n%s self\n' "$SECRET" > "$GH/memory/SELF.md"
printf -- '---\nlast_updated: "2999-01-01"\n---\n# Recent\n%s recent\n' "$SECRET" \
  > "$GH/memory/episodes/_recent.md"

mkdir -p "$TMP/bin"
GIT_LOG="$TMP/git-calls.log"
cat > "$TMP/bin/git" <<STUB
#!/bin/sh
printf '%s\n' "\$*" >> "$GIT_LOG"
exit 1
STUB
chmod +x "$TMP/bin/git"
PATH="$TMP/bin:$PATH"
export PATH

hook() {  # hook <role|-> <stdin> <script> [args...] — "-" leaves GYEOL_ROLE unset
  _role=$1; _in=$2; _script=$3; shift 3
  if [ "$_role" = "-" ]; then
    printf '%s' "$_in" | env GYEOL_HOME="$GH" sh "$GH/scripts/$_script" "$@"
  else
    printf '%s' "$_in" | env GYEOL_HOME="$GH" GYEOL_ROLE="$_role" sh "$GH/scripts/$_script" "$@"
  fi
}

snapshot() {  # every path under the home, and every file's checksum
  find "$GH" | sort
  find "$GH" -type f -exec cksum {} + | sort
}

flags() {  # the per-session flag files the hooks keep in /tmp
  for f in "/tmp/gyeol_session_${SID}."*; do
    [ -e "$f" ] && printf '%s\n' "$f"
  done
  return 0
}

git_calls() {  # called|none
  if [ -s "$GIT_LOG" ]; then echo called; else echo none; fi
}

leaks() {  # leaks <file> — did the canary reach the output?
  if grep -qF "$SECRET" "$1"; then echo "leaked"; else echo "clean"; fi
}

context() {  # context <file> — the additionalContext a SessionStart hook printed
  jq -r '.hookSpecificOutput.additionalContext // empty' "$1"
}

STOP_IN="{\"session_id\":\"$SID\",\"stop_hook_active\":false}"
COMMIT_IN="{\"session_id\":\"$SID\",\"tool_input\":{\"command\":\"git commit -m x\"}}"
RECOVER_IN="{\"session_id\":\"$SID\",\"tool_input\":{\"command\":\"git show HEAD:README.md\"}}"
AGY_IN="{\"conversationId\":\"$SID\",\"invocationNum\":1}"

# --- 1. one sweep through every hook as a worker -----------------------------
# A substantive flag is planted first, so the Stop gate would block if it ran.

touch "/tmp/gyeol_session_${SID}.substantive"
: > "$GIT_LOG"
snapshot > "$TMP/home-before"
flags > "$TMP/flags-before"

RCS=""
w() {  # w <name> <stdin> <script> [args...] — stdout kept in $TMP/w-<name>
  _name=$1; shift
  hook worker "$@" > "$TMP/w-$_name" 2>/dev/null
  RCS="$RCS $_name=$?"
}

w soul '{"source":"startup"}' session-bootstrap-json.sh --part=soul
w memory '{"source":"startup"}' session-bootstrap-json.sh --part=memory
w all '{"source":"startup"}' session-bootstrap-json.sh
w agy "$AGY_IN" session-bootstrap-json.sh
w raw '' session-bootstrap.sh
w pull '' sync-memory.sh pull
w push '' sync-memory.sh push
w end '' session-end.sh
w stop "$STOP_IN" stop-check-daily.sh
w mark "$COMMIT_IN" post-mark-substantive.sh
w mark-if "$COMMIT_IN" post-mark-substantive-if-commit.sh
w recover "$RECOVER_IN" post-mark-recovery.sh

snapshot > "$TMP/home-after"
flags > "$TMP/flags-after"

check "every hook exits 0" "$(printf '%s\n' $RCS | grep -v '=0$')" ""
check "no hook calls git" "$(git_calls)" "none"
check "no file under the home is created or changed" \
  "$(diff "$TMP/home-before" "$TMP/home-after" > /dev/null && echo same || echo changed)" "same"
check "no session flag is created" \
  "$(diff "$TMP/flags-before" "$TMP/flags-after" > /dev/null && echo same || echo changed)" "same"

check "bootstrap soul part prints {}" "$(cat "$TMP/w-soul")" "{}"
check "bootstrap memory part carries no memory" "$(leaks "$TMP/w-memory")" "clean"
check "it says, in one line, that this is a worker session" \
  "$(context "$TMP/w-memory" | grep -c 'worker session')/$(context "$TMP/w-memory" | wc -l | tr -d ' ')" "1/1"
check "it is a SessionStart payload" \
  "$(jq -r '.hookSpecificOutput.hookEventName' "$TMP/w-memory")" "SessionStart"
check "the single-part bootstrap prints the same notice" "$(context "$TMP/w-all")" "$(context "$TMP/w-memory")"
check "an Antigravity first call carries no memory" "$(leaks "$TMP/w-agy")" "clean"
check "raw bootstrap carries no memory" "$(leaks "$TMP/w-raw")" "clean"
check "raw bootstrap says it in one line" \
  "$(grep -c 'worker session' "$TMP/w-raw")/$(wc -l < "$TMP/w-raw" | tr -d ' ')" "1/1"
check "sync pull prints {}" "$(cat "$TMP/w-pull")" "{}"
check "sync push prints {}" "$(cat "$TMP/w-push")" "{}"
check "session-end prints nothing" "$(cat "$TMP/w-end")" ""
check "Stop prints {}" "$(cat "$TMP/w-stop")" "{}"
check "post-mark-substantive prints {}" "$(cat "$TMP/w-mark")" "{}"
check "post-mark-substantive-if-commit prints {}" "$(cat "$TMP/w-mark-if")" "{}"
check "post-mark-recovery prints {}" "$(cat "$TMP/w-recover")" "{}"

# --- 2. the controls: the same hooks, the same home, no role -----------------

rm -f "/tmp/gyeol_session_${SID}."*

hook - '{"source":"startup"}' session-bootstrap-json.sh --part=memory > "$TMP/c-memory"
check "control: an unset role receives memory" "$(leaks "$TMP/c-memory")" "leaked"
hook orchestrator '{"source":"startup"}' session-bootstrap-json.sh --part=memory > "$TMP/c-other"
check "control: any other role receives memory" "$(leaks "$TMP/c-other")" "leaked"
hook - '' session-bootstrap.sh > "$TMP/c-raw"
check "control: raw bootstrap carries memory" "$(leaks "$TMP/c-raw")" "leaked"

hook - "$AGY_IN" session-bootstrap-json.sh > /dev/null
check "control: an Antigravity first call marks the conversation" \
  "$(flags | grep -c '\.bootstrapped$')" "1"
rm -f "/tmp/gyeol_session_${SID}."*

: > "$GIT_LOG"
hook - '' sync-memory.sh pull > /dev/null
check "control: sync pull calls git" "$(git_calls)" "called"
: > "$GIT_LOG"
hook - '' sync-memory.sh push > /dev/null
check "control: sync push calls git" "$(git_calls)" "called"

hook - '' session-end.sh
check "control: session-end records the session" \
  "$(wc -l < "$GH/.session-log.jsonl" | tr -d ' ')" "1"

touch "/tmp/gyeol_session_${SID}.substantive"
check "control: a substantive session is held for its log" \
  "$(hook - "$STOP_IN" stop-check-daily.sh | jq -r '.decision // "none"')" "block"
rm -f "/tmp/gyeol_session_${SID}."*

hook - "$COMMIT_IN" post-mark-substantive.sh > /dev/null
check "control: post-mark-substantive marks the session" "$(flags | grep -c '\.substantive$')" "1"
rm -f "/tmp/gyeol_session_${SID}."*
hook - "$COMMIT_IN" post-mark-substantive-if-commit.sh > /dev/null
check "control: post-mark-substantive-if-commit marks the session" "$(flags | grep -c '\.substantive$')" "1"
rm -f "/tmp/gyeol_session_${SID}."*
hook - "$RECOVER_IN" post-mark-recovery.sh > /dev/null
check "control: post-mark-recovery marks the session" "$(flags | grep -c '\.recovery$')" "1"
rm -f "/tmp/gyeol_session_${SID}."*

# --- 3. what the role leaves alone -------------------------------------------

: > "$GIT_LOG"
hook worker '' sync-memory.sh status > /dev/null
check "a worker's sync status still reads git" "$(git_calls)" "called"
hook worker '' sync-memory.sh join > /dev/null 2>&1
check "a worker's join without a URL still prints usage" "$?" "2"

printf '%s' '{"source":"startup"}' \
  | env GYEOL_HOME="$GH" GYEOL_ROLE=worker GYEOL_TRUST=0 sh "$GH/scripts/session-bootstrap-json.sh" --part=memory \
  > "$TMP/w-untrusted"
check "an untrusted worker carries no memory" "$(leaks "$TMP/w-untrusted")" "clean"
check "and is told it is a worker, before the trust gate is asked" \
  "$(context "$TMP/w-untrusted")" "$(context "$TMP/w-memory")"

echo
echo "passed $passed, failed $failed"
[ "$failed" -eq 0 ]
