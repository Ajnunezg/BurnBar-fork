/**
 * @fileoverview Durable, version-complete erasure of hosted provider credentials.
 *
 * `provider_account_secret_refs/{uid}_{accountID}` (server-only) is both the
 * pointer to an account's live credential version and — while any version of
 * its Secret Manager secret still has to be destroyed — the durable retry
 * manifest for that work:
 *
 *   erasureScope          "all_versions"        deletion/revocation: destroy every
 *                                               version, then delete the reference
 *                         "superseded_versions" replacement: destroy every version
 *                                               older than the live one
 *   erasureReason         low-cardinality cause, for audit and ops triage
 *   erasureRequestedAt    first request (ISO)
 *   erasureAttemptCount   failed attempts so far
 *   erasureLastAttemptAt  latest failed attempt (ISO)
 *   erasureLastErrorCode  sanitized code of the latest failure
 *   erasureRetryAfter     ISO queue key: `reconcileAccountErasures` retries every
 *                         reference whose retryAfter has passed, oldest first
 *
 * The intent is committed BEFORE any Secret Manager call, so a crash at any
 * point leaves a queue entry. The reference is deleted (or its erasure fields
 * cleared) only after Secret Manager confirmed the destroy AND only if nothing
 * re-pointed the reference meanwhile. A failure never reports success: the
 * reference stays, the failure is recorded, and callers surface `unavailable`.
 */

import { createHash } from "node:crypto";
import { FieldValue, type DocumentReference, type Transaction } from "firebase-admin/firestore";
import { HttpsError } from "firebase-functions/v2/https";

import { db } from "./adminRuntime.js";
import { logError } from "./logging.js";
import { providerAccountSecretRefPath } from "./quota.js";
import {
  destroyCredentialSecret,
  destroySupersededCredentialVersions,
  MalformedSecretReferenceError,
  parseSecretVersionName,
} from "./secrets.js";
import type { ProviderAccountSecretRefDoc } from "./types.js";

type ProviderSecretErasureScope = "all_versions" | "superseded_versions";

type ProviderSecretErasureReason =
  | "provider_account_delete"
  | "hosted_quota_credential_delete"
  | "legacy_credential_delete"
  | "panic_revoke"
  | "credential_replaced";

interface ProviderSecretErasureOutcome {
  /** True when no version remains to destroy (or no credential was stored). */
  complete: boolean;
  /** Sanitized failure code when `complete` is false. */
  errorCode?: string;
}

/**
 * How long an in-flight attempt owns a pending reference before the
 * reconciler may retry it. Keeps the scheduled retry from racing a live
 * callable attempt while still covering a crash mid-attempt.
 */
export const PROVIDER_SECRET_ERASURE_ATTEMPT_LEASE_MS = 10 * 60 * 1000;
const RETRY_BASE_MS = 15 * 60 * 1000;
const RETRY_MAX_MS = 6 * 60 * 60 * 1000;

const ERASURE_FIELDS = [
  "erasureScope",
  "erasureReason",
  "erasureRequestedAt",
  "erasureAttemptCount",
  "erasureLastAttemptAt",
  "erasureLastErrorCode",
  "erasureRetryAfter",
] as const;

/** Exponential backoff for the Nth consecutive failure (15m, 30m, 1h … capped at 6h). */
export function providerSecretErasureRetryDelayMs(attemptCount: number): number {
  const exponent = Math.max(0, Math.min(attemptCount - 1, 16));
  return Math.min(RETRY_BASE_MS * 2 ** exponent, RETRY_MAX_MS);
}

function stringField(value: unknown): string | undefined {
  return typeof value === "string" && value.trim() ? value : undefined;
}

function attemptCountOf(value: unknown): number {
  return typeof value === "number" && Number.isSafeInteger(value) && value >= 0 ? value : 0;
}

function correlationHash(value: string): string {
  return createHash("sha256").update(value, "utf8").digest("hex").slice(0, 12);
}

/** Low-cardinality, identifier-free failure code safe for Firestore and logs. */
export function providerSecretErasureErrorCode(error: unknown): string {
  if (error && typeof error === "object") {
    const code = Reflect.get(error, "code");
    if ((typeof code === "string" || typeof code === "number") && /^[A-Za-z0-9_./-]{1,64}$/u.test(String(code))) {
      return String(code);
    }
  }
  if (error instanceof Error && /^[A-Za-z][A-Za-z0-9_]{0,63}$/u.test(error.name)) return error.name;
  return "secret_manager_error";
}

/**
 * The durable retry manifest on a `provider_account_secret_refs` doc, written
 * before any Secret Manager destroy. `erasureRetryAfter` is the ISO queue key
 * `reconcileAccountErasures` reads.
 */
interface ProviderSecretErasureManifest {
  erasureScope: ProviderSecretErasureScope;
  erasureReason: ProviderSecretErasureReason;
  erasureRequestedAt: string;
  erasureAttemptCount?: number;
  erasureLastAttemptAt?: string;
  erasureLastErrorCode?: string;
  erasureRetryAfter: string;
}

