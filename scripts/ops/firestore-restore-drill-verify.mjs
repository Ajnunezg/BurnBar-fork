#!/usr/bin/env node
/**
 * Data verification and receipts for the Firestore restore drill.
 *
 * scripts/ops/run-firestore-restore-drill.sh restores production into a
 * throwaway `dr-drill-*` database. A finished restore operation proves little
 * on its own, so this module compares data: it runs a COUNT aggregation for
 * each collection group against the source database at the snapshot time and
 * against the restored database, then writes the redaction-safe receipt
 * (docs/schemas/firestore-restore-drill-receipt.schema.json) that
 * scripts/commercial-launch-gate.mjs requires.
 *
 * The drill script calls these subcommands; operators run the drill script:
 *   preflight  reject bad drill configuration before anything is restored
 *   counts     count each collection group in the source and restored databases
 *   receipt    evaluate the drill, write the receipt and the latest pointer
 *
 * The access token arrives in FIRESTORE_DRILL_ACCESS_TOKEN, never argv, and is
 * only sent to firestore.googleapis.com or a loopback test server.
 */
import { mkdirSync, readFileSync, renameSync, writeFileSync } from "node:fs";
import { dirname } from "node:path";
import process from "node:process";
import { fileURLToPath } from "node:url";
import { parseArgs } from "node:util";
import { RFC3339, isObject, validateAgainstSchema } from "../lib/json-schema-subset.mjs";

export const DEFAULT_COLLECTION_GROUPS = Object.freeze(["entitlements", "cloud_vault_key_wrappers", "usage"]);
export const RESTORE_DRILL_COMMAND =
  "GCLOUD_PROJECT=burnbar bash scripts/ops/run-firestore-restore-drill.sh";
/** The launch gate's receipt TTL: fresh for launch, well inside the quarterly cadence. */
export const DEFAULT_RESTORE_DRILL_TTL_DAYS = 30;

const RECEIPT_SCHEMA = "openburnbar.firestore-restore-drill-receipt.v1";
const RECEIPT_SCHEMA_PATH = "docs/schemas/firestore-restore-drill-receipt.schema.json";
const FIRESTORE_API_BASE = "https://firestore.googleapis.com/v1";
const COUNT_ALIAS = "count";
const COLLECTION_GROUP_PATTERN = /^[A-Za-z0-9_-]{1,100}$/u;
const LOOPBACK_HOSTS = new Set(["127.0.0.1", "localhost", "[::1]"]);
const REQUEST_TIMEOUT_MS = 180_000;
const MINUTE_MS = 60_000;
const DAY_MS = 24 * 60 * MINUTE_MS;
const FUTURE_SKEW_MS = 5 * MINUTE_MS;

/** Bad drill configuration, flags or environment: the CLI exits 64. */
class UsageError extends Error {}

/** A failed count. `message` is redaction-safe; `detail` is Firestore's text, for the log only. */
class CountFailure extends Error {
  constructor(message, detail = "") {
    super(message);
    this.detail = detail;
  }
}

/** Collection groups to count: FIRESTORE_DRILL_COLLECTION_GROUPS (comma list) or the defaults. */
export function parseCollectionGroups(raw) {
  if (raw === undefined || raw.trim() === "") return [...DEFAULT_COLLECTION_GROUPS];
  const groups = raw.split(",").map((group) => group.trim());
  const invalid = groups.find((group) => !COLLECTION_GROUP_PATTERN.test(group));
  if (invalid !== undefined) {
    throw new UsageError(`FIRESTORE_DRILL_COLLECTION_GROUPS has an invalid collection group: "${invalid}"`);
  }
  if (new Set(groups).size !== groups.length) {
    throw new UsageError("FIRESTORE_DRILL_COLLECTION_GROUPS lists a collection group twice");
  }
  return groups;
}

/**
 * The REST base the counts go to. The access token rides along, so anything
 * other than Firestore itself or a loopback test server is refused. Only
 * Firestore itself makes a live drill.
 */
