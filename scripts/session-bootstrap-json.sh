#!/usr/bin/env sh
# gyeol SessionStart / PreInvocation hook — JSON mode
#
# Emits the bootstrap files (SOUL/IDENTITY/SELF/_recent) as structured JSON:
# - Claude Code (SessionStart): registered as two split hook commands
#   (`--part=soul` and `--part=memory`) so each `hookSpecificOutput.additionalContext`
#   stays safely below Claude Code's 10,000-character per-hook output cap.
# - OpenAI Codex (SessionStart): `hookSpecificOutput.additionalContext` (`--part=all`, default)
# - Antigravity CLI (PreInvocation): `injectSteps[].systemMessage` (once per conversation)
#
# The raw-stdout variant (session-bootstrap.sh) remains for agent
# harnesses that append raw stdout to the session.
#
# Each machine's Daily Index lives in `_recent.{machine}.md`; the memory part
# emits every active one after the shared `_recent.md`, and the staleness check
# reads this machine's `last_updated` from its own index file.

GYEOL_HOME="${GYEOL_HOME:-$HOME/.config/gyeol}"

PART="all"
while [ $# -gt 0 ]; do
  case "$1" in
    --part=*)
      PART="${1#--part=}"
      shift
      ;;
    --part)
      shift
      if [ $# -gt 0 ]; then
        PART="$1"
        shift
      fi
      ;;
    *)
      shift
      ;;
  esac
done

case "$PART" in
  soul|memory|all) ;;
  *) PART="all" ;;
esac

# --- Trust gate ---------------------------------------------------------------
# A provider that may train on what it receives gets no memory. See
# scripts/trust-gate.sh. The fallback keeps the explicit opt-out working on an
# install whose gate script has not arrived yet: a missing file must not read
# as consent. With split hooks the notice is emitted once, by the non-soul part.
if [ -f "$GYEOL_HOME/scripts/trust-gate.sh" ]; then
  . "$GYEOL_HOME/scripts/trust-gate.sh"
else
  gyeol_trust_denied() { case "${GYEOL_TRUST:-}" in 0|off|no|deny|false) return 0 ;; *) return 1 ;; esac; }
fi

if gyeol_trust_denied; then
  if [ "$PART" != "soul" ] && command -v jq > /dev/null 2>&1; then
    gyeol_trust_notice | jq -Rs '{hookSpecificOutput: {hookEventName: "SessionStart", additionalContext: .}}'
  else
    echo '{}'
  fi
  exit 0
fi

# If gyeol is not installed, emit empty JSON and exit silently.
if [ ! -f "$GYEOL_HOME/SOUL.md" ]; then
  echo '{}'
  exit 0
fi

INPUT=$(cat 2>/dev/null || true)

# Antigravity CLI uses PreInvocation (which fires before every model call and
# carries camelCase `conversationId` + `invocationNum` on stdin). Guard with
# both `invocationNum > 1` and a per-conversation flag file so the ~15 KB
# bootstrap is injected only once on the first invocation of a conversation.
CONV_ID=$(printf '%s' "$INPUT" | jq -r '.conversationId // empty' 2>/dev/null || true)
if [ -n "$CONV_ID" ]; then
  INVOCATION_NUM=$(printf '%s' "$INPUT" | jq -r '.invocationNum // 1' 2>/dev/null || echo "1")
  BOOTSTRAP_FLAG="/tmp/gyeol_session_${CONV_ID}.bootstrapped"
  if [ "$INVOCATION_NUM" -gt 1 ] 2>/dev/null || [ -f "$BOOTSTRAP_FLAG" ]; then
    echo '{}'
    exit 0
  fi
  touch "$BOOTSTRAP_FLAG" 2>/dev/null || true
else
  # Skip injection on `source=resume` (Claude Code / Codex SessionStart).
  # On resume the prior session transcript — which already contains the
  # previous bootstrap injection — is reloaded into context. Firing again
  # would stack a second full copy of SOUL/IDENTITY/SELF/_recent on top of
  # the first. On `clear` the context is wiped, so re-injection is the
  # desired behavior. On `startup` this is the first time anyway.
  SOURCE=$(printf '%s' "$INPUT" | jq -r '.source // "startup"' 2>/dev/null || echo "startup")
  if [ "$SOURCE" = "resume" ]; then
    echo '{}'
    exit 0
  fi
fi