function pendingErasureFields(
  scope: ProviderSecretErasureScope,
  reason: ProviderSecretErasureReason,
  existingRequestedAt: unknown,
  now: Date,
): ProviderSecretErasureManifest & { updatedAt: string } {
  const nowISO = now.toISOString();
  return {
    erasureScope: scope,
    erasureReason: reason,
    // Keep the FIRST request time so operators can see how long a credential
    // has outlived its owner's deletion request.
    erasureRequestedAt: stringField(existingRequestedAt) ?? nowISO,
    erasureRetryAfter: new Date(now.getTime() + PROVIDER_SECRET_ERASURE_ATTEMPT_LEASE_MS).toISOString(),
    updatedAt: nowISO,
  };
}

async function destroyForScope(scope: ProviderSecretErasureScope, secretVersionName: string | undefined): Promise<void> {
  // A reference without a usable version name is the only link to an external
  // secret: never treat it as "nothing stored".
  if (!secretVersionName) throw new MalformedSecretReferenceError();
  if (scope === "all_versions") await destroyCredentialSecret(secretVersionName);
  else await destroySupersededCredentialVersions(secretVersionName);
}

/** What one attempt read from the reference and acted on. */
interface ErasureAttempt {
  scope: ProviderSecretErasureScope;
  /** The raw stored scope value, which guards the settle transactions. */
  storedScope: unknown;
  secretVersionName: string | undefined;
}

/** The reference still describes the erasure this attempt performed. */
function unchangedSince(snap: { exists: boolean; get(field: string): unknown }, attempt: ErasureAttempt): boolean {
  return (
    snap.exists &&
    snap.get("erasureScope") === attempt.storedScope &&
    stringField(snap.get("secretVersionName")) === attempt.secretVersionName
  );
}

async function completeErasure(ref: DocumentReference, attempt: ErasureAttempt): Promise<void> {
  await db.runTransaction(async (tx) => {
    const snap = await tx.get(ref);
    // A concurrent replacement re-pointed the reference: its own pending
    // cleanup now owns the manifest, so leave it for that attempt.
    if (!unchangedSince(snap, attempt)) return;
    if (attempt.scope === "all_versions") {
      tx.delete(ref);
      return;
    }
    tx.set(ref, Object.fromEntries(ERASURE_FIELDS.map((field) => [field, FieldValue.delete()])), { merge: true });
  });
}

async function recordErasureFailure(
  ref: DocumentReference,
  attempt: ErasureAttempt,
  errorCode: string,
  now: Date,
): Promise<number | undefined> {
  return db.runTransaction(async (tx) => {
    const snap = await tx.get(ref);
    if (!unchangedSince(snap, attempt)) return undefined;
    const attemptCount = attemptCountOf(snap.get("erasureAttemptCount")) + 1;
    tx.set(
      ref,
      {
        erasureAttemptCount: attemptCount,
        erasureLastAttemptAt: now.toISOString(),
        erasureLastErrorCode: errorCode,
        erasureRetryAfter: new Date(now.getTime() + providerSecretErasureRetryDelayMs(attemptCount)).toISOString(),
      },
      { merge: true },
    );
    return attemptCount;
  });
}

/**
 * Destroy what the pending reference asks for, then settle the manifest:
 * success clears it, failure records retry evidence and backoff.
 */
async function attemptErasure(
  ref: DocumentReference,
  attempt: ErasureAttempt,
  context: { uid?: string; accountID?: string; reason: string },
  now: Date,
): Promise<ProviderSecretErasureOutcome> {
  try {
    await destroyForScope(attempt.scope, attempt.secretVersionName);
  } catch (error) {
    const errorCode = providerSecretErasureErrorCode(error);
    const attemptCount = await recordErasureFailure(ref, attempt, errorCode, now);
    logError({
      event: "provider_secret_erasure_failed",
      uid: context.uid,
      account_id_hash: context.accountID ? correlationHash(context.accountID) : undefined,
      reason: context.reason,
      scope: attempt.scope,
      error_code: errorCode,
      attempt_count: attemptCount,
    });
    return { complete: false, errorCode };
  }
  await completeErasure(ref, attempt);
  return { complete: true };
}

/**
 * Delete one account's hosted credential. The erasure intent — plus any
 * caller writes such as flipping the account to `deleted` — commits in one
 * transaction BEFORE Secret Manager is called; then every version is destroyed
 * and the reference is dropped. On failure the reference stays as the retry
 * manifest and the outcome is incomplete: callers must not report success.
 */
