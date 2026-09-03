#!/usr/bin/env node
// Behavioural test for the pi extension.
//
// Builds a throwaway GYEOL_HOME from this repository's scripts/, drives the
// extension through a stub pi harness, and asserts on the side effects the
// real scripts produce. Nothing outside the temp directory (and the /tmp flag
// files the scripts own) is touched.
//
// Requires Node 22.6+ for native TypeScript type stripping, and jq, which the
// marker scripts use to parse their stdin.
//
// Usage: node extensions/pi/test.mjs

import { execFileSync } from "node:child_process";
import { cpSync, existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const repo = join(here, "..", "..");

try {
  execFileSync("sh", ["-c", "command -v jq"], { stdio: "ignore" });
} catch {
  console.log("SKIP  jq is not installed; the marker scripts cannot run without it.");
  process.exit(0);
}

const home = mkdtempSync(join(tmpdir(), "gyeol-pi-test-"));
process.env.GYEOL_HOME = home;
mkdirSync(join(home, "memory", "episodes", "daily"), { recursive: true });
cpSync(join(repo, "scripts"), join(home, "scripts"), { recursive: true });
cpSync(join(repo, "SOUL.md"), join(home, "SOUL.md"));

const SESSION_ID = "gyeol-pi-test";
const flag = (suffix) => `/tmp/gyeol_session_${SESSION_ID}.${suffix}`;
const FLAGS = ["substantive", "recovery", "nagged"].map(flag);
const clearFlags = () => FLAGS.forEach((f) => rmSync(f, { force: true }));

let passed = 0;
let failed = 0;
function check(label, got, want) {
  if (got === want) {
    passed++;
    console.log(`PASS  ${label}`);
  } else {
    failed++;
    console.log(`FAIL  ${label} (got ${JSON.stringify(got)}, want ${JSON.stringify(want)})`);
  }
}

function cleanup() {
  clearFlags();
  rmSync(home, { recursive: true, force: true });
}
process.on("exit", cleanup);

clearFlags();

// --- stub pi harness -------------------------------------------------------

const { default: factory } = await import(join(here, "index.ts"));

const handlers = new Map();
const sentMessages = [];
const notifications = [];
const pi = {
  on: (name, fn) => handlers.set(name, fn),
  sendMessage: (message, options) => sentMessages.push({ message, options }),
};
await factory(pi);

const ctx = {
  ui: { notify: (text, level) => notifications.push({ text, level }) },
  sessionManager: { getSessionFile: () => `/tmp/pi-sessions/${SESSION_ID}.jsonl` },
};

const fire = (name, event, context = ctx) => handlers.get(name)(event, context);

// --- bootstrap -------------------------------------------------------------

await fire("session_start", { reason: "startup" });
const firstTurn = await fire("before_agent_start", {});
check("bootstrap is injected on a fresh session", Boolean(firstTurn?.message), true);
check("bootstrap carries the identity files", (firstTurn?.message?.content?.length ?? 0) > 1000, true);
check("bootstrap is not shown in the transcript", firstTurn?.message?.display, false);

check("no re-injection on the next turn", Boolean(await fire("before_agent_start", {})), false);

await fire("session_start", { reason: "resume" });
check("no injection on resume", Boolean(await fire("before_agent_start", {})), false);

await fire("session_start", { reason: "fork" });
check("no injection on fork", Boolean(await fire("before_agent_start", {})), false);

await fire("session_start", { reason: "new" });
check("injection returns for a new session", Boolean(await fire("before_agent_start", {})), true);

// --- substantive and recovery marking --------------------------------------

clearFlags();

await fire("tool_execution_end", { toolCallId: "t1", toolName: "read", isError: false });
check("read does not mark the session substantive", existsSync(flag("substantive")), false);

await fire("tool_execution_end", { toolCallId: "t2", toolName: "write", isError: true });
check("a failed write does not mark the session", existsSync(flag("substantive")), false);

await fire("tool_execution_end", { toolCallId: "t3", toolName: "edit", isError: false });
check("edit marks the session substantive", existsSync(flag("substantive")), true);

clearFlags();
await fire("tool_execution_start", { toolCallId: "t4", toolName: "bash", args: { command: "ls -la" } });
await fire("tool_execution_end", { toolCallId: "t4", toolName: "bash", isError: false });
check("a read-only shell command does not mark the session", existsSync(flag("substantive")), false);

await fire("tool_execution_start", { toolCallId: "t5", toolName: "bash", args: { command: "git commit -m wip" } });
await fire("tool_execution_end", { toolCallId: "t5", toolName: "bash", isError: false });
check("git commit marks the session substantive", existsSync(flag("substantive")), true);

await fire("tool_execution_start", { toolCallId: "t6", toolName: "bash", args: { command: "git show HEAD:notes.md" } });
await fire("tool_execution_end", { toolCallId: "t6", toolName: "bash", isError: false });
check("git show HEAD: records a recovery incident", existsSync(flag("recovery")), true);

// --- stop check ------------------------------------------------------------

await fire("agent_settled", {});
check("a substantive session with no daily log is re-engaged", sentMessages.length, 1);
check("the demand is delivered as a follow-up", sentMessages[0]?.options?.deliverAs, "followUp");
check("the follow-up restarts the agent", sentMessages[0]?.options?.triggerTurn, true);
check("the demand names the daily log", /daily log/.test(sentMessages[0]?.message?.content ?? ""), true);
check("the demand carries the Incidents hint", /Incidents/.test(sentMessages[0]?.message?.content ?? ""), true);
check("the session is marked as nagged", existsSync(flag("nagged")), true);

await fire("agent_settled", {});
check("the hard demand fires only once", sentMessages.length, 1);
check("later settles fall back to a soft reminder", notifications.length, 1);

const today = new Date().toISOString().slice(0, 10);
writeFileSync(join(home, "memory", "episodes", "daily", `${today}.md`), "# today\n");
sentMessages.length = 0;
notifications.length = 0;
await fire("agent_settled", {});
check("an existing daily log settles silently", sentMessages.length + notifications.length, 0);
check("the session flags are cleaned up", FLAGS.some(existsSync), false);

// --- session end -----------------------------------------------------------

await fire("session_shutdown", { reason: "quit" });
const evidence = join(home, ".session-log.jsonl");
check("session end leaves an evidence record", existsSync(evidence), true);
if (existsSync(evidence)) {
  const last = JSON.parse(readFileSync(evidence, "utf8").trim().split("\n").pop());
  check("the record carries an end timestamp", typeof last.end, "string");
  check("the record carries a cwd", typeof last.cwd, "string");
}

// --- ephemeral sessions ----------------------------------------------------

const ephemeralCtx = { ...ctx, sessionManager: { getSessionFile: () => null } };
const ephemeralFlag = `/tmp/gyeol_session_pi-ephemeral-${process.pid}.substantive`;
await fire("tool_execution_end", { toolCallId: "t7", toolName: "write", isError: false }, ephemeralCtx);
check("an ephemeral session still marks substantive work", existsSync(ephemeralFlag), true);
rmSync(ephemeralFlag, { force: true });

// --- memory sync on the session edges ---------------------------------------

// sync-memory.sh is a no-op unless memory/ is a synced repo, which is the
// state the checks above ran under. Give it a repo with an unreachable remote
// so it has something to say, and confirm the warning reaches the agent
// alongside the bootstrap rather than being swallowed.
execFileSync("git", ["init", "--quiet", "--initial-branch=main", join(home, "memory")]);
execFileSync("git", ["-C", join(home, "memory"), "config", "user.name", "test"]);
execFileSync("git", ["-C", join(home, "memory"), "config", "user.email", "test@example.com"]);
execFileSync("git", ["-C", join(home, "memory"), "remote", "add", "origin",
                     join(home, "unreachable.git")]);

await fire("session_start", { reason: "new" });
const synced = await fire("before_agent_start", {});
check(
  "an unreachable memory remote is reported to the agent",
  /gyeol memory sync/.test(synced?.message?.content ?? ""),
  true,
);
check(
  "the bootstrap still follows the sync warning",
  /gyeol session bootstrap/.test(synced?.message?.content ?? ""),
  true,
);
check(
  "session work is committed even when the remote is gone",
  execFileSync("git", ["-C", join(home, "memory"), "status", "--porcelain"]).toString().trim(),
  "",
);

// --- missing installation --------------------------------------------------

process.env.GYEOL_HOME = join(home, "does-not-exist");
const { default: orphanFactory } = await import(`${join(here, "index.ts")}?missing`);
const orphanHandlers = new Map();
await orphanFactory({ on: (n, fn) => orphanHandlers.set(n, fn), sendMessage: () => {} });
await orphanHandlers.get("session_start")({ reason: "startup" }, ctx);
check(
  "a missing installation degrades silently",
  Boolean(await orphanHandlers.get("before_agent_start")({}, ctx)),
  false,
);
process.env.GYEOL_HOME = home;

console.log(`\n${passed} passed, ${failed} failed`);
process.exitCode = failed ? 1 : 0;