export function resolveApiBase(raw) {
  const base = (raw || FIRESTORE_API_BASE).replace(/\/+$/u, "");
  let url;
  try {
    url = new URL(base);
  } catch {
    throw new UsageError(`FIRESTORE_DRILL_API_BASE is not a URL: ${base}`);
  }
  const live = url.protocol === "https:" && url.hostname === "firestore.googleapis.com";
  const loopback = ["http:", "https:"].includes(url.protocol) && LOOPBACK_HOSTS.has(url.hostname);
  if (!live && !loopback) {
    throw new UsageError(
      "FIRESTORE_DRILL_API_BASE must be https://firestore.googleapis.com/... or a loopback " +
        "test server; the access token is never sent anywhere else",
    );
  }
  return { base, live };
}

/**
 * Whole-minute read times around `timestamp`. PITR reads older than one hour
 * must use a whole minute, so a backup's sub-minute snapshotTime is read at
 * the minute on each side. Null when `timestamp` is not RFC 3339.
 */
export function minuteBounds(timestamp) {
  const match = RFC3339.exec(typeof timestamp === "string" ? timestamp : "");
  if (!match) return null;
  const [, minute, seconds, fraction = "", zone] = match;
  const floor = Date.parse(`${minute}:00${zone}`);
  if (!Number.isFinite(floor)) return null;
  const whole = seconds === "00" && !/[1-9]/u.test(fraction);
  const iso = (millis) => new Date(millis).toISOString().replace(".000Z", "Z");
  return { floor: iso(floor), ceil: iso(whole ? floor : floor + MINUTE_MS) };
}

/** runAggregationQuery body: COUNT(*) over every collection with this ID. */
export function countAggregationRequest(collectionGroup, readTime) {
  return {
    structuredAggregationQuery: {
      structuredQuery: { from: [{ collectionId: collectionGroup, allDescendants: true }] },
      aggregations: [{ alias: COUNT_ALIAS, count: {} }],
    },
    ...(readTime ? { readTime } : {}),
  };
}

/** The count from a runAggregationQuery response stream (a JSON array over REST). */
export function parseCountResponse(payload) {
  const messages = Array.isArray(payload) ? payload : [payload];
  const value = messages.find((message) => message?.result?.aggregateFields?.[COUNT_ALIAS])
    ?.result.aggregateFields[COUNT_ALIAS].integerValue;
  const text = typeof value === "number" ? String(value) : value;
  if (typeof text !== "string" || !/^\d+$/u.test(text) || !Number.isSafeInteger(Number(text))) {
    throw new CountFailure("the response carried no integer count");
  }
  return Number(text);
}

const STATUS_HINTS = {
  UNAUTHENTICATED: "the access token was rejected; run gcloud auth login and retry",
  PERMISSION_DENIED:
    "the operator needs datastore.entities.get and datastore.entities.list, both in roles/datastore.viewer",
  FAILED_PRECONDITION:
    "a collection-group index is missing or the read time is outside the PITR window; " +
    "the drill log has Firestore's message",
  INVALID_ARGUMENT: "a read time older than one hour must be a whole minute inside the PITR window",
  DEADLINE_EXCEEDED:
    "the count outran the server deadline; retry, or narrow FIRESTORE_DRILL_COLLECTION_GROUPS",
  NOT_FOUND: "the database does not exist",
  RESOURCE_EXHAUSTED: "quota exhausted; retry later",
  UNAVAILABLE: "Firestore was unavailable; retry",
};

function apiFailure(httpStatus, error, body) {
  const status = /^[A-Z_]{1,40}$/u.test(error?.status ?? "") ? error.status : `HTTP ${httpStatus}`;
  const hint = STATUS_HINTS[status];
  return new CountFailure(hint ? `${status} (${hint})` : status, error?.message ?? body.slice(0, 500));
}

async function runCount({ api, project, databaseId, collectionGroup, readTime, token, fetchImpl }) {
  const parent = `projects/${encodeURIComponent(project)}/databases/${encodeURIComponent(databaseId)}/documents`;
  let response;
  let body;
  try {
    response = await fetchImpl(`${api.base}/${parent}:runAggregationQuery`, {
      method: "POST",
      headers: { authorization: `Bearer ${token}`, "content-type": "application/json" },
      body: JSON.stringify(countAggregationRequest(collectionGroup, readTime)),
      signal: AbortSignal.timeout(REQUEST_TIMEOUT_MS),
    });
    body = await response.text();
  } catch (error) {
    throw new CountFailure(
      error?.name === "TimeoutError"
        ? `no response within ${REQUEST_TIMEOUT_MS / 1000}s`
        : "the request failed before Firestore answered (network or TLS error)",
      error?.message,
    );
  }
  let payload = null;
  try {
    payload = JSON.parse(body);
  } catch {
    // A non-JSON body fails below, as an HTTP error or as a missing count.
  }
  const error = (Array.isArray(payload) ? payload.find((message) => message?.error) : payload)?.error;
  if (!response.ok || error) throw apiFailure(response.status, error, body);
  return parseCountResponse(payload);
}

