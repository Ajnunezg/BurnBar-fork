/**
 * @fileoverview Firestore write helpers backing the provider-account callables.
 *
 * These are the post-authorization bodies of the connect/update/delete
 * callables in providerAccounts.ts. Hosted-credential writes go through
 * providerSecretErasure.ts: a replacement destroys every superseded Secret
 * Manager version, and a deletion persists its erasure intent, destroys every
 * version, and throws `unavailable` (never `success`) while any version
 * remains — the reference stays as the reconciler's retry manifest.
 */

import { HttpsError } from "firebase-functions/v2/https";

import { db } from "@openburnbar/functions-shared/adminRuntime.js";
import { logError } from "@openburnbar/functions-shared/logging.js";
import { ACCOUNT_SCHEMA_VERSION, assertHostedProvider, connectionDocFromAccount, hostedCredentialKind, hostedProviderLabel } from "@openburnbar/functions-shared/shared/accounts.js";
import { normalizeHostedCredential } from "@openburnbar/functions-shared/shared/providerConnect.js";
import { boundedTrimmedString, nowISO } from "@openburnbar/functions-shared/shared/validators.js";
import { storeCredential } from "@openburnbar/functions-shared/secrets.js";
import {
  adoptStoredCredentialVersion,
  eraseProviderAccountSecret,
  providerCredentialErasurePendingError,
} from "@openburnbar/functions-shared/providerSecretErasure.js";
import { revokeAllLinksForAccount, upsertDeviceLink } from "@openburnbar/functions-shared/domains/device-links/index.js";
import { optionalStringField, requireProviderAccountDoc, stripUndefinedObject } from "@openburnbar/functions-shared/guards.js";
import type { ProviderAccountDoc } from "@openburnbar/functions-shared/types.js";

type HostedQuotaConnectInput = {
  provider: string;
  credential: unknown;
  label?: string;
  accountID?: string;
  sourceDeviceID?: string;
  deviceDisplayName?: string;
};

export async function applyHostedQuotaConnect(
  uid: string,
  accountID: string,
  data: HostedQuotaConnectInput,
): Promise<ProviderAccountDoc> {
  const provider = data.provider;
  assertHostedProvider(provider);
  const credential = normalizeHostedCredential(provider, data.credential);
  const providerLabel = hostedProviderLabel(provider);
  const accountRedactedLabel = `${providerLabel} credential stored in Secret Manager`;
  const label = boundedTrimmedString(data.label, "label", 80) ?? `Hosted ${providerLabel}`;
  const now = nowISO();
  const accountRef = db.doc(`users/${uid}/provider_accounts/${accountID}`);
  const existing = await accountRef.get();
  const createdAt = existing.exists ? (optionalStringField(existing.get("createdAt")) ?? now) : now;
  const secretVersionName = await storeCredential(uid, provider, credential, accountID);
  await adoptStoredCredentialVersion({
    uid,
    accountID,
    providerID: provider,
    secretVersionName,
    createdAt,
    updatedAt: now,
  });

  const accountDoc: ProviderAccountDoc = {
    id: accountID,
    providerID: provider,
    label,
    identityHint: undefined,
    status: "connected",
    credentialKind: hostedCredentialKind(provider),
    storageScope: "server_private",
    redactedLabel: accountRedactedLabel,
    sourceDeviceID: boundedTrimmedString(data.sourceDeviceID, "sourceDeviceID", 128),
    linkedSwitcherProfileID: undefined,
    isDefault: data.accountID == null || accountID.endsWith("_default"),
    sortKey: accountID.endsWith("_default") ? 0 : Date.now(),
    lastValidatedAt: now,
    lastRefreshAt: now,
    lastErrorCode: undefined,
    schemaVersion: ACCOUNT_SCHEMA_VERSION,
    createdAt,
    updatedAt: now,
  };

  await db.runTransaction(async (tx) => {
    tx.set(accountRef, stripUndefinedObject(accountDoc), { merge: true });
    if (accountDoc.isDefault) {
      tx.set(db.doc(`users/${uid}/provider_connections/${provider}`), connectionDocFromAccount(accountDoc), {
        merge: true,
      });
    }
  });
  if (accountDoc.sourceDeviceID) {
    await upsertDeviceLink({
      db,
      uid,
      accountID,
      deviceID: accountDoc.sourceDeviceID,
      deviceDisplayName: data.deviceDisplayName ?? accountDoc.sourceDeviceID,
      capability: "owner",
    });
  }
  return accountDoc;
}

