#!/usr/bin/env node
// triple-review-broker-cleanup
//
// Tear down the codex plugin's app-server broker that triple-review's
// bare-CLI ADV reviewer creates. Without this, the broker re-parents to
// PID 1 after the auto-handoff session quits, the auto-handoff
// `SessionEnd` hook stalls trying to gracefully shut it down, and the
// user sees `SessionEnd hook ... failed: Hook cancelled`. Issue #162;
// ADR 0012 §"Known side effect — orphan broker after auto-handoff
// session quit".
//
// Subcommands:
//   snapshot <cwd>            stdout: {"existed":bool}
//                             Checks whether broker.json exists for the
//                             workspace. The pre-snapshot is fed back to
//                             `teardown` so we only clean up brokers we
//                             actually created — concurrent same-repo
//                             Claude Code sessions remain untouched.
//
//   teardown <cwd> <snapshot> No-op if snapshot.existed === true OR if
//                             broker.json is currently absent. Otherwise
//                             calls the plugin's broker-lifecycle.mjs
//                             API: graceful shutdown via the broker
//                             socket, then process kill + sessionDir
//                             cleanup.
//
// Plugin-upgrade fragility: imports `loadBrokerSession`, `sendBrokerShutdown`,
// `teardownBrokerSession`, `clearBrokerSession` from the codex plugin cache
// at runtime. `private_dot_claude/settings.json` pins `autoUpdate: false`
// for the openai-codex marketplace, so a manual `/plugin update` is the
// only thing that can change the cached API surface. If the API surface
// changes incompatibly, this helper exits non-zero; triple-review catches
// the failure and emits a warn — the review run still succeeds, but the
// orphan-broker side effect returns until the helper is updated.

import fs from "node:fs";
import path from "node:path";
import process from "node:process";
import { pathToFileURL } from "node:url";

const DEFAULT_CACHE_ROOT = path.join(
  process.env.HOME ?? "",
  ".claude",
  "plugins",
  "cache",
  "openai-codex",
  "codex"
);

// Highest installed version wins (matches `resolve_codex_companion` in
// triple-review). Numeric-aware compare so 1.0.10 sorts after 1.0.9.
function naturalCompare(a, b) {
  return a.localeCompare(b, undefined, { numeric: true, sensitivity: "base" });
}

function resolveCodexLibDir() {
  const cacheRoot = process.env.CODEX_COMPANION_CACHE_ROOT || DEFAULT_CACHE_ROOT;
  if (!fs.existsSync(cacheRoot)) {
    throw new Error(`codex plugin cache not found at ${cacheRoot}`);
  }
  const versions = fs
    .readdirSync(cacheRoot, { withFileTypes: true })
    .filter((entry) => entry.isDirectory())
    .map((entry) => entry.name)
    .sort(naturalCompare);
  if (versions.length === 0) {
    throw new Error(`no codex plugin versions installed under ${cacheRoot}`);
  }
  const libDir = path.join(cacheRoot, versions[versions.length - 1], "scripts", "lib");
  if (!fs.existsSync(libDir)) {
    throw new Error(`codex plugin lib dir missing: ${libDir}`);
  }
  return libDir;
}

async function loadLib() {
  const libDir = resolveCodexLibDir();
  const lifecycle = await import(pathToFileURL(path.join(libDir, "broker-lifecycle.mjs")));
  const procLib = await import(pathToFileURL(path.join(libDir, "process.mjs")));
  return { lifecycle, procLib };
}

async function snapshot(cwd) {
  const { lifecycle } = await loadLib();
  const session = lifecycle.loadBrokerSession(cwd);
  process.stdout.write(`${JSON.stringify({ existed: session !== null })}\n`);
}

async function teardown(cwd, snapshotJson) {
  let snap;
  try {
    snap = JSON.parse(snapshotJson);
  } catch (err) {
    throw new Error(`malformed snapshot argument: ${err.message}`);
  }
  // Conservative skip: if a broker existed before our run, a concurrent
  // session owns it. Tearing it down would break that session. There is
  // no per-process ownership tracking in the plugin to do better than
  // this heuristic.
  if (snap?.existed === true) {
    return;
  }
  const { lifecycle, procLib } = await loadLib();
  const session = lifecycle.loadBrokerSession(cwd);
  if (!session) {
    return;
  }
  if (session.endpoint) {
    try {
      await lifecycle.sendBrokerShutdown(session.endpoint);
    } catch {
      // Graceful shutdown is best-effort — `teardownBrokerSession` below
      // SIGKILLs the broker pid and unlinks the socket regardless.
    }
  }
  lifecycle.teardownBrokerSession({
    endpoint: session.endpoint ?? null,
    pidFile: session.pidFile ?? null,
    logFile: session.logFile ?? null,
    sessionDir: session.sessionDir ?? null,
    pid: session.pid ?? null,
    killProcess: procLib.terminateProcessTree
  });
  lifecycle.clearBrokerSession(cwd);
}

async function main() {
  const [, , subcommand, cwd, snapshotArg] = process.argv;
  if (!subcommand || !cwd) {
    process.stderr.write(
      "Usage: triple-review-broker-cleanup <snapshot|teardown> <cwd> [<snapshot-json>]\n"
    );
    process.exit(2);
  }
  if (subcommand === "snapshot") {
    await snapshot(cwd);
    return;
  }
  if (subcommand === "teardown") {
    if (!snapshotArg) {
      process.stderr.write("teardown requires a snapshot JSON argument\n");
      process.exit(2);
    }
    await teardown(cwd, snapshotArg);
    return;
  }
  process.stderr.write(`unknown subcommand: ${subcommand}\n`);
  process.exit(2);
}

main().catch((err) => {
  process.stderr.write(`triple-review-broker-cleanup: ${err.message ?? err}\n`);
  process.exit(1);
});