function sourceReadTimes(mode, snapshotTime) {
  if (mode === "clone") return snapshotTime ? [snapshotTime] : null;
  const bounds = minuteBounds(snapshotTime);
  return bounds && [...new Set([bounds.floor, bounds.ceil])];
}

/**
 * Count every collection group in the source (at the snapshot time) and in
 * the restored database. A failed read becomes a redaction-safe entry error
 * rather than an exception, so one bad read still yields a complete receipt.
 */
export async function collectDrillCounts({
  mode,
  project,
  sourceDatabaseId,
  restoreDatabaseId,
  snapshotTime,
  collectionGroups,
  api,
  token,
  fetchImpl = fetch,
  log = () => {},
}) {
  const readTimes = sourceReadTimes(mode, snapshotTime);
  const entries = [];
  for (const collectionGroup of collectionGroups) {
    const errors = [];
    const count = async (label, databaseId, readTime) => {
      try {
        return await runCount({ api, project, databaseId, collectionGroup, readTime, token, fetchImpl });
      } catch (error) {
        if (!(error instanceof CountFailure)) throw error;
        log(`FAIL: ${collectionGroup} ${label} count: ${error.message}${error.detail ? ` — ${error.detail}` : ""}`);
        errors.push(`${collectionGroup}: ${label} count failed: ${error.message}`);
        return null;
      }
    };
    let sourceCount = null;
    if (readTimes === null) {
      errors.push(`${collectionGroup}: the source snapshot time is unknown, so the source was not counted`);
    } else {
      const reads = [];
      for (const readTime of readTimes) reads.push(await count(`source at ${readTime}`, sourceDatabaseId, readTime));
      if (!reads.includes(null)) {
        sourceCount = mode === "clone" ? reads[0] : { floor: reads[0], ceil: reads.at(-1) };
      }
    }
    const restoredCount = await count("restored", restoreDatabaseId);
    log(`==> ${collectionGroup}: source ${JSON.stringify(sourceCount)}, restored ${restoredCount}`);
    entries.push({ collectionGroup, sourceCount, restoredCount, errors });
  }
  return entries;
}

function sourceRange(sourceCount) {
  if (Number.isInteger(sourceCount)) return [sourceCount, sourceCount];
  if (!isObject(sourceCount)) return null;
  return [Math.min(sourceCount.floor, sourceCount.ceil), Math.max(sourceCount.floor, sourceCount.ceil)];
}

/** Add `match` (restored count inside the source range) and `vacuous` (source empty). */
export function evaluateCollectionCount(entry) {
  const range = sourceRange(entry.sourceCount);
  return {
    ...entry,
    match:
      range !== null &&
      Number.isInteger(entry.restoredCount) &&
      entry.restoredCount >= range[0] &&
      entry.restoredCount <= range[1],
    vacuous: range !== null && range[1] === 0,
  };
}

function mismatchFailure({ collectionGroup, sourceCount, restoredCount }) {
  const range = sourceRange(sourceCount);
  if (range === null || !Number.isInteger(restoredCount)) {
    return `${collectionGroup}: the source or restored count is missing`;
  }
  const [low, high] = range;
  const expected = low === high ? `${low}` : `between ${low} and ${high}`;
  return `${collectionGroup}: restored count ${restoredCount} does not match the source count ${expected}`;
}

/**
 * The drill passes only when the source posture held, the restore finished,
 * every collection group matched, at least one held data, and the drill's own
 * cleanup deleted the drill database. `counts` are evaluated entries, or null
 * when count verification produced nothing.
 */
