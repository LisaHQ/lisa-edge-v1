// Shared Matter Server WebSocket client for LISA Edge tooling.
//
// Executed INSIDE the lisa-matter container (which ships Node.js and the
// `ws` module) via:  docker exec -i -e MWS_... lisa-matter node - < ws-client.js
// Unit tests run it directly with a mocked `ws` module on NODE_PATH.
//
// All inputs arrive through MWS_* environment variables so the Thread
// dataset never appears in process arguments, shell history, or logs.
// Output is machine-readable `key=value` lines on stdout; diagnostics go to
// stderr. Server-provided text is sanitized so credential material can never
// leak through error details.
//
// Commands (MWS_COMMAND):
//   server-info   connect, validate schema, print server info fields
//   status        server-info + fabric label + credentials + node count
//   credentials   server-info + list stored Thread credential summaries
//   sync          set_thread_dataset(MWS_DATASET), then verify through
//                 server_info and get_all_credentials
//   remove        remove_thread_dataset(), verify removal
//
// The Matter server's RESERVED DEFAULT Thread credential is LISA Edge's
// managed commissioning credential. MWS_CREDENTIAL_ID selects the target
// entry; the value "default" is normalized to the upstream reserved-default
// semantics: set_thread_dataset/remove_thread_dataset are sent WITHOUT an
// `id` field (clients such as Home Assistant read and write the same entry
// without supplying an ID). Entries returned by get_all_credentials with a
// missing/null ID are normalized internally to "default". Named credentials
// remain supported for inspection and explicit cleanup only.
//
// Exit codes (stable, used by callers and tests):
//   0 success, 2 usage error, 3 connect failure, 4 server rejected command,
//   5 timeout, 6 unsupported schema, 7 verification failed

"use strict";

let WebSocket;
try {
  WebSocket = require("ws");
} catch {
  // noinspection NpmUsedModulesInstalled,JSFileReferences — resolves inside the lisa-matter container only
  WebSocket = require("/app/node_modules/ws");
}

const HOST = process.env.MWS_HOST || "127.0.0.1";
const PORT = Number(process.env.MWS_PORT || 5580);
const COMMAND = process.env.MWS_COMMAND || "";
const DATASET = process.env.MWS_DATASET || "";
const CREDENTIAL_ID = process.env.MWS_CREDENTIAL_ID || "";
const MIN_SCHEMA = Number(process.env.MWS_MIN_SCHEMA || 12);
const CONNECT_TIMEOUT_MS = Number(process.env.MWS_CONNECT_TIMEOUT_MS || 10000);
const RESPONSE_TIMEOUT_MS = Number(process.env.MWS_RESPONSE_TIMEOUT_MS || 15000);

const EXIT = { OK: 0, USAGE: 2, CONNECT: 3, REJECTED: 4, TIMEOUT: 5, SCHEMA: 6, VERIFY: 7 };

// The Matter server's reserved default Thread credential slot. Operations
// targeting it must omit the `id` field (upstream default semantics).
const DEFAULT_ID = "default";
const TARGET_IS_DEFAULT = CREDENTIAL_ID === DEFAULT_ID;

let ws = null;
let finished = false;
let messageSeq = 0;
const pending = new Map(); // message_id -> {resolve, reject, timer}
let connectTimer = null;
let serverInfoTimer = null;

function fail(code, message) {
  process.stderr.write(`ERROR: ${sanitize(message)}\n`);
  finish(code);
  const abort = new Error("aborted");
  abort.handled = true;
  throw abort;
}

// fail() throws (also from timers and socket handlers) so no code path can
// continue past a reported error; the marker keeps Node from treating the
// controlled abort as a crash.
process.on("uncaughtException", (err) => {
  if (err && err.handled) return;
  process.stderr.write(`ERROR: ${sanitize(err && err.message ? err.message : String(err))}\n`);
  finish(EXIT.CONNECT);
});

// Replace any long hex run (potential dataset/key material) before printing
// text that originated from the server or from input validation.
function sanitize(text) {
  return String(text).replace(/[0-9A-Fa-f]{32,}/g, "[REDACTED]");
}

function out(key, value) {
  process.stdout.write(`${key}=${sanitize(value)}\n`);
}

function usage(message) {
  fail(EXIT.USAGE, message);
}

if (!["server-info", "status", "credentials", "sync", "remove"].includes(COMMAND)) {
  usage(`unsupported MWS_COMMAND: ${COMMAND || "(empty)"}`);
}
if (COMMAND === "sync") {
  if (!/^[0-9A-Fa-f]+$/.test(DATASET) || DATASET.length % 2 !== 0) {
    usage("MWS_DATASET must be a non-empty even-length hex string");
  }
  if (!CREDENTIAL_ID) usage("MWS_CREDENTIAL_ID is required for sync ('default' targets the reserved default entry)");
}
if (COMMAND === "remove" && !CREDENTIAL_ID) {
  usage("MWS_CREDENTIAL_ID is required for remove ('default' targets the reserved default entry)");
}