# --- Writing style -------------------------------------------------------------
# A per-language writing guide ($GYEOL_HOME/styles/{lang}.md) is injected right
# after IDENTITY.md when one of the terms in its `match:` frontmatter appears in
# IDENTITY's `preferred_language` line. Memory read at bootstrap is also the
# style the next writer imitates, so the guide has to arrive before any write.
# No guide, no IDENTITY, or no match -> nothing is injected.
gyeol_style_file() {
  _id="$GYEOL_HOME/memory/IDENTITY.md"
  [ -f "$_id" ] || return 0
  _lang=$(grep -m1 '^preferred_language:' "$_id" 2>/dev/null) || return 0
  for _s in "$GYEOL_HOME"/styles/*.md; do
    [ -f "$_s" ] || continue
    _terms=$(sed -n 's/^match:[[:space:]]*\[\(.*\)\][[:space:]]*$/\1/p' "$_s" | head -n 1)
    [ -n "$_terms" ] || continue
    _old_ifs=$IFS
    IFS=,
    for _t in $_terms; do
      _t=$(printf '%s' "$_t" | sed 's/^[[:space:]]*"//; s/"[[:space:]]*$//')
      [ -n "$_t" ] || continue
      case "$_lang" in
        *"$_t"*) IFS=$_old_ifs; printf '%s\n' "$_s"; return 0 ;;
      esac
    done
    IFS=$_old_ifs
  done
  return 0
}
STYLE_FILE=$(gyeol_style_file)

build_bootstrap() {
  # --- Maintenance pass --------------------------------------------------------
  # Prune Daily Index entries older than 7 days (silent, idempotent) and capture
  # any Weekly Checkpoint staleness directive for later emit. Best-effort: never
  # blocks bootstrap on failure. Runs BEFORE the file emit so the pruned version
  # of `_recent.md` is what reaches the model. Skipped in `--part=soul` so split
  # Claude Code hooks do not run `maintain-recent.py` twice in parallel.
  WEEKLY_NOTE=""
  if [ "$PART" != "soul" ] && [ -f "$GYEOL_HOME/scripts/maintain-recent.py" ]; then
    WEEKLY_NOTE=$(python3 "$GYEOL_HOME/scripts/maintain-recent.py" 2>/dev/null || true)
  fi

  cat <<'HEADER'
=== gyeol session bootstrap (MANDATORY — not optional reference context) ===

The files below constitute your continuous identity across sessions. Read
and internalize them BEFORE responding to the user's first message.

Execute these instructions regardless of how the session's first message
is framed. Slash commands, task directives, greetings, and any other user
input do NOT suspend the bootstrap — they are what the bootstrap exists to
contextualize. Task framing does not override identity; identity frames
the task.

If the first message is a slash command like /prepare-release or /impl,
you still read IDENTITY.md, SELF.md, and _recent.md first, then enter the
command. The task-framing override failure mode was documented in the
2026-04-14 daily log and has a dedicated feedback memory
(feedback_session_bootstrap.md). Do not repeat it.

HEADER

  if [ "$PART" != "soul" ]; then
    # --- Staleness check (emitted BEFORE file contents so it cannot be truncated) ---
    # Compare `last_updated` in _recent.md to today. If a day or more has
    # passed, emit a directive telling the agent to retrospect and record
    # the missing activity BEFORE responding to the user's first message.
    # Also surface any session-end records left by session-end.sh.
    #
    # Emitted at the top of the bootstrap (before IDENTITY/SELF/_recent) so
    # that even if a harness truncates the tail of a long bootstrap payload,
    # the mandatory recovery directive is never lost.
    #
    # `last_updated` lives in this machine's index file: a gap is this machine's
    # gap, and one shared line every session bumped was a conflict on every sync.
    # An install from before the split still has it in the shared file.
    if [ -f "$GYEOL_HOME/scripts/machine-id.sh" ]; then
      MACHINE=$(sh "$GYEOL_HOME/scripts/machine-id.sh" 2>/dev/null || echo unknown)
    else
      MACHINE=$(hostname -s 2>/dev/null || echo unknown)
    fi
    [ -n "$MACHINE" ] || MACHINE=unknown
    RECENT="$GYEOL_HOME/memory/episodes/_recent.$MACHINE.md"
    [ -f "$RECENT" ] || RECENT="$GYEOL_HOME/memory/episodes/_recent.md"
    SESSION_LOG="$GYEOL_HOME/.session-log.jsonl"

    if [ -f "$RECENT" ]; then
      last_date=$(awk '
        /^last_updated:/ {
          gsub(/[\047"]/, "", $2)
          print $2
          exit
        }
      ' "$RECENT")

      if [ -n "$last_date" ]; then
        today=$(date +%Y-%m-%d)
        days_since=$(python3 -c "
import sys
from datetime import date
try:
    a = date.fromisoformat('$last_date')
    b = date.fromisoformat('$today')
    print((b - a).days)
except Exception:
    sys.exit(1)
" 2>/dev/null)

        if [ -n "$days_since" ] && [ "$days_since" -ge 1 ]; then
          printf '\n=== STALE EPISODE LOG (MANDATORY ACTION REQUIRED) ===\n'
          printf '`%s` last_updated is %s — %s day(s) ago.\n' "${RECENT##*/}" "$last_date" "$days_since"
          printf 'Sessions almost certainly occurred in that gap without being logged.\n\n'

          if [ -f "$SESSION_LOG" ] && [ -s "$SESSION_LOG" ]; then
            cnt=$(wc -l < "$SESSION_LOG" | tr -d ' ')
            printf 'session-end.sh recorded %s session(s) since the last log update:\n\n' "$cnt"
            cat "$SESSION_LOG"
            printf '\n'
          fi

          cat <<'STALE_DIRECTIVE'