export function evaluateRestoreDrill({
  postureOk,
  restoreStarted,
  operationDone,
  captureOk,
  counts,
  cleanupRequested,
  databaseDeleted,
}) {
  const failures = [];
  if (!postureOk) failures.push("the source DR posture check failed; see the drill's .posture.json");
  if (!restoreStarted) {
    failures.push("the restore did not start; the drill log has the gcloud error");
  } else if (!operationDone) {
    failures.push("the restore operation did not finish cleanly (error or timeout); the drill log has its status");
  }
  if (operationDone) {
    if (!captureOk) failures.push("could not describe the restored database or list its indexes");
    if (counts === null || counts.length === 0) {
      failures.push("count verification produced no results; the drill log has the error");
    } else {
      for (const entry of counts) {
        if (entry.errors?.length > 0) failures.push(...entry.errors);
        else if (!entry.match) failures.push(mismatchFailure(entry));
      }
      if (counts.every((entry) => entry.vacuous)) {
        failures.push("every collection group was empty at the snapshot time; an all-empty restore proves nothing");
      }
    }
  }
  if (!cleanupRequested) {
    failures.push(
      "cleanup-disabled: FIRESTORE_DRILL_CLEANUP=0 kept the drill database; a retained clone never counts as a passed drill",
    );
  } else if (restoreStarted && !databaseDeleted) {
    failures.push("the drill database was not deleted; delete it by hand (see the drill log)");
  }
  return { ok: failures.length === 0, failures };
}

/** Build the receipt from the drill script's phase results. */
export function createFirestoreRestoreDrillReceipt(facts, { live, now = new Date() }) {
  const counts = facts.counts === null ? null : facts.counts.map(evaluateCollectionCount);
  const { ok, failures } = evaluateRestoreDrill({ ...facts, counts });
  return {
    schema: RECEIPT_SCHEMA,
    schemaVersion: 1,
    generatedAt: now.toISOString(),
    mode: facts.mode,
    liveDrill: live,
    ok,
    source: { databaseId: facts.sourceDatabaseId, snapshotTime: facts.snapshotTime || null },
    restore: {
      databaseId: facts.restoreDatabaseId,
      operationDone: facts.operationDone,
      elapsedSeconds: facts.operationDone ? facts.elapsedSeconds : null,
    },
    counts: (counts ?? []).map(({ collectionGroup, sourceCount, restoredCount, match, vacuous }) => ({
      collectionGroup,
      sourceCount,
      restoredCount,
      match,
      vacuous,
    })),
    cleanup: { requested: facts.cleanupRequested, databaseDeleted: facts.databaseDeleted },
    posture: { ok: facts.postureOk },
    failures,
  };
}

let receiptSchema;

/** Errors from validating `receipt` against docs/schemas/firestore-restore-drill-receipt.schema.json. */
export function validateFirestoreRestoreDrillReceipt(receipt) {
  receiptSchema ??= JSON.parse(readFileSync(new URL(`../../${RECEIPT_SCHEMA_PATH}`, import.meta.url), "utf8"));
  return validateAgainstSchema(receipt, receiptSchema);
}

/**
 * Launch-gate verdict on a restore-drill receipt: it must be a live, passing,
 * schema-valid drill that verified real data and is at most `maxAgeDays` old.
 * Every failure carries the command that produces a fresh receipt.
 */