// Never call process.exit() directly: piped stdout/stderr writes are
// asynchronous in Node and an immediate exit can truncate output mid-line.
// Instead clear everything keeping the event loop alive so the process
// drains its streams and exits naturally; an unref'd hard timeout guards
// against a peer that never completes the close handshake.
function finish(code) {
  if (finished) {
    process.exitCode = process.exitCode || code;
    return;
  }
  finished = true;
  process.exitCode = code;
  if (connectTimer) clearTimeout(connectTimer);
  if (serverInfoTimer) clearTimeout(serverInfoTimer);
  for (const waiter of pending.values()) clearTimeout(waiter.timer);
  pending.clear();
  if (ws) {
    try { ws.removeAllListeners(); } catch { /* best effort */ }
    try { ws.close(); } catch { /* already closed */ }
    try { ws.terminate?.(); } catch { /* not supported by mocks */ }
  }
  const hardExit = setTimeout(() => process.exit(code), 2000);
  hardExit.unref?.();
}

ws = new WebSocket(`ws://${HOST}:${PORT}/ws`);

connectTimer = setTimeout(() => {
  if (!finished) fail(EXIT.CONNECT, `timed out connecting to ws://${HOST}:${PORT}/ws`);
}, CONNECT_TIMEOUT_MS);

ws.on("error", (err) => {
  if (!finished) fail(EXIT.CONNECT, `websocket error: ${err.message}`);
});

ws.on("close", () => {
  if (!finished) fail(EXIT.CONNECT, "websocket closed before the exchange completed");
});

let serverInfoResolve;
const serverInfo = new Promise((resolve) => { serverInfoResolve = resolve; });
serverInfoTimer = setTimeout(() => {
  if (!finished) fail(EXIT.TIMEOUT, "timed out waiting for server info");
}, RESPONSE_TIMEOUT_MS);

ws.on("message", (raw) => {
  let msg;
  try {
    msg = JSON.parse(raw);
  } catch {
    return; // ignore malformed frames
  }
  if (msg === null || typeof msg !== "object") return;
  // First object carrying schema_version without a message_id is the server
  // info sent on connect (python-matter-server compatible behavior).
  if (msg.message_id === undefined) {
    if (msg.schema_version !== undefined && serverInfoResolve) {
      clearTimeout(serverInfoTimer);
      serverInfoResolve(msg);
      serverInfoResolve = null;
    }
    return; // events and unrelated frames are ignored
  }
  const waiter = pending.get(msg.message_id);
  if (!waiter) return; // response to someone else's command
  pending.delete(msg.message_id);
  clearTimeout(waiter.timer);
  if (msg.error_code !== undefined && msg.error_code !== null) {
    waiter.reject(new Error(`server rejected ${waiter.command}: ` +
      `error_code=${msg.error_code}${msg.details ? ` details=${msg.details}` : ""}`));
  } else {
    waiter.resolve(msg.result);
  }
});

function call(command, args) {
  const messageId = `lisa-${command}-${process.pid}-${messageSeq++}`;
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => {
      pending.delete(messageId);
      reject(Object.assign(new Error(`timed out waiting for ${command} response`), { isTimeout: true }));
    }, RESPONSE_TIMEOUT_MS);
    pending.set(messageId, { resolve, reject, timer, command });
    ws.send(JSON.stringify({ message_id: messageId, command, args: args || {} }));
  });
}

function printServerInfo(info) {
  for (const field of [
    "schema_version", "min_supported_schema_version", "sdk_version",
    "server_version", "wifi_credentials_set", "thread_credentials_set",
    "bluetooth_enabled",
  ]) {
    if (info[field] !== undefined && info[field] !== null) {
      out(`server.${field}`, info[field]);
    }
  }
}

function threadEntries(credentials) {
  const thread = credentials && Array.isArray(credentials.thread) ? credentials.thread : [];
  return thread.map((entry) => ({
    // A missing/null ID is the reserved default entry (upstream default
    // semantics); normalize it internally to "default".
    id: entry.id === undefined || entry.id === null ? DEFAULT_ID : String(entry.id),
    networkName: entry.networkName === undefined || entry.networkName === null
      ? "" : String(entry.networkName),
    extPanId: entry.extPanId === undefined || entry.extPanId === null
      ? "" : String(entry.extPanId).toUpperCase(),
  }));
}

// True when the entry carries actual Thread identity fields. The server can
// return an always-present EMPTY default summary; that alone never counts
// as a configured credential.
function entryHasIdentity(entry) {
  return Boolean(entry) && (entry.networkName !== "" || entry.extPanId !== "");
}

// Machine-readable summary of the reserved default credential. `configured`
// requires both a non-empty identity summary and the server reporting
// thread_credentials_set=true.
function printDefaultSummary(entries, threadCredentialsSet) {
  const entry = entries.find((candidate) => candidate.id === DEFAULT_ID);
  const configured = entryHasIdentity(entry) && threadCredentialsSet === true;
  out("default.present", Boolean(entry));
  out("default.configured", configured);
  out("default.network_name", entry ? entry.networkName : "");
  out("default.ext_pan_id", entry ? entry.extPanId : "");
}

