/**
 * @fileoverview Provider-quota refresh sweep (crosscut-010).
 *
 * Extracted core of the `refreshAllProviderQuotas` scheduled job so the
 * selection/budget/concurrency/backfill logic is unit-testable with an
 * in-memory Firestore model.
 *
 * Design notes (corrected from the originally-filed sketch):
 *
 * - Legacy account docs that predate `lastRefreshAt` have the field MISSING,
 *   not explicit-null. Firestore's `== null` filter matches only explicit
 *   nulls and `orderBy` excludes missing-field docs entirely, so neither the
 *   stale-first ordered query nor a `where("lastRefreshAt", "==", null)`
 *   filter can ever see them — the originally proposed filter would have
 *   returned zero rows and permanently orphaned legacy docs. Instead, a
 *   cursor-resumable backfill stamps an ancient ISO timestamp onto
 *   missing-field docs (cheap writes, no provider HTTP). That marker is
 *   Firestore-rules/schema-valid, sorts before every real refresh timestamp,
 *   and makes the docs refresh with stale-first priority by the very next
 *   ordered query, covered by the existing composite index (status asc,
 *   storageScope asc, lastRefreshAt asc) — no new index needed. Older
 *   admin-written null markers still sort first and drain through the same
 *   ordered pass; the sweep no longer writes new nulls.
 *
 * - The backfill terminates: each (status, storageScope) stream pages in
 *   implicit `__name__` order with a persisted cursor, and once every stream
 *   returns a short page the marker doc is stamped `complete` and cached
 *   in-process. After that the sweep costs one marker read per cold start and
 *   zero extra collection-group queries — replacing the old "compatibility
 *   pass" that re-read up to a full batch of already-refreshed docs every 15
 *   minutes forever (and that starved permanently once the ordered pass
 *   filled the batch budget).
 *
 * - Refreshes run through a bounded concurrency pool instead of strictly
 *   serial awaits: each refresh is an outbound provider HTTP call (1-3 s), so
 *   a serial batch of 20 approached the default 60 s function timeout. Provider
 *   adapters call `providerFetch`, which uses a provider-scoped breaker; one
 *   dead provider can open only its own breaker while the same sweep continues
 *   refreshing unrelated healthy providers.
 *
 * All Firestore access goes through narrow structural types so the real
 * admin-SDK objects satisfy them directly (zero casts, production and tests).
 */

import { isDemoProviderAccountID, providerAccountIDFromPath } from "@openburnbar/functions-shared/providerAccountIsolation.js";

/** Subset of `DocumentReference` the sweep touches on account docs. */
type SweepAccountDocRef = {
  readonly path: string;
  update(data: Record<string, unknown>): Promise<unknown>;
};

/** Subset of `QueryDocumentSnapshot` the sweep reads. */
export type SweepAccountDoc = {
  readonly ref: SweepAccountDocRef;
  get(field: string): unknown;
};

type SweepQuerySnapshot<Doc> = { readonly docs: readonly Doc[] };

/** Subset of `Query` used for both the ordered pass and the backfill scan. */
export type SweepQuery<Doc> = {
  where(field: string, op: "==" | "in", value: unknown): SweepQuery<Doc>;
  orderBy(field: string, direction?: "asc" | "desc"): SweepQuery<Doc>;
  limit(count: number): SweepQuery<Doc>;
  startAfter(cursor: unknown): SweepQuery<Doc>;
  get(): Promise<SweepQuerySnapshot<Doc>>;
};

/** Subset of `DocumentSnapshot` used for marker and cursor docs. */
export type SweepMarkerSnapshot = {
  readonly exists: boolean;
  /** Cursor resume position — real snapshots expose their location here. */
  readonly ref: { readonly path: string };
  data(): Record<string, unknown> | undefined;
};

/** Subset of `DocumentReference` used for marker and cursor docs. */
export type SweepDocRef = {
  get(): Promise<SweepMarkerSnapshot>;
  set(data: Record<string, unknown>): Promise<unknown>;
};

