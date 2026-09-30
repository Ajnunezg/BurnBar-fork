/**
 * @fileoverview Provider quota snapshot upload + legacy credential deletion callables
 */

import { HttpsError, onCall, type CallableRequest } from "firebase-functions/v2/https";

import { getConfig } from "@openburnbar/functions-shared/config.js";
import { enforceAuthAndAppCheck } from "@openburnbar/functions-shared/auth.js";
import { db } from "@openburnbar/functions-shared/adminRuntime.js";
import { wrapCallableHandler } from "@openburnbar/functions-shared/logging.js";
import { assertSelfHostedProvider } from "@openburnbar/functions-shared/shared/accounts.js";
import { sanitizeUploadedQuotaSnapshot } from "@openburnbar/functions-shared/shared/providerConnect.js";
import { assertProvider, nowISO, requiredIdentifier } from "@openburnbar/functions-shared/shared/validators.js";
import {
  eraseProviderAccountSecret,
  providerCredentialErasurePendingError,
} from "@openburnbar/functions-shared/providerSecretErasure.js";
import { requireProviderAccountDoc } from "@openburnbar/functions-shared/guards.js";
import { FUNCTIONS_REGION } from "@openburnbar/functions-shared/runtimeOptions.js";

// ---------------------------------------------------------------------------
// Callable: uploadProviderQuotaSnapshot
// ---------------------------------------------------------------------------

export const uploadProviderQuotaSnapshot = onCall(
  {
    region: FUNCTIONS_REGION,
    enforceAppCheck: getConfig().enforceAppCheck,
    maxInstances: 100,
  },
  wrapCallableHandler("uploadProviderQuotaSnapshot", async (request: CallableRequest<Record<string, unknown>>) => {
    const uid = request.auth?.uid;
    if (!uid) {
      throw new HttpsError("unauthenticated", "Sign in before uploading quota snapshots.");
    }
    enforceAuthAndAppCheck(request, uid);
    const accountID = requiredIdentifier(request.data.accountID, "accountID");
    const accountRef = db.doc(`users/${uid}/provider_accounts/${accountID}`);
    const accountSnap = await accountRef.get();
    if (!accountSnap.exists) {
      throw new HttpsError("not-found", "Provider account not found.");
    }
    const account = requireProviderAccountDoc(accountSnap.data());
    if (account.storageScope !== "local_only") {
      throw new HttpsError("failed-precondition", "Only self-hosted local-only accounts can upload runner snapshots.");
    }
    assertSelfHostedProvider(account.providerID);
    const snapshot = sanitizeUploadedQuotaSnapshot(account, request.data);
    const snapshotID = `${account.providerID}_${account.id}_${snapshot.sourceId}`;
    const now = nowISO();
    await db.runTransaction(async (tx) => {
      tx.set(db.doc(`users/${uid}/quota_snapshots/${snapshotID}`), snapshot, { merge: true });
      tx.update(accountRef, {
        status: "connected",
        lastRefreshAt: now,
        lastErrorCode: null,
        updatedAt: now,
      });
    });
    return snapshot;
  }),
);

// ---------------------------------------------------------------------------
// Callable: deleteProviderCredential (legacy default-account credential delete)
// ---------------------------------------------------------------------------

export const deleteProviderCredential = onCall(
  {
    region: FUNCTIONS_REGION,
    enforceAppCheck: getConfig().enforceAppCheck,
    maxInstances: 100,
  },
  wrapCallableHandler("deleteProviderCredential", async (request: CallableRequest<{ provider: string }>) => {
    const { provider } = request.data;
    const uid = request.auth?.uid;

    if (!uid) {
      throw new HttpsError("unauthenticated", "Sign in before deleting provider credentials.");
    }
    enforceAuthAndAppCheck(request, uid);
    assertProvider(provider);

    const accountID = `${provider}_default`;
    const now = nowISO();
    const cleared = { lastValidatedAt: null, lastRefreshAt: null, lastErrorCode: null, updatedAt: now };
    // Every version of the stored secret is destroyed; a failure keeps the
    // reference as the reconciler's retry manifest and is reported below.
    const erasure = await eraseProviderAccountSecret({
      uid,
      accountID,
      reason: "legacy_credential_delete",
      alsoInIntentTransaction: (tx) => {
        tx.set(db.doc(`users/${uid}/provider_accounts/${accountID}`), { status: "deleted", ...cleared }, { merge: true });
        tx.set(db.doc(`users/${uid}/provider_connections/${provider}`), { status: "disconnected", ...cleared }, { merge: true });
      },
    });

    // Stale-mark the quota snapshot.
    const snapRef = db.doc(`users/${uid}/quota_snapshots/${provider}_default`);
    await snapRef.set(
      {
        confidence: "stale",
        statusMessage: "Credential deleted; snapshot is stale.",
        updatedAt: now,
      },
      { merge: true },
    );

    if (!erasure.complete) {
      throw providerCredentialErasurePendingError(accountID, erasure);
    }
    return { success: true, provider };
  }),
);