export async function eraseProviderAccountSecret(params: {
  uid: string;
  accountID: string;
  reason: Exclude<ProviderSecretErasureReason, "credential_replaced">;
  /** Writes committed atomically with the intent (writes only: reads must precede them). */
  alsoInIntentTransaction?: (tx: Transaction) => void;
  now?: Date;
}): Promise<ProviderSecretErasureOutcome> {
  const now = params.now ?? new Date();
  const ref = db.doc(providerAccountSecretRefPath(params.uid, params.accountID));
  const intent = await db.runTransaction(async (tx) => {
    const snap = await tx.get(ref);
    params.alsoInIntentTransaction?.(tx);
    if (!snap.exists) return undefined;
    tx.set(
      ref,
      pendingErasureFields("all_versions", params.reason, snap.get("erasureRequestedAt"), now),
      { merge: true },
    );
    return { secretVersionName: stringField(snap.get("secretVersionName")) };
  });
  if (!intent) return { complete: true };
  return attemptErasure(
    ref,
    { scope: "all_versions", storedScope: "all_versions", secretVersionName: intent.secretVersionName },
    params,
    now,
  );
}

/**
 * Point the account's reference at a newly stored credential version and
 * destroy every older version. The reference only moves forward, so a
 * concurrent replacement that stored a newer version keeps it. A pending
 * deletion is converted to superseded cleanup, which never destroys the new
 * credential. Cleanup failure does not fail the connect (the new credential
 * is stored and valid) but leaves a durable pending marker the reconciler
 * retries.
 */
export async function adoptStoredCredentialVersion(params: {
  uid: string;
  accountID: string;
  providerID: ProviderAccountSecretRefDoc["providerID"];
  secretVersionName: string;
  createdAt: string;
  updatedAt: string;
  now?: Date;
}): Promise<ProviderSecretErasureOutcome> {
  const now = params.now ?? new Date();
  const ref = db.doc(providerAccountSecretRefPath(params.uid, params.accountID));
  const liveVersionName = await db.runTransaction(async (tx) => {
    const snap = await tx.get(ref);
    const current = snap.exists ? stringField(snap.get("secretVersionName")) : undefined;
    const currentParsed = current ? parseSecretVersionName(current) : undefined;
    const incomingParsed = parseSecretVersionName(params.secretVersionName);
    const keepCurrent =
      current !== undefined &&
      currentParsed !== undefined &&
      incomingParsed !== undefined &&
      currentParsed.secretName === incomingParsed.secretName &&
      currentParsed.version > incomingParsed.version;
    const refDoc: ProviderAccountSecretRefDoc | Record<string, never> = keepCurrent
      ? {}
      : {
          uid: params.uid,
          providerID: params.providerID,
          accountID: params.accountID,
          secretVersionName: params.secretVersionName,
          createdAt: params.createdAt,
          updatedAt: params.updatedAt,
        };
    tx.set(
      ref,
      {
        ...refDoc,
        ...pendingErasureFields("superseded_versions", "credential_replaced", snap.get("erasureRequestedAt"), now),
      },
      { merge: true },
    );
    return keepCurrent ? current : params.secretVersionName;
  });
  return attemptErasure(
    ref,
    { scope: "superseded_versions", storedScope: "superseded_versions", secretVersionName: liveVersionName },
    { uid: params.uid, accountID: params.accountID, reason: "credential_replaced" },
    now,
  );
}

/** The callable error for a deletion whose Secret Manager erasure is still pending. */
export function providerCredentialErasurePendingError(
  accountID: string,
  outcome: ProviderSecretErasureOutcome,
): HttpsError {
  return new HttpsError(
    "unavailable",
    "The provider account was disconnected, but its stored credential could not be erased yet. " +
      "Erasure retries automatically; retry the deletion to check again.",
    { accountID, erasurePending: true, errorCode: outcome.errorCode ?? "credential_erasure_incomplete" },
  );
}

/** A pending reference as the reconciler's query returns it. */
interface PendingProviderSecretErasureDoc {
  readonly ref: DocumentReference;
  get(field: string): unknown;
}

interface ProviderSecretErasureReconcileResult {
  status: "completed" | "failed";
  errorCode?: string;
}

/**
 * Retry every pending reference the reconciler selected, sequentially (Secret
 * Manager quota), each from its CURRENT scope and live version.
 */
export async function reconcilePendingProviderSecretErasures(
  documents: readonly PendingProviderSecretErasureDoc[],
  dependencies: { now(): Date } = { now: () => new Date() },
): Promise<ProviderSecretErasureReconcileResult[]> {
  const results: ProviderSecretErasureReconcileResult[] = [];
  for (const document of documents) {
    const storedScope = document.get("erasureScope");
    const outcome = await attemptErasure(
      document.ref,
      {
        // An unknown scope never escalates to destroying the live credential.
        scope: storedScope === "all_versions" ? "all_versions" : "superseded_versions",
        storedScope,
        secretVersionName: stringField(document.get("secretVersionName")),
      },
      {
        uid: stringField(document.get("uid")),
        accountID: stringField(document.get("accountID")),
        reason: stringField(document.get("erasureReason")) ?? "unknown",
      },
      dependencies.now(),
    );
    results.push(outcome.complete ? { status: "completed" } : { status: "failed", errorCode: outcome.errorCode });
  }
  return results;
}