/** Subset of `Firestore` the sweep needs. */
export type SweepDb<Doc extends SweepAccountDoc> = {
  collectionGroup(collectionId: string): SweepQuery<Doc>;
  doc(path: string): SweepDocRef;
};

type QuotaBackfillResult = {
  /** True when the backfill is already complete and no scan was issued. */
  skipped: boolean;
  /** True once every (status, storageScope) stream has been drained. */
  complete: boolean;
  /** Docs examined by this run's scan pages. */
  examined: number;
  /** Missing-field docs stamped with the legacy refresh marker by this run. */
  backfilled: number;
};

type QuotaRefreshSweepOptions<Doc extends SweepAccountDoc> = {
  /** Maximum account + legacy-connection refreshes per run. */
  batchSize: number;
  /** Parallel refresh width (default 5). */
  concurrency?: number;
  /** Clock for due-date checks (default now). */
  now?: Date;
  /** Backfill scan page size per stream per run (default 200). */
  backfillScanPageSize?: number;
  /** Maximum ordered account docs inspected while selecting one refresh batch. */
  maxSelectionScanCount?: number;
  /** Refresh one provider account doc. Expected to handle its own errors. */
  refreshAccountDoc(doc: Doc): Promise<void>;
  /** `${uid}/${providerID}` key used to dedupe the legacy connection pass. */
  legacyKeyForAccountDoc(doc: Doc): string | undefined;
  /** Refresh one legacy provider_connections doc. */
  refreshLegacyConnectionDoc(doc: Doc): Promise<void>;
  /** Dedupe key for a legacy connection doc; undefined skips the doc. */
  legacyKeyForConnectionDoc(doc: Doc): string | undefined;
};

type QuotaRefreshSweepResult = {
  backfill: QuotaBackfillResult;
  refreshedAccountPaths: string[];
  refreshedLegacyPaths: string[];
};

const REFRESHABLE_STATUSES = ["connected", "stale", "error"] as const;
const REFRESHABLE_SCOPES = ["cloud_refreshable", "server_private"] as const;
const DEFAULT_CONCURRENCY = 5;
const DEFAULT_BACKFILL_SCAN_PAGE_SIZE = 200;
const DEFAULT_SELECTION_SCAN_MULTIPLIER = 5;

/**
 * Schema-valid marker for legacy provider account docs that predate
 * `lastRefreshAt`. It sorts before any real refresh timestamp without
 * teaching Firestore rules or generated clients to accept nullable timestamps.
 */
export const LEGACY_LAST_REFRESH_AT_BACKFILL_SENTINEL = "1970-01-01T00:00:00.000Z";

/**
 * Server-only migration marker (clients are denied by default — the path is
 * matched by no firestore.rules allow). While incomplete it stores one resume
 * cursor per (status, storageScope) stream; on completion the cursors are
 * dropped so no account-doc paths are retained.
 */
export const LAST_REFRESH_AT_BACKFILL_MARKER_PATH = "ops_migrations/provider_accounts_last_refresh_at_backfill";

/**
 * Process-global memo of backfill completion: warm instances skip even the
 * marker read. Safe because completion is monotonic — new account docs are
 * always created with `lastRefreshAt` populated.
 */
let backfillCompleteCache = false;

export function resetQuotaRefreshSweepCachesForTests(): void {
  backfillCompleteCache = false;
}

/**
 * Runs `fn` over `items` with at most `limit` invocations in flight. Always
 * settles every item (a rejection does not starve the rest of the batch),
 * then rethrows the first failure so callers still observe it.
 */
export async function mapWithConcurrency<T>(
  items: readonly T[],
  limit: number,
  fn: (item: T) => Promise<void>,
): Promise<void> {
  if (items.length === 0) return;
  const width = Math.max(1, Math.min(limit, items.length));
  let nextIndex = 0;
  const failures: unknown[] = [];

  const workers = Array.from({ length: width }, async () => {
    for (;;) {
      const index = nextIndex;
      nextIndex += 1;
      if (index >= items.length) return;
      try {
        await fn(items[index]);
      } catch (err) {
        failures.push(err);
      }
    }
  });

  await Promise.all(workers);
  if (failures.length > 0) {
    throw failures[0];
  }
}

