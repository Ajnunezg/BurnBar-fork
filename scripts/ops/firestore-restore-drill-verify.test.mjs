#!/usr/bin/env node
/**
 * Self-test for scripts/ops/firestore-restore-drill-verify.mjs (offline; fetch is stubbed).
 * Run: node --test scripts/ops/firestore-restore-drill-verify.test.mjs
 * The end-to-end drill against a fake gcloud and a fake Firestore REST server
 * lives in scripts/ops/run-firestore-restore-drill.test.sh.
 */
import assert from "node:assert/strict";
import { test } from "node:test";
import {
  DEFAULT_COLLECTION_GROUPS,
  collectDrillCounts,
  countAggregationRequest,
  createFirestoreRestoreDrillReceipt,
  evaluateCollectionCount,
  evaluateRestoreDrill,
  minuteBounds,
  parseCollectionGroups,
  parseCountResponse,
  resolveApiBase,
  validateFirestoreRestoreDrillReceipt,
} from "./firestore-restore-drill-verify.mjs";
import { validateAgainstSchema } from "../lib/json-schema-subset.mjs";

const SNAPSHOT = "2026-09-28T11:55:00Z";
const LIVE_API = resolveApiBase(undefined);
const TEST_API = resolveApiBase("http://127.0.0.1:9/v1");

function countStream(count) {
  return [
    { readTime: "2026-09-28T12:00:00Z" },
    { result: { aggregateFields: { count: { integerValue: String(count) } } }, readTime: "2026-09-28T12:00:00Z" },
  ];
}

function stubFetch(handler) {
  const calls = [];
  const fetchImpl = async (url, init) => {
    const call = { url, body: JSON.parse(init.body), authorization: init.headers.authorization };
    calls.push(call);
    const { status = 200, json } = handler(call);
    return new Response(typeof json === "string" ? json : JSON.stringify(json), { status });
  };
  return { fetchImpl, calls };
}

function countsOptions(overrides = {}) {
  return {
    mode: "clone",
    project: "drill-project",
    sourceDatabaseId: "(default)",
    restoreDatabaseId: "dr-drill-test",
    snapshotTime: SNAPSHOT,
    collectionGroups: ["entitlements"],
    api: TEST_API,
    token: "test-token",
    ...overrides,
  };
}

function drillFacts(overrides = {}) {
  return {
    mode: "clone",
    sourceDatabaseId: "(default)",
    restoreDatabaseId: "dr-drill-20260928120000",
    snapshotTime: SNAPSHOT,
    postureOk: true,
    restoreStarted: true,
    operationDone: true,
    elapsedSeconds: 312,
    captureOk: true,
    counts: [
      { collectionGroup: "entitlements", sourceCount: 4, restoredCount: 4, errors: [] },
      { collectionGroup: "cloud_vault_key_wrappers", sourceCount: 2, restoredCount: 2, errors: [] },
      { collectionGroup: "usage", sourceCount: 0, restoredCount: 0, errors: [] },
    ],
    cleanupRequested: true,
    databaseDeleted: true,
    ...overrides,
  };
}

function evaluate(overrides) {
  const facts = drillFacts(overrides);
  return evaluateRestoreDrill({ ...facts, counts: facts.counts?.map(evaluateCollectionCount) ?? null });
}

test("collection groups default to the launch-blocking data and reject malformed overrides", () => {
  assert.deepEqual(parseCollectionGroups(undefined), [...DEFAULT_COLLECTION_GROUPS]);
  assert.deepEqual(parseCollectionGroups(""), ["entitlements", "cloud_vault_key_wrappers", "usage"]);
  assert.deepEqual(parseCollectionGroups(" usage , entitlements "), ["usage", "entitlements"]);
  assert.throws(() => parseCollectionGroups("usage,,entitlements"), /invalid collection group: ""/u);
  assert.throws(() => parseCollectionGroups("users/usage"), /invalid collection group/u);
  assert.throws(() => parseCollectionGroups("usage,usage"), /twice/u);
});

