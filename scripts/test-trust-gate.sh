#!/usr/bin/env sh
# Test the trust gate: does an untrusted provider actually get nothing?
#
# Every case has a control. A gate that is tested only in its deny state is
# indistinguishable from a fixture that never carried memory in the first
# place — the allow row is what shows the memory was there to withhold.
#
# Everything happens inside a synthetic GYEOL_HOME; no real memory is touched.
#
# Usage: sh scripts/test-trust-gate.sh

set -u

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$SCRIPT_DIR/.." && pwd)

command -v jq > /dev/null 2>&1 || { echo "SKIP  jq is not installed."; exit 0; }

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

verdict() {  # verdict <env assignments...> — prints allow|deny
  env "$@" sh "$REPO/scripts/trust-gate.sh" | cut -d' ' -f1
}

leaks() {  # leaks <file> — did the canary reach the output?
  if grep -qF "$SECRET" "$1"; then echo "leaked"; else echo "clean"; fi
}

# --- 1. the verdict itself ---------------------------------------------------

check "no override is the harness's own API" "$(verdict GYEOL_TRUST= ANTHROPIC_BASE_URL=)" "allow"
check "GYEOL_TRUST=0 denies" "$(verdict GYEOL_TRUST=0)" "deny"
check "GYEOL_TRUST=1 allows" "$(verdict GYEOL_TRUST=1)" "allow"
check "a typo is not consent" "$(verdict GYEOL_TRUST=maybe)" "deny"
check "anthropic endpoint allows" "$(verdict ANTHROPIC_BASE_URL=https://api.anthropic.com)" "allow"
check "third-party endpoint denies" "$(verdict ANTHROPIC_BASE_URL=https://openrouter.ai/api/v1)" "deny"
check "a loopback router denies" "$(verdict ANTHROPIC_BASE_URL=http://127.0.0.1:3000)" "deny"
check "bedrock allows" "$(verdict CLAUDE_CODE_USE_BEDROCK=1)" "allow"
check "GYEOL_TRUSTED_HOSTS extends the allowlist" \
  "$(verdict ANTHROPIC_BASE_URL=https://llm.corp.example/v1 GYEOL_TRUSTED_HOSTS=corp.example)" "allow"
check "GYEOL_TRUST beats the endpoint" \
  "$(verdict GYEOL_TRUST=0 ANTHROPIC_BASE_URL=https://api.anthropic.com)" "deny"

# --- 2. the bootstrap, which is the actual leak ------------------------------

echo '{"source":"startup"}' | env GYEOL_HOME="$GH" GYEOL_TRUST=1 \
  sh "$GH/scripts/session-bootstrap-json.sh" > "$TMP/boot-allow.json"
echo '{"source":"startup"}' | env GYEOL_HOME="$GH" GYEOL_TRUST=0 \
  sh "$GH/scripts/session-bootstrap-json.sh" > "$TMP/boot-deny.json"
check "control: a trusted session receives memory" "$(leaks "$TMP/boot-allow.json")" "leaked"
check "an untrusted session receives none" "$(leaks "$TMP/boot-deny.json")" "clean"
check "and is told why" \
  "$(jq -r '.hookSpecificOutput.additionalContext' "$TMP/boot-deny.json" | grep -c 'memory is withheld')" "1"

env GYEOL_HOME="$GH" GYEOL_TRUST=1 sh "$GH/scripts/session-bootstrap.sh" > "$TMP/raw-allow.txt"
env GYEOL_HOME="$GH" GYEOL_TRUST=0 sh "$GH/scripts/session-bootstrap.sh" > "$TMP/raw-deny.txt"
check "control: raw-stdout bootstrap carries memory" "$(leaks "$TMP/raw-allow.txt")" "leaked"
check "raw-stdout bootstrap withholds it" "$(leaks "$TMP/raw-deny.txt")" "clean"

# --- 3. the demand to write a daily log --------------------------------------
# A blocked Stop is what sends the agent into the memory tree, so the gate has
# to reach it too. The control needs a substantive session and no log for today.

stop_decision() {  # stop_decision <trust> — prints the decision or "none"
  sid="stop-$1-$$"
  touch "/tmp/gyeol_session_${sid}.substantive"
  printf '{"session_id":"%s","stop_hook_active":false}' "$sid" \
    | env GYEOL_HOME="$GH" GYEOL_TRUST="$1" sh "$GH/scripts/stop-check-daily.sh" \
    | jq -r '.decision // "none"'
  rm -f "/tmp/gyeol_session_${sid}."*
}

check "control: a trusted substantive session is held for its log" "$(stop_decision 1)" "block"
check "an untrusted session is not" "$(stop_decision 0)" "none"

# --- 4. the flag files the Stop gate reads -----------------------------------

mark() {  # mark <trust> — prints created|absent
  sid="mark-$1-$$"
  printf '{"session_id":"%s"}' "$sid" \
    | env GYEOL_HOME="$GH" GYEOL_TRUST="$1" sh "$GH/scripts/post-mark-substantive.sh" > /dev/null
  if [ -f "/tmp/gyeol_session_${sid}.substantive" ]; then echo created; else echo absent; fi
  rm -f "/tmp/gyeol_session_${sid}."*
}

check "control: a trusted edit marks the session" "$(mark 1)" "created"
check "an untrusted edit marks nothing" "$(mark 0)" "absent"

# --- 5. the session-end record, which is kept either way ---------------------

: > "$GH/.session-log.jsonl"
env GYEOL_HOME="$GH" GYEOL_TRUST=1 sh "$GH/scripts/session-end.sh"
env GYEOL_HOME="$GH" GYEOL_TRUST=0 sh "$GH/scripts/session-end.sh"
check "both sessions are recorded as having happened" \
  "$(wc -l < "$GH/.session-log.jsonl" | tr -d ' ')" "2"
check "and only the untrusted one is marked" \
  "$(grep -c '"trust":"denied"' "$GH/.session-log.jsonl")" "1"

# --- 6. memory sync ----------------------------------------------------------

check "an untrusted session does not sync the memory tree" \
  "$(env GYEOL_HOME="$GH" GYEOL_TRUST=0 sh "$GH/scripts/sync-memory.sh" pull)" "{}"

echo
echo "passed $passed, failed $failed"
[ "$failed" -eq 0 ]
