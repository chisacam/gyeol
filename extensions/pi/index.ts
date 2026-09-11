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
import { existsSync, readFileSync } from "node:fs";
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

// Providers allowed to receive memory, one `provider/id` glob per line in
// $GYEOL_HOME/trusted-providers (`#` comments and blank lines ignored).
//
// pi is the harness where this has to be decided per turn rather than per
// process: the model changes mid-session with /frontier, /local, or the model
// picker, and switching does not clear the conversation. Unlike Claude Code, a
// loopback endpoint here means the weights run on this machine, so it is
// trusted without being listed.
const TRUSTED_PROVIDERS = join(GYEOL_HOME, "trusted-providers");
const DEFAULT_TRUSTED = ["anthropic/*"];

function loadTrusted(): string[] {
  try {
    const lines = readFileSync(TRUSTED_PROVIDERS, "utf8")
      .split("\n")
      .map((line) => line.replace(/#.*$/, "").trim())
      .filter((line) => line.length > 0);
    return lines.length > 0 ? lines : DEFAULT_TRUSTED;
  } catch {
    return DEFAULT_TRUSTED;
  }
}

/** `*` matches any run of characters; nothing else is special. */
function globMatch(pattern: string, value: string): boolean {
  const escaped = pattern.split("*").map((part) => part.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")).join(".*");
  return new RegExp(`^${escaped}$`).test(value);
}

function baseUrlOf(ctx: ExtensionContext, provider: string): string | undefined {
  const registry = ctx.modelRegistry as unknown as { getProviderAuth?: (id: string) => { baseUrl?: string } | undefined };
  try {
    return registry?.getProviderAuth?.(provider)?.baseUrl;
  } catch {
    return undefined;
  }
}

/**
 * May this turn's model receive memory? A turn with no resolved model answers
 * no: "I could not tell" and "it is safe" are different answers, and only one
 * of them can be the default for something that cannot be un-sent.
 */
function trustOf(ctx: ExtensionContext): { trusted: boolean; reason: string } {
  const model = ctx.model as { provider?: string; id?: string } | undefined;
  if (!model?.provider || !model?.id) return { trusted: false, reason: "no model is resolved for this turn" };
  const full = `${model.provider}/${model.id}`;
  const baseUrl = baseUrlOf(ctx, model.provider);
  if (baseUrl && /^https?:\/\/(127\.0\.0\.1|localhost|0\.0\.0\.0|\[::1\])([:/]|$)/.test(baseUrl)) {
    return { trusted: true, reason: `${full} runs on this machine` };
  }
  const pattern = loadTrusted().find((p) => globMatch(p, full) || globMatch(p, model.id!));
  return pattern
    ? { trusted: true, reason: `${full} matches ${pattern} in ${TRUSTED_PROVIDERS}` }
    : { trusted: false, reason: `${full} is not listed in ${TRUSTED_PROVIDERS}` };
}

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
  trusted = true,
): Promise<ScriptResult | null> {
  if (!existsSync(script)) return null;

  try {
    const child = execFileAsync("sh", [script, ...args], {
      env: { ...process.env, GYEOL_HOME, GYEOL_TRUST: trusted ? "1" : "0" },
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
async function runScriptRaw(script: string, trusted = true): Promise<string | null> {
  if (!existsSync(script)) return null;

  try {
    const { stdout } = await execFileAsync("sh", [script], {
      env: { ...process.env, GYEOL_HOME, GYEOL_TRUST: trusted ? "1" : "0" },
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
  // The withheld-memory notice is given once per model, not once per turn, and
  // re-given when the user switches to a different untrusted model.
  let noticedFor: string | undefined;

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

  pi.on("before_agent_start", async (_event, ctx) => {
    const trust = trustOf(ctx);
    if (!trust.trusted) {
      // bootstrapPending is deliberately left standing: if the user switches
      // back to a trusted model later in this session, the identity arrives
      // then. Withholding is a property of the model, not of the session.
      const key = trust.reason;
      if (noticedFor === key) return;
      noticedFor = key;
      const notice = await runScriptRaw(BOOTSTRAP, false);
      if (!notice) return;
      return { message: { customType: "gyeol-trust-notice", content: notice, display: false } };
    }
    noticedFor = undefined;

    if (!bootstrapPending || bootstrapInjected) return;

    bootstrapPending = false;
    bootstrapInjected = true;

    // Pull first: the bootstrap is about to read IDENTITY/SELF/_recent, and
    // reading them before another machine's work arrives is how two machines
    // drift into two identities. A no-op unless memory/ is a synced repo.
    const sync = await runScript(SYNC_MEMORY, undefined, ["pull"], true);
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

  // Injection is not the only path memory takes to a provider. pi resends the
  // whole conversation each turn, so a session that bootstrapped on a trusted
  // model and then switched would ship the identity to the untrusted one.
  // These are gyeol's own messages, matched by customType rather than by
  // content, so nothing else in the conversation is touched.
  pi.on("context", (event, ctx) => {
    if (trustOf(ctx).trusted) return;
    const messages = event.messages.filter((message) => {
      const custom = message as { role?: string; customType?: string };
      return !(custom.role === "custom" && typeof custom.customType === "string" && custom.customType.startsWith("gyeol-bootstrap"));
    });
    return messages.length === event.messages.length ? undefined : { messages };
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

    const trusted = trustOf(ctx).trusted;

    if (FILE_MUTATING_TOOLS.has(event.toolName)) {
      // pi's edit/write tools are visible to this event, so — unlike Codex,
      // where apply_patch bypasses hooks entirely — pi can use the
      // unconditional marker the way Claude Code does.
      await runScript(MARK_SUBSTANTIVE, { session_id }, [], trusted);
      return;
    }

    if (command !== undefined) {
      const input = { session_id, tool_input: { command } };
      // The mutating-command pattern set lives in the shared script rather
      // than being duplicated here, so it stays consistent across harnesses.
      await runScript(MARK_IF_COMMIT, input, [], trusted);
      await runScript(MARK_RECOVERY, input, [], trusted);
    }
  });

  pi.on("agent_settled", async (_event, ctx) => {
    const result = await runScript(
      STOP_CHECK,
      { session_id: sessionId(ctx), stop_hook_active: false },
      [],
      trustOf(ctx).trusted,
    );
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

  pi.on("session_shutdown", async (_event, ctx) => {
    // The record is written either way — a withheld session still happened —
    // and session-end.sh marks it. Only the sync is skipped.
    const trusted = trustOf(ctx).trusted;
    await runScriptRaw(SESSION_END, trusted);
    await runScript(SYNC_MEMORY, undefined, ["push"], trusted);
  });
}
