// gyeol — pi harness integration
//
// pi (https://github.com/earendil-works/pi-mono) has no shell-hook engine:
// there is no SessionStart / PostToolUse / Stop equivalent that runs a command
// and reads its stdout. What it has instead is a TypeScript extension API with
// a full lifecycle event set. This extension is the adapter between the two.
//
// It deliberately shells out to the same scripts every other harness uses,
// feeding each one the Claude-Code-shaped hook JSON it already parses, rather
// than reimplementing their logic in TypeScript. The enforcement rules
// (which commands count as substantive, what the daily-log demand says, when
// to nag softly) then live in exactly one place for every harness.
//
// Event mapping:
//
//   Claude Code hook   pi event                     notes
//   ----------------   --------------------------   ---------------------------
//   SessionStart       session_start +              session_start cannot return
//                      before_agent_start           a message; injection is
//                                                   deferred to the first turn
//   PostToolUse        tool_execution_start/_end    args arrive on _start,
//                                                   success on _end
//   Stop               agent_settled                pi cannot block; the demand
//                                                   is delivered as a follow-up
//                                                   message that restarts the
//                                                   agent instead
//   SessionEnd         session_shutdown             append-only evidence record
//
// When the memory tree is a synced git repo, the same two session edges carry
// sync-memory.sh: pull before the bootstrap reads the files, push after the
// evidence record is written.

import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";
import { execFile } from "node:child_process";
import { existsSync } from "node:fs";
import { homedir } from "node:os";
import { basename, join } from "node:path";
import { promisify } from "node:util";

const execFileAsync = promisify(execFile);

const GYEOL_HOME = process.env.GYEOL_HOME ?? join(homedir(), ".config", "gyeol");
const SCRIPTS = join(GYEOL_HOME, "scripts");

const BOOTSTRAP = join(SCRIPTS, "session-bootstrap.sh");
const MARK_SUBSTANTIVE = join(SCRIPTS, "post-mark-substantive.sh");
const MARK_IF_COMMIT = join(SCRIPTS, "post-mark-substantive-if-commit.sh");
const MARK_RECOVERY = join(SCRIPTS, "post-mark-recovery.sh");
const STOP_CHECK = join(SCRIPTS, "stop-check-daily.sh");
const SESSION_END = join(SCRIPTS, "session-end.sh");
const SYNC_MEMORY = join(SCRIPTS, "sync-memory.sh");

// Session reasons that begin a fresh transcript. "resume", "fork", and
// "reload" reload a transcript that already carries an earlier bootstrap
// injection, and re-firing would stack a duplicate copy — the same rule
// session-bootstrap-json.sh applies to Claude Code's `source=resume`.
const FRESH_SESSION_REASONS = new Set(["startup", "new"]);

// pi's built-in tools are read, bash, powershell (Windows), edit, write, grep,
// find, ls. Only the two that mutate files count as unconditionally
// substantive; shell commands are filtered by content downstream.
const FILE_MUTATING_TOOLS = new Set(["edit", "write"]);
const SHELL_TOOLS = new Set(["bash", "powershell"]);

interface ScriptResult {
  decision?: string;
  reason?: string;
  systemMessage?: string;
  hookSpecificOutput?: { additionalContext?: string };
}

/**
 * Run a gyeol hook script with `input` on stdin and parse its stdout as JSON.
 *
 * Every failure mode is swallowed by design: a missing script, a non-zero
 * exit, or unparseable stdout must never take pi down or interrupt a turn.
 * That mirrors the `2>/dev/null || true` the shell-hook harnesses wrap each
 * command in.
 */
async function runScript(
  script: string,
  input: unknown,
  args: string[] = [],
): Promise<ScriptResult | null> {
  if (!existsSync(script)) return null;

  try {
    const child = execFileAsync("sh", [script, ...args], {
      env: { ...process.env, GYEOL_HOME },
      maxBuffer: 8 * 1024 * 1024,
    });

    if (input !== undefined) {
      child.child.stdin?.end(JSON.stringify(input));
    }

    const { stdout } = await child;
    const trimmed = stdout.trim();
    if (!trimmed) return null;

    try {
      return JSON.parse(trimmed) as ScriptResult;
    } catch {
      return null;
    }
  } catch {
    return null;
  }
}