type BackfillStreamState = {
  cursorPath?: string;
  done?: boolean;
};

function parseBackfillStreamState(value: unknown): BackfillStreamState {
  if (typeof value !== "object" || value === null) return {};
  const record: Record<string, unknown> = { ...value };
  return {
    cursorPath: typeof record.cursorPath === "string" ? record.cursorPath : undefined,
    done: record.done === true ? true : undefined,
  };
}

function backfillStreamKeys(): string[] {
  const keys: string[] = [];
  for (const status of REFRESHABLE_STATUSES) {
    for (const scope of REFRESHABLE_SCOPES) {
      keys.push(`${status}|${scope}`);
    }
  }
  return keys;
}

function isDemoSweepAccountDoc(doc: SweepAccountDoc): boolean {
  if (doc.get("demo") === true) return true;
  const id = doc.get("id");
  if (typeof id === "string" && isDemoProviderAccountID(id)) return true;
  const accountID = providerAccountIDFromPath(doc.ref.path);
  return accountID !== undefined && isDemoProviderAccountID(accountID);
}

/**
 * How early the sweep may take an account ahead of its `quotaNextRefreshAt`.
 * A snapshot's `fetchedAt` trails its sweep tick by up to the job's 120 s
 * timeout, so without this slack an account due "at" the next tick lands a
 * few seconds after it and waits a whole extra 15-minute interval (a 30-minute
 * TTL became 45 minutes of staleness).
 */
export const QUOTA_SWEEP_DUE_GRACE_MS = 2 * 60_000;

export function isQuotaSweepAccountDue(doc: SweepAccountDoc, now: Date = new Date()): boolean {
  const nextRefreshAt = doc.get("quotaNextRefreshAt");
  if (typeof nextRefreshAt !== "string") return true;
  const nextRefreshAtMs = Date.parse(nextRefreshAt);
  if (!Number.isFinite(nextRefreshAtMs)) return true;
  return nextRefreshAtMs <= now.getTime() + QUOTA_SWEEP_DUE_GRACE_MS;
}

type SelectionStream<Doc> = {
  readonly status: (typeof REFRESHABLE_STATUSES)[number];
  readonly buffer: Doc[];
  cursor: Doc | undefined;
  exhausted: boolean;
};

/**
 * Firestore's cross-type sort rank for a `lastRefreshAt` value: null before
 * numbers before timestamps before strings. Each per-status stream arrives in
 * this order, so the merge must compare the same way.
 */
function lastRefreshAtSortKey(value: unknown): [rank: number, key: number | string] {
  if (value === null) return [0, 0];
  if (typeof value === "number") return [1, value];
  if (typeof value === "object" && "toMillis" in value && typeof value.toMillis === "function") {
    const millis: unknown = value.toMillis();
    return [2, typeof millis === "number" ? millis : 0];
  }
  if (typeof value === "string") return [3, value];
  return [4, 0];
}

/** Oldest refresh first, then document path — the order Firestore pages each stream in. */
function compareSelectionOrder(a: SweepAccountDoc, b: SweepAccountDoc): number {
  const [rankA, keyA] = lastRefreshAtSortKey(a.get("lastRefreshAt"));
  const [rankB, keyB] = lastRefreshAtSortKey(b.get("lastRefreshAt"));
  if (rankA !== rankB) return rankA - rankB;
  if (keyA < keyB) return -1;
  if (keyA > keyB) return 1;
  return a.ref.path < b.ref.path ? -1 : a.ref.path > b.ref.path ? 1 : 0;
}

/**
 * One bounded slice of the one-time `lastRefreshAt` backfill. Missing-field
 * docs are stamped with a schema-valid ancient timestamp so the ordered
 * refresh pass can see them; docs that already carry the field (including
 * legacy explicit null markers) are untouched.
 */