test("the access token only goes to Firestore or a loopback test server", () => {
  assert.deepEqual(LIVE_API, { base: "https://firestore.googleapis.com/v1", live: true });
  assert.deepEqual(resolveApiBase("http://127.0.0.1:4321/v1/"), { base: "http://127.0.0.1:4321/v1", live: false });
  assert.equal(resolveApiBase("http://localhost:4321/v1").live, false);
  assert.throws(() => resolveApiBase("https://collector.example.com/v1"), /never sent anywhere else/u);
  assert.throws(() => resolveApiBase("http://firestore.googleapis.com/v1"), /never sent anywhere else/u);
  assert.throws(() => resolveApiBase("not a url"), /not a URL/u);
});

test("backup snapshot times are read at the whole minutes around them", () => {
  assert.deepEqual(minuteBounds("2026-09-28T03:17:42.123456Z"), {
    floor: "2026-09-28T03:17:00Z",
    ceil: "2026-09-28T03:18:00Z",
  });
  assert.deepEqual(minuteBounds("2026-09-28T03:17:00.000000Z"), {
    floor: "2026-09-28T03:17:00Z",
    ceil: "2026-09-28T03:17:00Z",
  });
  // A nanosecond past the minute is not a whole minute, even though Date truncates it.
  assert.equal(minuteBounds("2026-09-28T03:17:00.000000001Z").ceil, "2026-09-28T03:18:00Z");
  assert.deepEqual(minuteBounds("2026-06-01T10:30:00.00-07:00"), {
    floor: "2026-06-01T17:30:00Z",
    ceil: "2026-06-01T17:30:00Z",
  });
  assert.equal(minuteBounds("yesterday"), null);
  assert.equal(minuteBounds(null), null);
});

test("the count request is a collection-group COUNT with an optional read time", () => {
  assert.deepEqual(countAggregationRequest("usage", SNAPSHOT), {
    structuredAggregationQuery: {
      structuredQuery: { from: [{ collectionId: "usage", allDescendants: true }] },
      aggregations: [{ alias: "count", count: {} }],
    },
    readTime: SNAPSHOT,
  });
  assert.equal("readTime" in countAggregationRequest("usage"), false);
});

test("count responses parse from the REST stream and refuse anything but an integer", () => {
  assert.equal(parseCountResponse(countStream(42)), 42);
  assert.equal(parseCountResponse({ result: { aggregateFields: { count: { integerValue: "0" } } } }), 0);
  assert.equal(parseCountResponse([{ result: { aggregateFields: { count: { integerValue: 7 } } } }]), 7);
  assert.throws(() => parseCountResponse([{ readTime: SNAPSHOT }]), /no integer count/u);
  assert.throws(() => parseCountResponse(countStream("-1")), /no integer count/u);
  assert.throws(() => parseCountResponse(countStream("99999999999999999999")), /no integer count/u);
  assert.throws(() => parseCountResponse(null), /no integer count/u);
});

test("clone counts read the source at the snapshot time and the restore as it stands", async () => {
  const { fetchImpl, calls } = stubFetch(() => ({ json: countStream(5) }));
  const entries = await collectDrillCounts(countsOptions({ collectionGroups: ["entitlements", "usage"], fetchImpl }));
  assert.deepEqual(entries, [
    { collectionGroup: "entitlements", sourceCount: 5, restoredCount: 5, errors: [] },
    { collectionGroup: "usage", sourceCount: 5, restoredCount: 5, errors: [] },
  ]);
  assert.equal(calls.length, 4);
  const [source, restored] = calls;
  assert.equal(
    source.url,
    "http://127.0.0.1:9/v1/projects/drill-project/databases/(default)/documents:runAggregationQuery",
  );
  assert.equal(source.body.readTime, SNAPSHOT);
  assert.equal(
    restored.url,
    "http://127.0.0.1:9/v1/projects/drill-project/databases/dr-drill-test/documents:runAggregationQuery",
  );
  assert.equal("readTime" in restored.body, false);
  assert.ok(calls.every((call) => call.authorization === "Bearer test-token"));
});