type SelfHostedQuotaConnectInput = {
  provider: string;
  label?: string;
  accountID?: string;
  sourceDeviceID?: string;
  deviceDisplayName?: string;
};

export async function applySelfHostedQuotaConnect(
  uid: string,
  accountID: string,
  data: SelfHostedQuotaConnectInput,
): Promise<ProviderAccountDoc> {
  const provider = data.provider;
  const label = boundedTrimmedString(data.label, "label", 80) ?? `${hostedProviderLabel(provider)} self-hosted`;
  const now = nowISO();
  const existing = await db.doc(`users/${uid}/provider_accounts/${accountID}`).get();
  const accountDoc: ProviderAccountDoc = {
    id: accountID,
    providerID: provider,
    label,
    identityHint: undefined,
    status: "connected",
    credentialKind: "session",
    storageScope: "local_only",
    redactedLabel: "Self-hosted runner",
    sourceDeviceID: boundedTrimmedString(data.sourceDeviceID, "sourceDeviceID", 128),
    linkedSwitcherProfileID: undefined,
    isDefault: data.accountID == null || accountID.endsWith("_default"),
    sortKey: accountID.endsWith("_default") ? 0 : Date.now(),
    lastValidatedAt: now,
    lastRefreshAt: undefined,
    lastErrorCode: undefined,
    schemaVersion: ACCOUNT_SCHEMA_VERSION,
    createdAt: existing.exists ? (optionalStringField(existing.get("createdAt")) ?? now) : now,
    updatedAt: now,
  };

  await db.runTransaction(async (tx) => {
    tx.set(db.doc(`users/${uid}/provider_accounts/${accountID}`), stripUndefinedObject(accountDoc), {
      merge: true,
    });
    if (accountDoc.isDefault) {
      tx.set(db.doc(`users/${uid}/provider_connections/${provider}`), connectionDocFromAccount(accountDoc), {
        merge: true,
      });
    }
  });

  if (accountDoc.sourceDeviceID) {
    try {
      await upsertDeviceLink({
        db,
        uid,
        accountID,
        deviceID: accountDoc.sourceDeviceID,
        deviceDisplayName: data.deviceDisplayName ?? accountDoc.sourceDeviceID,
        capability: "owner",
      });
    } catch (linkErr) {
      logError({
        event: "device_links_upsert_failed",
        uid,
        accountID,
        detail: String(linkErr),
      });
    }
  }
  return accountDoc;
}

export async function applyHostedQuotaCredentialDelete(
  uid: string,
  accountID: string,
): Promise<{ success: true; accountID: string }> {
  const accountRef = db.doc(`users/${uid}/provider_accounts/${accountID}`);
  const accountSnap = await accountRef.get();
  if (!accountSnap.exists) {
    throw new HttpsError("not-found", "Provider account not found.");
  }
  const account = requireProviderAccountDoc(accountSnap.data());
  if (account.storageScope !== "server_private") {
    throw new HttpsError("failed-precondition", "Account is not a hosted quota account.");
  }
  const now = nowISO();
  const erasure = await eraseProviderAccountSecret({
    uid,
    accountID,
    reason: "hosted_quota_credential_delete",
    alsoInIntentTransaction: (tx) => {
      tx.set(accountRef, deletedAccountFields(now), { merge: true });
    },
  });
  if (!erasure.complete) {
    throw providerCredentialErasurePendingError(accountID, erasure);
  }
  return { success: true, accountID };
}

/** Account-doc fields for a deleted provider account (credential erasure requested). */
function deletedAccountFields(now: string): Record<string, unknown> {
  return {
    status: "deleted",
    lastValidatedAt: null,
    lastRefreshAt: null,
    lastErrorCode: null,
    updatedAt: now,
  };
}

