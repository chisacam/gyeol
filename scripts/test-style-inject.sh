#!/usr/bin/env sh
# Test the writing-style injection: does the bootstrap carry styles/{lang}.md
# exactly when IDENTITY's preferred_language matches the guide's `match:` terms?
#
# Every injection row has a control: the same home with an unmatched language,
# and the same language with no styles/ directory. A guide that is "injected"
# in a fixture where it would be injected anyway proves nothing.
#
# Both bootstrap variants are checked: the JSON one (Claude Code SessionStart)
# and the raw one (pi and other harnesses that append stdout).
#
# Everything happens inside a synthetic GYEOL_HOME; no real memory is touched.
#
# Usage: sh scripts/test-style-inject.sh

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

GH="$TMP/gyeol"
mkdir -p "$GH/memory/episodes" "$GH/scripts" "$GH/styles"
cp "$REPO/scripts/"*.sh "$REPO/scripts/"*.py "$GH/scripts/" 2>/dev/null
printf '# SOUL\n' > "$GH/SOUL.md"
printf '# Self\n' > "$GH/memory/SELF.md"
printf -- '---\nlast_updated: 2099-01-01\n---\n# Recent Activity\n' > "$GH/memory/episodes/_recent.md"
printf -- '---\nlanguage: xx\nmatch: ["Klingon", "tlhIngan"]\n---\n# STYLE-CANARY\n' > "$GH/styles/xx.md"

identity() {  # identity <preferred_language>
  printf -- '---\nname: "test"\npreferred_language: "%s"\n---\n# Identity\n' "$1" > "$GH/memory/IDENTITY.md"
}

# Headers the bootstrap printed, in order, with the home prefix stripped.
headers_json() {
  echo '{"source":"startup"}' | GYEOL_HOME="$GH" sh "$GH/scripts/session-bootstrap-json.sh" 2>/dev/null \
    | jq -r '.hookSpecificOutput.additionalContext // ""' \
    | sed -n "s|^--- $GH/\\(.*\\) ---\$|\\1|p" | tr '\n' ' '
}
headers_part() {  # headers_part <soul|memory>
  echo '{"source":"startup"}' | GYEOL_HOME="$GH" sh "$GH/scripts/session-bootstrap-json.sh" --part="$1" 2>/dev/null \
    | jq -r '.hookSpecificOutput.additionalContext // ""' \
    | sed -n "s|^--- $GH/\\(.*\\) ---\$|\\1|p" | tr '\n' ' '
}
headers_raw() {
  GYEOL_HOME="$GH" sh "$GH/scripts/session-bootstrap.sh" < /dev/null 2>/dev/null \
    | sed -n "s|^--- $GH/\\(.*\\) ---\$|\\1|p" | tr '\n' ' '
}

WITH="SOUL.md memory/IDENTITY.md styles/xx.md memory/SELF.md memory/episodes/_recent.md "
WITHOUT="SOUL.md memory/IDENTITY.md memory/SELF.md memory/episodes/_recent.md "

identity "tlhIngan Hol + English"
check "json: matching term injects the guide right after IDENTITY" "$(headers_json)" "$WITH"
check "raw:  matching term injects the guide right after IDENTITY" "$(headers_raw)" "$WITH"

check "json --part=memory: the guide rides with IDENTITY" "$(headers_part memory)" \
  "memory/IDENTITY.md styles/xx.md memory/SELF.md memory/episodes/_recent.md "
check "json --part=soul: the guide stays out of the soul part" "$(headers_part soul)" "SOUL.md "

identity "English"
check "json: unmatched language injects nothing" "$(headers_json)" "$WITHOUT"
check "raw:  unmatched language injects nothing" "$(headers_raw)" "$WITHOUT"

identity "Klingon"
rm -rf "$GH/styles"
check "json: no styles/ directory injects nothing" "$(headers_json)" "$WITHOUT"
check "raw:  no styles/ directory injects nothing" "$(headers_raw)" "$WITHOUT"

# The shipped Korean guide matches the way IDENTITY records Korean.
mkdir -p "$GH/styles"
cp "$REPO/styles/ko.md" "$GH/styles/ko.md"
identity "한국어 + English 혼용 (Korean primary)"
check "json: shipped ko.md matches a Korean preferred_language" "$(headers_json)" \
  "SOUL.md memory/IDENTITY.md styles/ko.md memory/SELF.md memory/episodes/_recent.md "

echo ""
echo "$passed passed, $failed failed"
[ "$failed" -eq 0 ]