test("backup counts bracket a sub-minute snapshot and read a whole-minute one once", async () => {
  const bySnapshot = { "2026-09-28T03:17:00Z": 10, "2026-09-28T03:18:00Z": 12 };
  const { fetchImpl, calls } = stubFetch((call) => ({
    json: countStream(call.body.readTime ? bySnapshot[call.body.readTime] : 11),
  }));
  const [entry] = await collectDrillCounts(
    countsOptions({ mode: "backup", snapshotTime: "2026-09-28T03:17:42.5Z", fetchImpl }),
  );
  assert.deepEqual(entry, { collectionGroup: "entitlements", sourceCount: { floor: 10, ceil: 12 }, restoredCount: 11, errors: [] });
  assert.deepEqual(calls.map((call) => call.body.readTime ?? "restored"), [
    "2026-09-28T03:17:00Z",
    "2026-09-28T03:18:00Z",
    "restored",
  ]);

  const whole = stubFetch(() => ({ json: countStream(3) }));
  const [wholeEntry] = await collectDrillCounts(
    countsOptions({ mode: "backup", snapshotTime: "2026-09-28T03:17:00Z", fetchImpl: whole.fetchImpl }),
  );
  assert.deepEqual(wholeEntry.sourceCount, { floor: 3, ceil: 3 });
  assert.equal(whole.calls.length, 2);
});