export function evaluateFirestoreRestoreDrillEvidence(
  receipt,
  { now = new Date(), maxAgeDays = DEFAULT_RESTORE_DRILL_TTL_DAYS } = {},
) {
  if (!isObject(receipt)) {
    return {
      ok: false,
      maxAgeDays,
      failures: ["the receipt is missing or is not a JSON object"],
      command: RESTORE_DRILL_COMMAND,
    };
  }
  const nowMillis = new Date(now).getTime();
  const failures = [];
  if (receipt.schema !== RECEIPT_SCHEMA || receipt.schemaVersion !== 1) {
    failures.push(`schema is ${JSON.stringify(receipt.schema)} v${receipt.schemaVersion}; expected ${RECEIPT_SCHEMA} v1`);
  }
  if (receipt.liveDrill !== true) failures.push("not a live drill (liveDrill is not true)");
  if (receipt.ok !== true) {
    const reasons = Array.isArray(receipt.failures) ? receipt.failures.join("; ") : "";
    failures.push(`the drill did not pass${reasons ? `: ${reasons}` : ""}`);
  }
  if (!Number.isFinite(maxAgeDays) || maxAgeDays <= 0) {
    failures.push("the restore-drill TTL must be a positive number of days");
  }
  const generatedAt = typeof receipt.generatedAt === "string" ? Date.parse(receipt.generatedAt) : Number.NaN;
  let ageDays = null;
  if (!Number.isFinite(generatedAt)) {
    failures.push("generatedAt is missing or invalid");
  } else if (generatedAt - nowMillis > FUTURE_SKEW_MS) {
    failures.push("generatedAt is in the future");
  } else {
    ageDays = Math.max(0, Math.round(((nowMillis - generatedAt) / DAY_MS) * 100) / 100);
    if (ageDays > maxAgeDays) {
      failures.push(`the receipt is ${Math.floor(ageDays)} days old; re-run the drill at least every ${maxAgeDays} days`);
    }
  }
  const counts = Array.isArray(receipt.counts) ? receipt.counts : [];
  const unmatched = counts.filter((entry) => entry?.match !== true).map((entry) => entry?.collectionGroup);
  if (counts.length === 0) failures.push("no collection group was verified");
  if (unmatched.length > 0) failures.push(`restored counts did not match the source for: ${unmatched.join(", ")}`);
  if (counts.length > 0 && counts.every((entry) => entry?.vacuous !== false)) {
    failures.push("no verified collection group held data; an all-empty restore proves nothing");
  }
  if (receipt.restore?.operationDone !== true) failures.push("the restore operation did not complete");
  if (receipt.cleanup?.requested !== true || receipt.cleanup?.databaseDeleted !== true) {
    failures.push("the drill did not delete its drill database");
  }
  if (receipt.posture?.ok !== true) failures.push("the source DR posture check did not pass");
  try {
    const schemaErrors = validateFirestoreRestoreDrillReceipt(receipt);
    if (schemaErrors.length > 0) {
      failures.push(`does not conform to ${RECEIPT_SCHEMA_PATH}: ${schemaErrors.slice(0, 5).join("; ")}`);
    }
  } catch (error) {
    failures.push(`cannot validate against ${RECEIPT_SCHEMA_PATH}: ${error.message}`);
  }
  return {
    ok: failures.length === 0,
    generatedAt: receipt.generatedAt ?? null,
    ageDays,
    maxAgeDays,
    mode: receipt.mode ?? null,
    failures,
    ...(failures.length > 0 ? { command: RESTORE_DRILL_COMMAND } : {}),
  };
}

/** Read and evaluate a receipt file such as launch-evidence/latest-firestore-restore-drill.json. */
export function readFirestoreRestoreDrillEvidence(path, options = {}) {
  let receipt;
  try {
    receipt = JSON.parse(readFileSync(path, "utf8"));
  } catch (error) {
    return {
      ok: false,
      path,
      failures: [error.code === "ENOENT" ? `missing ${path}` : `unreadable ${path}: ${error.message}`],
      command: RESTORE_DRILL_COMMAND,
    };
  }
  return { path, ...evaluateFirestoreRestoreDrillEvidence(receipt, options) };
}

const CLI_OPTIONS = Object.fromEntries(
  [
    "mode", "project", "source-database", "restore-database", "snapshot-time", "posture-ok",
    "restore-started", "operation-done", "elapsed-seconds", "capture-ok", "counts",
    "cleanup-requested", "database-deleted", "out", "latest",
  ].map((name) => [name, { type: "string" }]),
);

function requiredFlag(values, name) {
  if (values[name] === undefined) throw new UsageError(`--${name} is required`);
  return values[name];
}

function booleanFlag(values, name) {
  const value = requiredFlag(values, name);
  if (value !== "true" && value !== "false") throw new UsageError(`--${name} must be true or false`);
  return value === "true";
}

function drillIdentity(values) {
  return {
    mode: requiredFlag(values, "mode"),
    sourceDatabaseId: requiredFlag(values, "source-database"),
    restoreDatabaseId: requiredFlag(values, "restore-database"),
    snapshotTime: values["snapshot-time"] || null,
  };
}

function writeJson(path, value) {
  mkdirSync(dirname(path), { recursive: true });
  const temporary = `${path}.${process.pid}.tmp`;
  writeFileSync(temporary, `${JSON.stringify(value, null, 2)}\n`);
  renameSync(temporary, path);
}