async function runLastRefreshAtBackfill<Doc extends SweepAccountDoc>(
  db: SweepDb<Doc>,
  pageSize: number,
): Promise<QuotaBackfillResult> {
  if (backfillCompleteCache) {
    return { skipped: true, complete: true, examined: 0, backfilled: 0 };
  }

  const markerRef = db.doc(LAST_REFRESH_AT_BACKFILL_MARKER_PATH);
  const markerSnap = await markerRef.get();
  const marker = markerSnap.exists ? (markerSnap.data() ?? {}) : {};
  if (marker.complete === true) {
    backfillCompleteCache = true;
    return { skipped: true, complete: true, examined: 0, backfilled: 0 };
  }

  const priorStreamsValue = marker.streams;
  const priorStreams: Record<string, unknown> =
    typeof priorStreamsValue === "object" && priorStreamsValue !== null ? { ...priorStreamsValue } : {};

  const effectivePageSize = Math.max(1, pageSize);
  const nextStreams: Record<string, BackfillStreamState> = {};
  let examined = 0;
  let backfilled = 0;
  let allDone = true;

  for (const streamKey of backfillStreamKeys()) {
    const [status, scope] = streamKey.split("|");
    const prior = parseBackfillStreamState(priorStreams[streamKey]);
    if (prior.done === true) {
      nextStreams[streamKey] = { done: true };
      continue;
    }

    let query = db
      .collectionGroup("provider_accounts")
      .where("status", "==", status)
      .where("storageScope", "==", scope)
      .limit(effectivePageSize);

    if (prior.cursorPath !== undefined) {
      const cursorSnap = await db.doc(prior.cursorPath).get();
      if (cursorSnap.exists) {
        query = query.startAfter(cursorSnap);
      }
      // A vanished cursor doc restarts the stream from the beginning; the
      // null stamp is idempotent so a re-scan only costs reads.
    }

    const snapshot = await query.get();
    examined += snapshot.docs.length;

    for (const doc of snapshot.docs) {
      if (isDemoSweepAccountDoc(doc)) continue;
      if (doc.get("lastRefreshAt") !== undefined) continue;
      try {
        await doc.ref.update({ lastRefreshAt: LEGACY_LAST_REFRESH_AT_BACKFILL_SENTINEL });
        backfilled += 1;
      } catch {
        // Doc deleted between scan and stamp — nothing left to migrate.
      }
    }

    if (snapshot.docs.length >= effectivePageSize) {
      allDone = false;
      const lastDoc = snapshot.docs[snapshot.docs.length - 1];
      nextStreams[streamKey] = { cursorPath: lastDoc.ref.path };
    } else {
      nextStreams[streamKey] = { done: true };
    }
  }

  const now = new Date().toISOString();
  if (allDone) {
    backfillCompleteCache = true;
    // Full set (no merge): drops the per-stream cursors so no account-doc
    // paths are retained once the migration is over.
    await markerRef.set({ complete: true, completedAt: now });
  } else {
    const streams: Record<string, unknown> = {};
    for (const [key, state] of Object.entries(nextStreams)) {
      streams[key] = state.done === true ? { done: true } : { cursorPath: state.cursorPath };
    }
    await markerRef.set({ complete: false, streams, updatedAt: now });
  }

  return { skipped: false, complete: allDone, examined, backfilled };
}

/**
 * Full provider-quota sweep:
 *   1. Backfill slice (until the one-time migration completes).
 *   2. Stale-first ordered refresh of provider_accounts, oldest snapshot
 *      first across ALL refreshable statuses (not status by status), bounded
 *      by `batchSize`, refreshed through the concurrency pool. Selection (and
 *      the budget math) happens serially BEFORE any refresh runs, so pooling
 *      cannot skew the limit accounting.
 *   3. Legacy provider_connections fallback for installs that predate
 *      account docs, deduped against the accounts already refreshed.
 */
