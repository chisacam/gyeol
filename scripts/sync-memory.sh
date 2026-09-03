#!/usr/bin/env sh
# gyeol memory sync — share one memory tree across machines
#
# gyeol's premise is that identity lives in accumulated memory, and a person
# who works on two machines has one identity, not two. This syncs
# $GYEOL_HOME/memory (and nothing else — every machine-specific file lives
# outside it) through a git remote, pulling at session start and pushing at
# session end.
#
# Usage:
#   sync-memory.sh join <url>  # first-time setup: adopt an existing memory tree
#   sync-memory.sh pull        # SessionStart: bring in what other machines wrote
#   sync-memory.sh push        # SessionEnd: publish what this session wrote
#   sync-memory.sh status      # report without changing anything (default)
#
# The overriding safety rule is that a memory file must never contain conflict
# markers. The bootstrap reads these files as identity; `<<<<<<< HEAD` in
# SELF.md would be read as something the agent believes about itself. So a
# merge that conflicts is aborted, not left in the tree, and the divergence is
# reported instead.
#
# Nothing here ever blocks a session. An unconfigured sync, a missing git, an
# offline laptop, and a diverged remote all exit 0. Output is a SessionStart
# hook payload so it can be registered directly.

set -u

GYEOL_HOME="${GYEOL_HOME:-$HOME/.config/gyeol}"
MEM="$GYEOL_HOME/memory"
MODE="${1:-status}"

# Collected warnings, surfaced to the agent as session context.
NOTES=""

note() {
  NOTES="${NOTES}${NOTES:+ }$1"
}

emit_and_exit() {
  if [ -z "$NOTES" ]; then
    echo '{}'
    exit 0
  fi
  if command -v jq > /dev/null 2>&1; then
    jq -n --arg t "gyeol memory sync: $NOTES" '{
      hookSpecificOutput: {
        hookEventName: "SessionStart",
        additionalContext: $t
      }
    }'
  else
    echo '{}'
  fi
  exit 0
}

git_mem() {
  git -C "$MEM" "$@"
}

# --- join: the one mode that runs before a repo exists ----------------------
#
# Adopting an existing memory tree is the single destructive-if-wrong operation
# in gyeol. A machine that has already run gyeol has daily logs of its own, and
# the obvious move -- cloning the authoritative tree over it -- deletes them
# unrecoverably. So join never clones: it commits whatever is here, then merges
# the remote in as an unrelated history, and abandons the merge if it conflicts.

if [ "$MODE" = "join" ]; then
  REMOTE="${2:-}"
  if [ -z "$REMOTE" ]; then
    echo "usage: sync-memory.sh join <remote-url>" >&2
    exit 2
  fi
  command -v git > /dev/null 2>&1 || { echo "git is required to join a memory tree." >&2; exit 2; }
  mkdir -p "$MEM"

  if git -C "$MEM" remote get-url origin > /dev/null 2>&1; then
    echo "Already joined: $(git -C "$MEM" remote get-url origin)"
    echo "Use pull/push, or remove the remote first to re-join elsewhere."
    exit 0
  fi

  git -C "$MEM" rev-parse --git-dir > /dev/null 2>&1 || git -C "$MEM" init --quiet
  git -C "$MEM" remote add origin "$REMOTE" || exit 2

  # Which branch does the remote call its default?
  # awk, not sed: BSD sed does not understand \t, so a sed class built on it
  # silently swallows the tab and returns "main<TAB>HEAD" as the branch name.
  REMOTE_BRANCH=$(git -C "$MEM" ls-remote --symref origin HEAD 2>/dev/null \
    | awk '/^ref:/ { sub("refs/heads/", "", $2); print $2; exit }')
  [ -n "$REMOTE_BRANCH" ] || REMOTE_BRANCH=main

  if ! git -C "$MEM" fetch --quiet origin "$REMOTE_BRANCH" 2>/dev/null; then
    git -C "$MEM" remote remove origin > /dev/null 2>&1 || true
    echo "Could not fetch $REMOTE_BRANCH from $REMOTE. Nothing was changed." >&2
    exit 2
  fi

  # Put this machine's existing memory on a commit first, so the merge below
  # can only ever add to it.
  git -C "$MEM" symbolic-ref HEAD "refs/heads/$REMOTE_BRANCH" > /dev/null 2>&1 || true
  git -C "$MEM" add -A > /dev/null 2>&1
  if ! git -C "$MEM" diff --cached --quiet 2>/dev/null; then
    git -C "$MEM" commit --quiet --no-verify \
      -m "memory: $(hostname -s 2>/dev/null || echo unknown) before joining" > /dev/null 2>&1
  fi

  if git -C "$MEM" rev-parse --verify HEAD > /dev/null 2>&1; then
    if ! git -C "$MEM" merge --no-edit --quiet --allow-unrelated-histories FETCH_HEAD > /dev/null 2>&1; then
      git -C "$MEM" merge --abort > /dev/null 2>&1 || true
      echo "This machine's memory and the remote both define the same files, and the merge conflicts." >&2
      echo "Nothing was overwritten. Resolve by hand in $MEM, then run: sync-memory.sh push" >&2
      git -C "$MEM" diff --name-only HEAD FETCH_HEAD 2>/dev/null | sed 's/^/  conflicting: /' >&2
      exit 1
    fi
  else
    # Nothing local at all: this is a plain adoption.
    git -C "$MEM" merge --no-edit --quiet FETCH_HEAD > /dev/null 2>&1
  fi

  git -C "$MEM" branch --set-upstream-to="origin/$REMOTE_BRANCH" "$REMOTE_BRANCH" > /dev/null 2>&1 || true
  echo "Joined $REMOTE ($REMOTE_BRANCH)."
  if [ -f "$MEM/IDENTITY.md" ]; then
    echo "IDENTITY.md is present - First Activation will not run, and this machine keeps the existing identity."
  else
    echo "Warning: the remote carries no IDENTITY.md, so First Activation will still run here." >&2
  fi
  echo "Review the merge, then publish this machine's side with: sync-memory.sh push"
  exit 0