test("API failures become redaction-safe entry errors with an operator hint", async () => {
  const logged = [];
  const { fetchImpl } = stubFetch((call) =>
    call.url.includes("dr-drill-")
      ? {
          status: 400,
          json: {
            error: {
              code: 400,
              status: "FAILED_PRECONDITION",
              message: "The query requires an index: https://console.firebase.google.com/project/secret-project/indexes",
            },
          },
        }
      : { status: 403, json: { error: { code: 403, status: "PERMISSION_DENIED", message: "Missing permissions on projects/secret-project" } } },
  );
  const [entry] = await collectDrillCounts(countsOptions({ fetchImpl, log: (line) => logged.push(line) }));
  assert.equal(entry.sourceCount, null);
  assert.equal(entry.restoredCount, null);
  assert.equal(entry.errors.length, 2);
  assert.match(entry.errors[0], /^entitlements: source at 2026-09-28T11:55:00Z count failed: PERMISSION_DENIED \(.*roles\/datastore\.viewer\)$/u);
  assert.match(entry.errors[1], /^entitlements: restored count failed: FAILED_PRECONDITION \(a collection-group index is missing/u);
  assert.doesNotMatch(entry.errors.join("\n"), /secret-project|https?:/u);
  // Firestore's own message reaches the operator log, not the receipt.
  assert.match(logged.join("\n"), /secret-project/u);
});

test("non-JSON errors, in-stream errors and network failures are named without upstream text", async () => {
  const cases = [
    [() => ({ status: 502, json: "<html>bad gateway</html>" }), /count failed: HTTP 502$/u],
    [() => ({ json: [{ error: { code: 503, status: "UNAVAILABLE", message: "try later" } }] }), /count failed: UNAVAILABLE \(Firestore was unavailable; retry\)$/u],
    [() => ({ json: [{ readTime: SNAPSHOT }] }), /count failed: the response carried no integer count$/u],
  ];
  for (const [handler, expected] of cases) {
    const [entry] = await collectDrillCounts(countsOptions({ fetchImpl: stubFetch(handler).fetchImpl }));
    assert.match(entry.errors[0], expected);
  }
  const offline = async () => {
    throw new TypeError("fetch failed");
  };
  const [entry] = await collectDrillCounts(countsOptions({ fetchImpl: offline }));
  assert.match(entry.errors[0], /the request failed before Firestore answered/u);
});

test("a missing snapshot time is an entry error, not a guessed read time", async () => {
  const { fetchImpl, calls } = stubFetch(() => ({ json: countStream(1) }));
  const [entry] = await collectDrillCounts(countsOptions({ mode: "backup", snapshotTime: null, fetchImpl }));
  assert.equal(entry.sourceCount, null);
  assert.equal(entry.restoredCount, 1);
  assert.match(entry.errors[0], /source snapshot time is unknown/u);
  assert.equal(calls.length, 1);
});

test("counts match exactly for clones, inside the minute range for backups, and flag empty sources", () => {
  const check = (sourceCount, restoredCount) => {
    const { match, vacuous } = evaluateCollectionCount({ collectionGroup: "usage", sourceCount, restoredCount });
    return { match, vacuous };
  };
  assert.deepEqual(check(5, 5), { match: true, vacuous: false });
  assert.deepEqual(check(5, 4), { match: false, vacuous: false });
  assert.deepEqual(check(0, 0), { match: true, vacuous: true });
  assert.deepEqual(check({ floor: 10, ceil: 12 }, 10), { match: true, vacuous: false });
  assert.deepEqual(check({ floor: 10, ceil: 12 }, 12), { match: true, vacuous: false });
  assert.deepEqual(check({ floor: 12, ceil: 10 }, 11), { match: true, vacuous: false });
  assert.deepEqual(check({ floor: 10, ceil: 12 }, 13), { match: false, vacuous: false });
  assert.deepEqual(check({ floor: 0, ceil: 0 }, 0), { match: true, vacuous: true });
  assert.deepEqual(check(null, 3), { match: false, vacuous: false });
  assert.deepEqual(check(3, null), { match: false, vacuous: false });
});

test("the drill passes only with posture, a finished restore, matched data and cleanup", () => {
  assert.deepEqual(evaluate({}), { ok: true, failures: [] });
  const failuresFor = (overrides) => evaluate(overrides).failures;

  assert.match(failuresFor({ postureOk: false }).join("\n"), /posture check failed/u);
  assert.deepEqual(failuresFor({ restoreStarted: false, operationDone: false, databaseDeleted: false }), [
    "the restore did not start; the drill log has the gcloud error",
  ]);
  assert.match(failuresFor({ operationDone: false }).join("\n"), /did not finish cleanly/u);
  assert.match(failuresFor({ captureOk: false }).join("\n"), /could not describe the restored database/u);
  assert.match(failuresFor({ counts: null }).join("\n"), /count verification produced no results/u);
  assert.match(failuresFor({ counts: [] }).join("\n"), /count verification produced no results/u);
  assert.deepEqual(
    failuresFor({
      counts: [
        { collectionGroup: "entitlements", sourceCount: 4, restoredCount: 3, errors: [] },
        { collectionGroup: "usage", sourceCount: { floor: 10, ceil: 12 }, restoredCount: 9, errors: [] },
        { collectionGroup: "cloud_vault_key_wrappers", sourceCount: null, restoredCount: null, errors: ["x: restored count failed: HTTP 500"] },
      ],
    }),
    [
      "entitlements: restored count 3 does not match the source count 4",
      "usage: restored count 9 does not match the source count between 10 and 12",
      "x: restored count failed: HTTP 500",
    ],
  );
  assert.deepEqual(
    failuresFor({
      counts: [
        { collectionGroup: "entitlements", sourceCount: 0, restoredCount: 0, errors: [] },
        { collectionGroup: "usage", sourceCount: { floor: 0, ceil: 0 }, restoredCount: 0, errors: [] },
      ],
    }),
    ["every collection group was empty at the snapshot time; an all-empty restore proves nothing"],
  );
  const kept = failuresFor({ cleanupRequested: false, databaseDeleted: false });
  assert.equal(kept.length, 1);
  assert.match(kept[0], /^cleanup-disabled: /u);
  assert.match(failuresFor({ databaseDeleted: false }).join("\n"), /was not deleted/u);
});

test("receipts conform to the published schema whether the drill passed or failed", () => {
  const now = new Date("2026-09-28T12:10:00Z");
  const passed = createFirestoreRestoreDrillReceipt(drillFacts(), { live: true, now });
  assert.deepEqual(validateFirestoreRestoreDrillReceipt(passed), []);
  assert.equal(passed.ok, true);
  assert.equal(passed.liveDrill, true);
  assert.deepEqual(passed.restore, { databaseId: "dr-drill-20260928120000", operationDone: true, elapsedSeconds: 312 });
  assert.deepEqual(passed.counts[0], {
    collectionGroup: "entitlements",
    sourceCount: 4,
    restoredCount: 4,
    match: true,
    vacuous: false,
  });

  const fixture = createFirestoreRestoreDrillReceipt(drillFacts(), { live: false, now });
  assert.deepEqual(validateFirestoreRestoreDrillReceipt(fixture), []);
  assert.equal(fixture.liveDrill, false);

  const unfinished = createFirestoreRestoreDrillReceipt(
    drillFacts({ operationDone: false, elapsedSeconds: 99, counts: [] }),
    { live: true, now },
  );
  assert.deepEqual(validateFirestoreRestoreDrillReceipt(unfinished), []);
  assert.equal(unfinished.ok, false);
  assert.equal(unfinished.restore.elapsedSeconds, null);

  const backup = createFirestoreRestoreDrillReceipt(
    drillFacts({
      mode: "backup",
      snapshotTime: "2026-09-28T03:17:42.123456Z",
      counts: [{ collectionGroup: "usage", sourceCount: { floor: 10, ceil: 12 }, restoredCount: 11, errors: [] }],
    }),
    { live: true, now },
  );
  assert.deepEqual(validateFirestoreRestoreDrillReceipt(backup), []);
  assert.equal(backup.ok, true);

  const failedRead = createFirestoreRestoreDrillReceipt(
    drillFacts({ counts: [{ collectionGroup: "usage", sourceCount: null, restoredCount: 2, errors: ["usage: source at x count failed: HTTP 500"] }] }),
    { live: true, now },
  );
  assert.deepEqual(validateFirestoreRestoreDrillReceipt(failedRead), []);
  assert.equal("errors" in failedRead.counts[0], false);
});

test("the schema rejects receipts that claim more than they prove", () => {
  const receipt = createFirestoreRestoreDrillReceipt(drillFacts(), { live: true, now: new Date("2026-09-28T12:10:00Z") });
  const errorsFor = (mutate) => {
    const copy = structuredClone(receipt);
    mutate(copy);
    return validateFirestoreRestoreDrillReceipt(copy).join("\n");
  };
  assert.match(errorsFor((copy) => { copy.project = "burnbar"; }), /unexpected property project/u);
  assert.match(errorsFor((copy) => { copy.source.databaseId = "projects/burnbar/databases/(default)"; }), /\$\.source\.databaseId does not match/u);
  assert.match(errorsFor((copy) => { copy.restore.databaseId = "(default)"; }), /\$\.restore\.databaseId does not match/u);
  assert.match(errorsFor((copy) => { copy.counts[0].match = false; }), /\$\.counts\[0\]\.match must be true/u);
  assert.match(errorsFor((copy) => { copy.counts.forEach((entry) => { entry.vacuous = true; }); }), /no item matching its contains rule/u);
  assert.match(errorsFor((copy) => { copy.cleanup.databaseDeleted = false; }), /\$\.cleanup\.databaseDeleted must be true/u);
  assert.match(errorsFor((copy) => { copy.failures = ["something broke"]; }), /\$\.failures has more than 0 items/u);
  assert.match(errorsFor((copy) => { copy.ok = false; }), /\$\.failures has fewer than 1 items/u);
  assert.match(errorsFor((copy) => { copy.counts[0].sourceCount = { floor: 4, ceil: 4 }; }), /\$\.counts\[0\]\.sourceCount must be integer or null/u);
  assert.match(errorsFor((copy) => { copy.generatedAt = "last Tuesday"; }), /not an RFC 3339 date-time/u);
  assert.match(errorsFor((copy) => { copy.mode = "export"; }), /\$\.mode must be one of clone, backup/u);
});

test("the validator refuses schema keywords it does not implement", () => {
  assert.throws(() => validateAgainstSchema({}, { patternProperties: {} }), /unsupported JSON Schema keyword "patternProperties"/u);
  assert.throws(() => validateAgainstSchema({}, { additionalProperties: { type: "string" } }), /additionalProperties/u);
  assert.throws(() => validateAgainstSchema("x", { format: "uri" }), /date-time/u);
  assert.deepEqual(validateAgainstSchema(3, { oneOf: [{ type: "integer" }, { type: "null" }] }), []);
  assert.match(validateAgainstSchema(3, { oneOf: [{ type: "integer" }, { type: "number" }] }).join(), /matches 2 oneOf branches/u);
});
