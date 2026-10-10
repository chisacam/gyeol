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

Remove gyeol from **only the agent system in which you are currently running this file**.

### Remove from global config

Identify your current agent system:

| Agent System | Global Config File |
|-------------|-------------------|
| Claude Code | `~/.claude/CLAUDE.md` |
| Antigravity CLI | `~/.gemini/GEMINI.md` (also check `~/.gemini/AGENTS.md`, `~/.gemini/config/GEMINI.md`, `~/.gemini/config/AGENTS.md`) |
| OpenAI Codex | `~/.codex/AGENTS.md` |

Open the global config file and remove everything between `<!-- gyeol:begin -->` and `<!-- gyeol:end -->` (inclusive). If the file is empty after removal, you may delete it.

## Step 3: Remove hooks and skills

Find the hook configuration file for your agent system:

| Agent System | Hook Config File |
|-------------|-------------------|
| Claude Code | `~/.claude/settings.json` |
| Antigravity CLI | `~/.gemini/config/hooks.json` |
| OpenAI Codex | `~/.codex/hooks.json` |

Open the hook configuration file and remove the gyeol entries:

- **Claude Code** (`~/.claude/settings.json`): Remove gyeol entries across all of the following hook groups:
  - `hooks.SessionStart` — `session-bootstrap-json.sh` (or legacy `session-bootstrap.sh`)
  - `hooks.PostToolUse` — `post-mark-substantive.sh` and `post-mark-recovery.sh` (there may be multiple entries, including `Write|Edit` and `Bash` matchers with conditional `if` clauses for `git commit:*` and `git show:*`)
  - `hooks.Stop` — `stop-check-daily.sh`
  - `hooks.SessionEnd` — `session-end.sh`
  - Also remove `~/.claude/skills/gyeol-capture` if present.
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

## Step 4: Ask user about memory data

**Before proceeding, ask the user explicitly:**

> gyeol's memory data is stored at `$GYEOL_HOME` (`~/.config/gyeol`). This includes identity, episodic memory, bonds, reflections, and semantic knowledge — everything accumulated through our interactions. Removing this data is irreversible. Would you like to:
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
2. Which hooks and skills were removed and from which configuration files
3. Whether memory data was preserved or removed
4. If memory was preserved, remind the user that `~/.config/gyeol/` still exists and can be re-activated by reinstalling gyeol