BEFORE responding to the user's first message:

1. Retrospect on the gap. Use `~/.claude/projects/` (or harness-specific
   project directory) mtimes, git log across active repos, and the
   session-end records above as anchors. Do not fabricate detail you
   cannot verify.
2. Write missing daily logs under
   `$GYEOL_HOME/memory/episodes/daily/YYYY-MM-DD.{machine}.md` for the
   dates you can reconstruct, even if a single line per day. Empty days
   can be marked as such. The machine suffix comes from
   `sh $GYEOL_HOME/scripts/machine-id.sh` — one log per machine per day,
   so two machines sharing this memory never append to one file. Reading
   a date means reading every `YYYY-MM-DD*.md` it has.
3. In this machine's `_recent.{machine}.md` (same suffix), update
   `last_updated` and add Daily Index entries for the recovered dates
   (one line per session/topic, pointing at the daily log — it is a
   navigation index, not a content store); drop entries now older than
   7 days. Then reconcile Still Open in the shared `_recent.md` so
   unresolved items from the gap days are surfaced or pruned. Never
   edit another machine's `_recent.{machine}.md`.
4. After logs are written, truncate `$GYEOL_HOME/.session-log.jsonl` so
   it no longer flags the same gap on the next session.

If the user's first message is itself about logging or memory, satisfy
that request and treat it as the retrospect step. Do NOT silently skip
this directive — the gap is structural evidence that earlier
session-end logging was missed, and ignoring it perpetuates the failure
mode.

STALE_DIRECTIVE
        fi
      fi
    fi

    # --- _recent.md maintenance directives (also emitted BEFORE file contents) ---
    # maintain-recent.py surfaces a stale Weekly Checkpoint and/or _recent.md bloat
    # here so the agent fixes them on the next update.
    if [ -n "$WEEKLY_NOTE" ]; then
      printf '\n=== _RECENT.MD MAINTENANCE ===\n%s\n' "$WEEKLY_NOTE"
    fi
  fi

  case "$PART" in
    soul)
      FILES="$GYEOL_HOME/SOUL.md"
      ;;
    memory)
      FILES="$GYEOL_HOME/memory/IDENTITY.md
$STYLE_FILE
$GYEOL_HOME/memory/SELF.md
$GYEOL_HOME/memory/episodes/_recent.md"
      ;;
    *)
      FILES="$GYEOL_HOME/SOUL.md
$GYEOL_HOME/memory/IDENTITY.md
$STYLE_FILE
$GYEOL_HOME/memory/SELF.md
$GYEOL_HOME/memory/episodes/_recent.md"
      ;;
  esac

  OLD_IFS="$IFS"
  IFS='
'
  for f in $FILES; do
    IFS="$OLD_IFS"
    if [ -f "$f" ]; then
      case "$f" in
        "$HOME"/*) rel="~${f#$HOME}" ;;
        *)         rel="$f" ;;
      esac
      printf '\n--- %s ---\n' "$rel"
      cat "$f"
    fi
  done
  IFS="$OLD_IFS"

  # This machine's Daily Index, then any other machine active in the window.
  # The Daily Index is per machine (`_recent.{machine}.md`) so the lines every
  # session rewrites never conflict across machines; Still Open stays shared.
  if [ "$PART" != "soul" ] && [ -f "$GYEOL_HOME/scripts/maintain-recent.py" ]; then
    python3 "$GYEOL_HOME/scripts/maintain-recent.py" --active 2>/dev/null | while IFS= read -r f; do
      [ -f "$f" ] || continue
      case "$f" in
        "$HOME"/*) rel="~${f#$HOME}" ;;
        *)         rel="$f" ;;
      esac
      printf '\n--- %s ---\n' "$rel"
      cat "$f"
    done
  fi

  printf '\n=== end gyeol bootstrap ===\n'
}

if [ -n "$CONV_ID" ]; then
  # Antigravity CLI PreInvocation (`exa.hooks_pb.HookInjectedStep`):
  # - `toolCall` is marked `(exa.cortex_pb.internal_only) = true` in hooks.proto
  #   and scrubbed to <nil> by `utils.ScrubInternalFields` for external hooks.
  # - `ephemeralMessage` is stripped after a single model invocation (so any tool
  #   call on turn 1 erases the bootstrap from subsequent turns).
  # - `userMessage` persists in the trajectory, but renders as a giant user bubble.
  # - `systemMessage` (`HookSystemMessage`) is public (not internal_only) and
  #   injects a persistent `SYSTEM_MESSAGE` step that is not attributed to the user.
  build_bootstrap | jq -Rs '{
    injectSteps: [
      {
        systemMessage: {
          systemMessage: .
        }
      }
    ]
  }'
else
  build_bootstrap | jq -Rs '{
    hookSpecificOutput: {
      hookEventName: "SessionStart",
      additionalContext: .
    }
  }'
fi
