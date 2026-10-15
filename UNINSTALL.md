# gyeol — Uninstallation Instructions for AI Agents

You are reading the uninstallation instructions for **gyeol**. Follow the steps below to remove gyeol from this system.

## Step 1: Determine GYEOL_HOME

| OS | GYEOL_HOME |
|----|------------|
| Linux / macOS | `~/.config/gyeol` |
| Windows | `%APPDATA%\gyeol` |

## Step 2: Remove gyeol block from global config

You are reading this document in one of the following agent systems:
- **Claude Code** (in `~/.claude/`)
- **Antigravity CLI** (in `~/.gemini/antigravity-cli/` or `~/.gemini/config/`)
- **OpenAI Codex** (in `~/.codex/`)
- **pi** (in `~/.pi/agent/`)

Remove gyeol from **only the agent system in which you are currently running this file**.

### Remove from global config

Identify your current agent system:

| Agent System | Global Config File |
|-------------|-------------------|
| Claude Code | `~/.claude/CLAUDE.md` |
| Antigravity CLI | `~/.gemini/GEMINI.md` (also check `~/.gemini/AGENTS.md`, `~/.gemini/config/GEMINI.md`, `~/.gemini/config/AGENTS.md`) |
| OpenAI Codex | `~/.codex/AGENTS.md` |
| pi | `~/.pi/agent/AGENTS.md` |

Open the global config file and remove everything between `<!-- gyeol:begin -->` and `<!-- gyeol:end -->` (inclusive). If the file is empty after removal, you may delete it.

## Step 3: Remove hooks and skills

Find the hook configuration file for your agent system:

| Agent System | Hook Config File |
|-------------|-------------------|
| Claude Code | `~/.claude/settings.json` |
| Antigravity CLI | `~/.gemini/config/hooks.json` |
| OpenAI Codex | `~/.codex/hooks.json` |
| pi | none — see Step 3.5 |

**If you are in pi, skip to Step 3.5.** pi has no hook settings file; gyeol never writes to `~/.pi/agent/settings.json`, so there is nothing here to unmerge.

Open the hook configuration file and remove the gyeol entries:

- **Claude Code** (`~/.claude/settings.json`): Remove gyeol entries across all of the following hook groups:
  - `hooks.SessionStart` — `sync-memory.sh pull` and `session-bootstrap-json.sh` (or legacy `session-bootstrap.sh`)
  - `hooks.PostToolUse` — `post-mark-substantive.sh` and `post-mark-recovery.sh` (there may be multiple entries, including `Write|Edit` and `Bash` matchers with conditional `if` clauses for `git commit:*` and `git show:*`)
  - `hooks.Stop` — `stop-check-daily.sh`
  - `hooks.SessionEnd` — `session-end.sh` and `sync-memory.sh push`
- **Antigravity CLI** (`~/.gemini/config/hooks.json`):
  - Remove the top-level `"gyeol"` named hook object (which contains `PreInvocation`, `PostToolUse`, and `Stop` entries referencing `~/.config/gyeol/scripts/`). If `~/.gemini/config/hooks.json` becomes empty (`{}`), you may delete the file.
  - Also remove `~/.gemini/config/skills/gyeol-capture` if present.
- **OpenAI Codex** (`~/.codex/hooks.json`): Remove gyeol entries across:
  - `hooks.SessionStart` — `session-bootstrap-json.sh`
  - `hooks.PostToolUse` — entries with matchers `Write|Edit` and `^Bash$` that reference `post-mark-substantive.sh`, `post-mark-substantive-if-commit.sh`, or `post-mark-recovery.sh`
  - `hooks.Stop` — `stop-check-daily.sh`
  - If `~/.codex/hooks.json` contains nothing but gyeol hooks, you may delete the file entirely. Codex's `~/.codex/config.toml` is a separate file and is not touched by gyeol.
  - Also remove `~/.codex/skills/gyeol-capture` if it is a standalone directory.

For each agent, after removing the individual gyeol entries, also drop any hook group wrapper objects that become empty. If the `hooks` object itself becomes empty, you may remove the entire `hooks` key. If other non-gyeol hooks remain, leave the surrounding structure in place.

If the hook configuration file becomes empty after cleanup, you may delete the file.

## Step 3.5: Remove gyeol's extension and skill directories

gyeol owns exactly one extension directory and one skill directory, and never modifies a neighboring one. Remove only these:

```bash
rm -rf ~/.pi/agent/extensions/gyeol          # pi integration (pi only)
rm -rf ~/.claude/skills/gyeol-capture        # whichever of these exist
rm -rf ~/.codex/skills/gyeol-capture
rm -rf ~/.pi/agent/skills/gyeol-capture
rm -rf ~/.gemini/config/skills/gyeol-capture
```

The `gyeol-capture` skill may be installed in more than one skills directory, because a machine's harnesses share a single memory tree. Leave every other extension and skill untouched.

## Step 3.6: Removing gyeol from one harness only

Skip this step if the user is removing gyeol from the machine entirely — Step 5 deletes `$GYEOL_HOME`, so nothing survives to reinstall anything.

Do it when gyeol stays installed in another harness (the common case: it is too heavy for one harness and wanted in another). Deleting the files is not enough there. `update-gyeol.sh` runs from whichever harness kept gyeol, and its three reconciliations — the instructions block, the `gyeol-capture` skill, the pi extension — are gated on nothing more than whether the harness directory exists. That directory outlives the removal because it holds the harness's *other* extensions and skills: `~/.pi/agent/extensions` still carries its neighbors after `~/.pi/agent/extensions/gyeol` is gone. So the deletion holds until the next check and then quietly comes back.

Record the intent where a reconciliation can read it — append the harness id to `$GYEOL_HOME/.disabled-harnesses`, one per line:

```bash
echo pi >> ~/.config/gyeol/.disabled-harnesses
```

Valid ids are `claude`, `codex`, `antigravity`, `pi`. `gemini`, the id from before Antigravity CLI replaced Gemini CLI, still disables the harness rooted at `~/.gemini`. `#` comments and surrounding whitespace are ignored; matching is on the whole line, so `pilot` does not disable `pi`. Both `update-gyeol.sh` and the agent-driven update path in `AGENTS.md` skip a listed harness — its config file, its skills directory and its extension directory alike. Delete the line to let it back in.

## Step 4: Ask user about memory data

**Before proceeding, ask the user explicitly:**

> gyeol's memory data is stored at `$GYEOL_HOME` (`~/.config/gyeol`). This includes identity, episodic memory, bonds, reflections, and semantic knowledge — everything accumulated through our interactions. Removing this data is irreversible on this machine (if `memory/` is a synced git repo, the remote and any other machine still hold it — say so, so the choice is made on accurate information). Would you like to:
>
> 1. **Keep memory data** — remove only the agent instructions and hooks (already done in Steps 2 and 3)
> 2. **Remove everything** — delete `$GYEOL_HOME` and all its contents permanently

**Do not proceed to Step 5 unless the user explicitly chooses option 2.**

## Step 5: Remove GYEOL_HOME (only if user confirmed)

```bash
rm -rf ~/.config/gyeol
```

## Step 6: Report to user

Report the following:

1. Which global config file was cleaned
2. Which hooks were removed and from which settings file, and which extension/skill directories were deleted
3. Whether the harness was recorded in `$GYEOL_HOME/.disabled-harnesses`, and that deleting that line lets gyeol back in
4. Whether memory data was preserved or removed
5. If memory was preserved, remind the user that `~/.config/gyeol/` still exists and can be re-activated by reinstalling gyeol