type ProviderAccountUpdateInput = {
  label?: string;
  isDefault?: boolean;
  disabled?: boolean;
};

export async function applyProviderAccountUpdate(
  uid: string,
  accountID: string,
  data: ProviderAccountUpdateInput,
): Promise<ProviderAccountDoc> {
  const accountRef = db.doc(`users/${uid}/provider_accounts/${accountID}`);
  const snap = await accountRef.get();
  if (!snap.exists) {
    throw new HttpsError("not-found", "Provider account not found.");
  }
  const current = requireProviderAccountDoc(snap.data());
  const now = nowISO();
  const next: Partial<ProviderAccountDoc> = {
    updatedAt: now,
  };
  if (typeof data.label === "string" && data.label.trim()) {
    next.label = data.label.trim();
  }
  if (typeof data.isDefault === "boolean") {
    next.isDefault = data.isDefault;
  }
  if (typeof data.disabled === "boolean") {
    next.status = data.disabled ? "disabled" : "connected";
  }

  await db.runTransaction(async (tx) => {
    if (next.isDefault === true) {
      const siblingSnap = await db
        .collection(`users/${uid}/provider_accounts`)
        .where("providerID", "==", current.providerID)
        .where("isDefault", "==", true)
        .get();

      for (const sibling of siblingSnap.docs) {
        if (sibling.id !== accountID) {
          tx.set(sibling.ref, { isDefault: false, updatedAt: now }, { merge: true });
        }
      }
    }

    tx.set(accountRef, next, { merge: true });
  });

  const updatedSnap = await accountRef.get();
  const updated = requireProviderAccountDoc(updatedSnap.data());
  if (updated.isDefault) {
    await db
      .doc(`users/${uid}/provider_connections/${updated.providerID}`)
      .set(connectionDocFromAccount(updated), { merge: true });
  }
  if (current.isDefault && !updated.isDefault) {
    await db
      .doc(`users/${uid}/provider_connections/${updated.providerID}`)
      .set({ status: "disconnected", updatedAt: now }, { merge: true });
  }
  return updated;
}

export async function applyProviderAccountDelete(
  uid: string,
  accountID: string,
): Promise<{ success: true; accountID: string }> {
  const accountRef = db.doc(`users/${uid}/provider_accounts/${accountID}`);
  const accountSnap = await accountRef.get();
  if (!accountSnap.exists) {
    throw new HttpsError("not-found", "Provider account not found.");
  }
  const account = requireProviderAccountDoc(accountSnap.data());

  // The account stops being used the moment deletion is requested; the
  // credential's erasure is durable (retried by the reconciler) and a failure
  // is reported below instead of being swallowed.
  const now = nowISO();
  const erasure = await eraseProviderAccountSecret({
    uid,
    accountID,
    reason: "provider_account_delete",
    alsoInIntentTransaction: (tx) => {
      tx.set(accountRef, deletedAccountFields(now), { merge: true });
      if (account.isDefault) {
        tx.set(
          db.doc(`users/${uid}/provider_connections/${account.providerID}`),
          { ...deletedAccountFields(now), status: "disconnected" },
          { merge: true },
        );
      }
    },
  });

  const snapshotQuery = await db.collection(`users/${uid}/quota_snapshots`).where("accountID", "==", accountID).get();
  const batch = db.batch();
  for (const doc of snapshotQuery.docs) {
    batch.set(
      doc.ref,
      {
        confidence: "stale",
        statusMessage: "Credential deleted; snapshot is stale.",
        updatedAt: now,
      },
      { merge: true },
    );
  }
  await batch.commit();

  try {
    await revokeAllLinksForAccount(db, uid, accountID);
  } catch (linkErr) {
    logError({
      event: "device_links_cascade_revoke_failed",
      uid,
      accountID,
      detail: String(linkErr),
    });
  }

  if (!erasure.complete) {
    throw providerCredentialErasurePendingError(accountID, erasure);
  }
  return { success: true, accountID };
}