fi

# --- preconditions, all of which are "not configured", not "broken" ---------

[ -d "$MEM" ] || emit_and_exit
command -v git > /dev/null 2>&1 || emit_and_exit
git_mem rev-parse --git-dir > /dev/null 2>&1 || emit_and_exit
git_mem remote get-url origin > /dev/null 2>&1 || emit_and_exit

BRANCH=$(git_mem symbolic-ref --short HEAD 2>/dev/null) || BRANCH=""
if [ -z "$BRANCH" ]; then
  note "the memory repo has a detached HEAD; sync is paused until a branch is checked out."
  emit_and_exit
fi

# Commit whatever is sitting in the tree before touching the remote. A session
# that crashed, or one whose SessionEnd never fired, leaves written memory
# uncommitted; losing it to a merge would be the one unacceptable outcome.
commit_local() {
  git_mem add -A > /dev/null 2>&1 || return 1
  git_mem diff --cached --quiet 2>/dev/null && return 0
  git_mem -c user.useConfigOnly=false \
    commit --quiet --no-verify \
    -m "memory: $(hostname -s 2>/dev/null || echo unknown) $(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    > /dev/null 2>&1
}

# Merge FETCH_HEAD, or abort and say so. Never leaves the tree conflicted.
merge_fetched() {
  if git_mem merge --no-edit --quiet FETCH_HEAD > /dev/null 2>&1; then
    return 0
  fi
  git_mem merge --abort > /dev/null 2>&1 || git_mem reset --merge > /dev/null 2>&1 || true
  conflicts=$(git_mem diff --name-only origin/"$BRANCH"...HEAD 2>/dev/null | tr '\n' ' ')
  note "this machine and the remote have both changed memory and the merge conflicts, so it was abandoned and your local copy is untouched. Diverged: ${conflicts:-unknown}. Resolve by hand in $MEM before relying on memory being complete; _recent.md and today's daily log are the usual culprits, and semantics indices can just be regenerated with build-index.py."
  return 1
}

case "$MODE" in
  pull)
    commit_local || note "could not commit local memory changes before pulling."
    if ! git_mem fetch --quiet origin "$BRANCH" > /dev/null 2>&1; then
      note "could not reach the memory remote, so this session starts from the local copy. Anything written now still commits locally and pushes on the next successful sync."
      emit_and_exit
    fi
    merge_fetched
    emit_and_exit
    ;;

  push)
    commit_local || {
      note "could not commit this session's memory."
      emit_and_exit
    }
    if git_mem push --quiet origin "$BRANCH" > /dev/null 2>&1; then
      emit_and_exit
    fi
    # Rejected: the remote moved while this session ran. Integrate, then retry.
    if ! git_mem fetch --quiet origin "$BRANCH" > /dev/null 2>&1; then
      note "this session's memory is committed locally but could not be pushed (remote unreachable). The next pull will carry it up."
      emit_and_exit
    fi
    if merge_fetched; then
      git_mem push --quiet origin "$BRANCH" > /dev/null 2>&1 \
        || note "this session's memory is committed locally but the push was rejected twice. Push $MEM by hand."
    fi
    emit_and_exit
    ;;

  status)
    ahead=$(git_mem rev-list --count origin/"$BRANCH"..HEAD 2>/dev/null || echo "?")
    behind=$(git_mem rev-list --count HEAD..origin/"$BRANCH" 2>/dev/null || echo "?")
    dirty=$(git_mem status --porcelain 2>/dev/null | wc -l | tr -d ' ')
    echo "memory:  $MEM"
    echo "remote:  $(git_mem remote get-url origin)"
    echo "branch:  $BRANCH"
    echo "ahead:   $ahead commit(s) not pushed"
    echo "behind:  $behind commit(s) not pulled"
    echo "dirty:   $dirty uncommitted path(s)"
    exit 0
    ;;

  *)
    echo "usage: sync-memory.sh [join <url>|pull|push|status]" >&2
    exit 0
    ;;
esac