/** Same as runScript but returns raw stdout — the bootstrap emits prose, not JSON. */
async function runScriptRaw(script: string): Promise<string | null> {
  if (!existsSync(script)) return null;

  try {
    const { stdout } = await execFileAsync("sh", [script], {
      env: { ...process.env, GYEOL_HOME },
      maxBuffer: 8 * 1024 * 1024,
    });
    const trimmed = stdout.trim();
    return trimmed || null;
  } catch {
    return null;
  }
}

export default function (pi: ExtensionAPI) {
  // Per-session bootstrap state. `before_agent_start` is a per-turn event, so
  // these two flags enforce the once-per-session contract session-bootstrap.sh
  // documents; without them every turn would re-inject ~3.8k tokens.
  let bootstrapPending = false;
  let bootstrapInjected = false;

  // tool_execution_end carries the result but not the args, so shell commands
  // are captured on _start and read back on _end (keyed by tool call).
  const shellCommands = new Map<string, string>();

  // Flag files under /tmp are keyed by session id. pi identifies a session by
  // its file path; ephemeral sessions (--no-session) get a process-scoped id so
  // their flags still pair up within the run.
  const ephemeralId = `pi-ephemeral-${process.pid}`;
  function sessionId(ctx: ExtensionContext): string {
    const file = ctx.sessionManager?.getSessionFile?.();
    if (!file) return ephemeralId;
    return basename(file).replace(/\.jsonl$/, "");
  }

  pi.on("session_start", async (event) => {
    bootstrapPending = FRESH_SESSION_REASONS.has(event.reason);
    bootstrapInjected = false;
    shellCommands.clear();
  });

  pi.on("before_agent_start", async () => {
    if (!bootstrapPending || bootstrapInjected) return;

    bootstrapPending = false;
    bootstrapInjected = true;

    // Pull first: the bootstrap is about to read IDENTITY/SELF/_recent, and
    // reading them before another machine's work arrives is how two machines
    // drift into two identities. A no-op unless memory/ is a synced repo.
    const sync = await runScript(SYNC_MEMORY, undefined, ["pull"]);
    const syncNote = sync?.hookSpecificOutput?.additionalContext;

    const content = await runScriptRaw(BOOTSTRAP);
    const body = [syncNote, content].filter(Boolean).join("\n\n");
    if (!body) return;

    return {
      message: {
        customType: "gyeol-bootstrap",
        content: body,
        display: false,
      },
    };
  });

  pi.on("tool_execution_start", async (event) => {
    if (!SHELL_TOOLS.has(event.toolName)) return;
    const command = (event.args as { command?: unknown } | undefined)?.command;
    if (typeof command === "string") {
      shellCommands.set(event.toolCallId, command);
    }
  });

  pi.on("tool_execution_end", async (event, ctx) => {
    const command = shellCommands.get(event.toolCallId);
    shellCommands.delete(event.toolCallId);

    // A tool that failed changed nothing worth remembering.
    if (event.isError) return;

    const session_id = sessionId(ctx);

    if (FILE_MUTATING_TOOLS.has(event.toolName)) {
      // pi's edit/write tools are visible to this event, so — unlike Codex,
      // where apply_patch bypasses hooks entirely — pi can use the
      // unconditional marker the way Claude Code does.
      await runScript(MARK_SUBSTANTIVE, { session_id });
      return;
    }

    if (command !== undefined) {
      const input = { session_id, tool_input: { command } };
      // The mutating-command pattern set lives in the shared script rather
      // than being duplicated here, so it stays consistent across harnesses.
      await runScript(MARK_IF_COMMIT, input);
      await runScript(MARK_RECOVERY, input);
    }
  });

  pi.on("agent_settled", async (_event, ctx) => {
    const result = await runScript(STOP_CHECK, {
      session_id: sessionId(ctx),
      stop_hook_active: false,
    });
    if (!result) return;

    // pi has no Stop-hook veto and no AfterAgent "deny", so the demand is
    // delivered as a follow-up message with triggerTurn instead: the agent
    // picks the work back up rather than being refused an exit it never
    // asked for. stop-check-daily.sh's own nagged flag bounds this to one
    // hard demand per session, so the follow-up cannot loop.
    if (result.decision && result.reason) {
      pi.sendMessage(
        {
          customType: "gyeol-stop-check",
          content: result.reason,
          display: true,
        },
        { deliverAs: "followUp", triggerTurn: true },
      );
      return;
    }

    if (result.systemMessage) {
      ctx.ui.notify(result.systemMessage, "info");
    }
  });

  pi.on("session_shutdown", async () => {
    await runScriptRaw(SESSION_END);
    await runScript(SYNC_MEMORY, undefined, ["push"]);
  });
}