function readCounts(path) {
  try {
    const counts = JSON.parse(readFileSync(path, "utf8"));
    return Array.isArray(counts) ? counts : null;
  } catch {
    return null;
  }
}

async function main(argv, env = process.env) {
  const [command, ...args] = argv;
  const { values } = parseArgs({ args, options: CLI_OPTIONS, strict: true });
  const api = resolveApiBase(env.FIRESTORE_DRILL_API_BASE);

  if (command === "preflight") {
    const collectionGroups = parseCollectionGroups(env.FIRESTORE_DRILL_COLLECTION_GROUPS);
    // Build an empty receipt now so a bad mode, database ID or snapshot time
    // fails before a multi-hour restore instead of when the receipt is written.
    const probe = createFirestoreRestoreDrillReceipt(
      {
        ...drillIdentity(values),
        postureOk: false,
        restoreStarted: false,
        operationDone: false,
        captureOk: false,
        counts: [],
        cleanupRequested: true,
        databaseDeleted: false,
      },
      { live: api.live },
    );
    const errors = validateFirestoreRestoreDrillReceipt(probe);
    if (errors.length > 0) throw new UsageError(`drill configuration would not yield a valid receipt: ${errors.join("; ")}`);
    console.error(`==> will count ${collectionGroups.join(", ")} via ${api.live ? "firestore.googleapis.com" : `test server ${api.base}`}`);
    return 0;
  }

  if (command === "counts") {
    const out = requiredFlag(values, "out");
    const token = env.FIRESTORE_DRILL_ACCESS_TOKEN;
    if (!token) {
      throw new UsageError("FIRESTORE_DRILL_ACCESS_TOKEN is required; the drill script passes gcloud's token through the environment");
    }
    const counts = await collectDrillCounts({
      ...drillIdentity(values),
      project: requiredFlag(values, "project"),
      collectionGroups: parseCollectionGroups(env.FIRESTORE_DRILL_COLLECTION_GROUPS),
      api,
      token,
      log: (line) => console.error(line),
    });
    writeJson(out, counts);
    return 0;
  }

  if (command === "receipt") {
    const out = requiredFlag(values, "out");
    const latest = requiredFlag(values, "latest");
    const operationDone = booleanFlag(values, "operation-done");
    const elapsedSeconds = values["elapsed-seconds"] ? Number(values["elapsed-seconds"]) : null;
    if (elapsedSeconds !== null && !(Number.isInteger(elapsedSeconds) && elapsedSeconds >= 0)) {
      throw new UsageError("--elapsed-seconds must be a whole number of seconds");
    }
    const receipt = createFirestoreRestoreDrillReceipt(
      {
        ...drillIdentity(values),
        postureOk: booleanFlag(values, "posture-ok"),
        restoreStarted: booleanFlag(values, "restore-started"),
        operationDone,
        elapsedSeconds,
        captureOk: booleanFlag(values, "capture-ok"),
        counts: operationDone ? readCounts(requiredFlag(values, "counts")) : [],
        cleanupRequested: booleanFlag(values, "cleanup-requested"),
        databaseDeleted: booleanFlag(values, "database-deleted"),
      },
      { live: api.live },
    );
    const errors = validateFirestoreRestoreDrillReceipt(receipt);
    if (errors.length > 0) throw new Error(`refusing to write a receipt that violates ${RECEIPT_SCHEMA_PATH}: ${errors.join("; ")}`);
    writeJson(out, receipt);
    writeJson(latest, receipt);
    console.log(JSON.stringify(receipt, null, 2));
    console.error(`==> wrote ${out} and ${latest}`);
    if (!receipt.ok) {
      console.error("FAIL: the Firestore restore drill did not pass:");
      for (const failure of receipt.failures) console.error(` - ${failure}`);
      return 1;
    }
    console.error("PASS: the Firestore restore drill verified the restored data");
    return 0;
  }

  throw new UsageError("usage: firestore-restore-drill-verify.mjs preflight|counts|receipt [--flag value ...]");
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  main(process.argv.slice(2)).then(
    (code) => {
      process.exitCode = code;
    },
    (error) => {
      const usage = error instanceof UsageError || String(error?.code).startsWith("ERR_PARSE_ARGS");
      console.error(`FAIL: ${error.message}`);
      process.exitCode = usage ? 64 : 2;
    },
  );
}