export async function runQuotaRefreshSweep<Doc extends SweepAccountDoc>(
  db: SweepDb<Doc>,
  options: QuotaRefreshSweepOptions<Doc>,
): Promise<QuotaRefreshSweepResult> {
  const concurrency = options.concurrency ?? DEFAULT_CONCURRENCY;
  const now = options.now ?? new Date();
  const backfill = await runLastRefreshAtBackfill(db, options.backfillScanPageSize ?? DEFAULT_BACKFILL_SCAN_PAGE_SIZE);

  // Selection pass: materialize the batch before any refresh starts.
  const selectedAccounts: Doc[] = [];
  const selectedAccountPaths = new Set<string>();
  const legacyKeys = new Set<string>();
  const maxSelectionScanCount = Math.max(
    options.batchSize,
    options.maxSelectionScanCount ?? options.batchSize * DEFAULT_SELECTION_SCAN_MULTIPLIER,
  );
  let scannedForSelection = 0;

  // One stale-first stream per status, merged oldest-snapshot-first so a
  // full batch of `connected` accounts cannot starve older `stale`/`error`
  // ones. Each stream is served by the existing (status, storageScope,
  // lastRefreshAt) index; a stream is only paged when its buffer runs dry.
  const streams: SelectionStream<Doc>[] = REFRESHABLE_STATUSES.map((status) => ({
    status,
    buffer: [],
    cursor: undefined,
    exhausted: false,
  }));

  const fillStream = async (stream: SelectionStream<Doc>): Promise<boolean> => {
    const limit = Math.min(options.batchSize - selectedAccounts.length, maxSelectionScanCount - scannedForSelection);
    if (limit <= 0) return false;
    let query = db
      .collectionGroup("provider_accounts")
      .where("status", "==", stream.status)
      .where("storageScope", "in", [...REFRESHABLE_SCOPES])
      .orderBy("lastRefreshAt", "asc")
      .limit(limit);
    if (stream.cursor !== undefined) {
      query = query.startAfter(stream.cursor);
    }
    const snapshot = await query.get();
    scannedForSelection += snapshot.docs.length;
    stream.buffer.push(...snapshot.docs);
    stream.cursor = snapshot.docs.at(-1) ?? stream.cursor;
    stream.exhausted = snapshot.docs.length < limit;
    return true;
  };

  selection: while (selectedAccounts.length < options.batchSize) {
    let oldest: { stream: SelectionStream<Doc>; head: Doc } | undefined;
    for (const stream of streams) {
      if (stream.buffer.length === 0 && !stream.exhausted && !(await fillStream(stream))) {
        // Scan budget spent with this stream's head unknown: picking from the
        // others could skip an older account, so stop the batch here.
        break selection;
      }
      const head = stream.buffer[0];
      if (head !== undefined && (oldest === undefined || compareSelectionOrder(head, oldest.head) < 0)) {
        oldest = { stream, head };
      }
    }
    if (oldest === undefined) break;

    oldest.stream.buffer.shift();
    const doc = oldest.head;
    if (isDemoSweepAccountDoc(doc) || selectedAccountPaths.has(doc.ref.path)) continue;
    if (!isQuotaSweepAccountDue(doc, now)) continue;
    selectedAccountPaths.add(doc.ref.path);
    const legacyKey = options.legacyKeyForAccountDoc(doc);
    if (legacyKey !== undefined) legacyKeys.add(legacyKey);
    selectedAccounts.push(doc);
  }

  await mapWithConcurrency(selectedAccounts, concurrency, (doc) => options.refreshAccountDoc(doc));

  const refreshedLegacyPaths: string[] = [];
  const legacyRemaining = Math.max(0, options.batchSize - selectedAccounts.length);
  if (legacyRemaining > 0) {
    const connectionSnapshot = await db
      .collectionGroup("provider_connections")
      .where("status", "==", "connected")
      .orderBy("lastRefreshAt", "asc")
      .limit(legacyRemaining)
      .get();

    const selectedConnections: Doc[] = [];
    for (const doc of connectionSnapshot.docs) {
      const legacyKey = options.legacyKeyForConnectionDoc(doc);
      if (legacyKey === undefined || legacyKeys.has(legacyKey)) continue;
      selectedConnections.push(doc);
      refreshedLegacyPaths.push(doc.ref.path);
    }

    await mapWithConcurrency(selectedConnections, concurrency, (doc) => options.refreshLegacyConnectionDoc(doc));
  }

  return {
    backfill,
    refreshedAccountPaths: [...selectedAccountPaths],
    refreshedLegacyPaths,
  };
}