function printThreadEntries(entries) {
  out("thread_credential_count", entries.length);
  entries.forEach((entry, index) => {
    out(`thread_credential.${index}.id`, entry.id);
    out(`thread_credential.${index}.network_name`, entry.networkName);
    // Extended PAN IDs are public identity fields, not secrets; print them
    // through a path that the long-hex redaction does not touch (16 chars is
    // below the redaction threshold anyway).
    out(`thread_credential.${index}.ext_pan_id`, entry.extPanId);
  });
}

async function main() {
  await new Promise((resolve) => ws.on("open", resolve));
  clearTimeout(connectTimer);

  const info = await serverInfo;
  if (typeof info.schema_version !== "number" || info.schema_version < MIN_SCHEMA) {
    printServerInfo(info);
    fail(EXIT.SCHEMA,
      `server schema_version ${info.schema_version} is older than required ${MIN_SCHEMA}`);
  }
  printServerInfo(info);

  if (COMMAND === "server-info") {
    finish(EXIT.OK);
    return;
  }

  if (COMMAND === "status") {
    try {
      const label = await call("get_fabric_label");
      out("fabric_label", label && label.fabric_label !== null && label.fabric_label !== undefined
        ? label.fabric_label : "");
    } catch (err) {
      process.stderr.write(`WARNING: ${sanitize(err.message)}\n`);
    }
    const entries = threadEntries(await call("get_all_credentials"));
    printThreadEntries(entries);
    printDefaultSummary(entries, info.thread_credentials_set);
    try {
      const nodes = await call("get_nodes");
      out("node_count", Array.isArray(nodes) ? nodes.length : 0);
    } catch (err) {
      process.stderr.write(`WARNING: ${sanitize(err.message)}\n`);
    }
    finish(EXIT.OK);
    return;
  }

  if (COMMAND === "credentials") {
    const entries = threadEntries(await call("get_all_credentials"));
    printThreadEntries(entries);
    printDefaultSummary(entries, info.thread_credentials_set);
    finish(EXIT.OK);
    return;
  }

  if (COMMAND === "sync") {
    // Reserved default entry: omit `id` (upstream default semantics).
    await call("set_thread_dataset",
      TARGET_IS_DEFAULT ? { dataset: DATASET } : { dataset: DATASET, id: CREDENTIAL_ID });

    // The handshake's thread_credentials_set predates the write; re-read it.
    let credsSet;
    if (TARGET_IS_DEFAULT) {
      try {
        const refreshed = await call("server_info");
        if (refreshed && typeof refreshed === "object") {
          credsSet = refreshed.thread_credentials_set;
        }
      } catch (err) {
        process.stderr.write(`WARNING: server_info re-read failed: ${sanitize(err.message)}\n`);
      }
      if (credsSet === undefined || credsSet === null) {
        // Fall back to the handshake value (true only when credentials were
        // already set before this sync).
        credsSet = info.thread_credentials_set;
      }
      // Distinct key: server.thread_credentials_set already carries the
      // (pre-sync) handshake value earlier in the output.
      out("sync.thread_credentials_set", credsSet === true);
    }

    const entries = threadEntries(await call("get_all_credentials"));
    const stored = entries.find((entry) => entry.id === CREDENTIAL_ID);
    if (!stored || (TARGET_IS_DEFAULT && !entryHasIdentity(stored))) {
      printThreadEntries(entries);
      fail(EXIT.VERIFY, TARGET_IS_DEFAULT
        ? "the reserved default credential is missing or empty after set_thread_dataset"
        : `stored credential '${CREDENTIAL_ID}' was not returned by get_all_credentials`);
    }
    if (TARGET_IS_DEFAULT && credsSet !== true) {
      printThreadEntries(entries);
      fail(EXIT.VERIFY,
        "the server does not report thread_credentials_set=true after storing the default credential");
    }
    out("stored.id", stored.id);
    out("stored.network_name", stored.networkName);
    out("stored.ext_pan_id", stored.extPanId);
    out("sync.result", "ok");
    finish(EXIT.OK);
    return;
  }

  if (COMMAND === "remove") {
    // Reserved default entry: omit `id` (upstream default semantics).
    await call("remove_thread_dataset", TARGET_IS_DEFAULT ? {} : { id: CREDENTIAL_ID });
    const entries = threadEntries(await call("get_all_credentials"));
    const remaining = entries.find((entry) => entry.id === CREDENTIAL_ID);
    // The server may keep an always-present EMPTY default summary; only a
    // default entry that still carries identity fields fails verification.
    if (TARGET_IS_DEFAULT ? entryHasIdentity(remaining) : Boolean(remaining)) {
      fail(EXIT.VERIFY, `credential '${CREDENTIAL_ID}' is still stored after removal`);
    }
    out("remove.result", "ok");
    finish(EXIT.OK);
  }
}

main().catch((err) => {
  try {
    if (err && err.handled) return;
    if (err && err.isTimeout) fail(EXIT.TIMEOUT, err.message);
    if (err && /^server rejected /.test(err.message || "")) fail(EXIT.REJECTED, err.message);
    fail(EXIT.CONNECT, err && err.message ? err.message : String(err));
  } catch (abort) {
    if (!abort || !abort.handled) throw abort;
  }
});
