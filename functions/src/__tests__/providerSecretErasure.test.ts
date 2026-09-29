/**
 * Credential custody: replacement, deletion, panic revoke and account erasure
 * must leave NO readable Secret Manager version, must never report success
 * while a version survives, and must leave durable retry evidence that the
 * reconciler consumes. Runs the real secrets.ts / providerSecretErasure.ts /
 * callable code against a stateful Secret Manager double.
 */

import { beforeEach, describe, expect, it, vi } from "vitest";

const env = vi.hoisted(() => {
  process.env.KMS_KEY_NAME = "projects/demo-project/locations/global/keyRings/test/cryptoKeys/credentials";
  process.env.ENFORCE_APP_CHECK = "false";
  return { store: new Map<string, Record<string, unknown>>() };
});

vi.mock("googleapis", async () => {
  const { fakeSecretManager } = await import("./fakeSecretManager.js");
  return {
    google: {
      auth: { getClient: async () => ({}) },
      cloudkms: () => fakeSecretManager.kms,
      secretmanager: () => fakeSecretManager,
    },
  };
});
vi.mock("../../../packages/functions-shared/src/adminRuntime.js", async () => {
  const { pathKeyedFirestore } = await import("./bola/callableBolaHarness.js");
  return { db: pathKeyedFirestore(env.store) };
});
vi.mock("firebase-admin/firestore", async () => {
  const actual = await vi.importActual<typeof import("firebase-admin/firestore")>("firebase-admin/firestore");
  const { pathKeyedFirestore } = await import("./bola/callableBolaHarness.js");
  return { ...actual, getFirestore: () => pathKeyedFirestore(env.store) };
});
vi.mock("../../../packages/functions-shared/src/auth.js", () => ({
  enforceAuthAndAppCheck: vi.fn(),
  assertAppCheck: vi.fn(),
}));

import { fakeSecretManager } from "./fakeSecretManager.js";
import { callableRequest, callableRunner, pathKeyedFirestore, quotaFirestore, seedDoc } from "./bola/callableBolaHarness.js";
import {
  CredentialErasureIncompleteError,
  destroyCredentialSecret,
  destroySupersededCredentialVersions,
  MalformedSecretReferenceError,
  parseSecretVersionName,
  retrieveCredential,
  storeCredential,
} from "../../../packages/functions-shared/src/secrets.js";
import {
  providerSecretErasureRetryDelayMs,
  reconcilePendingProviderSecretErasures,
  type PendingProviderSecretErasureDoc,
} from "../../../packages/functions-shared/src/providerSecretErasure.js";
import { eraseUserCloudData } from "../../../packages/functions-shared/src/accountDeletion.js";
import {
  providerAccountSecretRefPath,
  refreshUserProviderAccountQuota,
} from "../../../packages/functions-shared/src/quota.js";
import {
  applyHostedQuotaConnect,
  applyHostedQuotaCredentialDelete,
  applyProviderAccountDelete,
} from "../../../functions-identity/src/callables/providerAccountWrites.js";
import { deleteProviderCredential } from "../../../functions-identity/src/callables/providerAccountSnapshots.js";
import { __testing__ as panicTesting } from "../domains/ops/panic.js";

const UID = "custodyUser0000000000000001";
const ACCOUNT_ID = "codex_default";
const REF_PATH = providerAccountSecretRefPath(UID, ACCOUNT_ID);
const CREDENTIAL = (generation: number) => JSON.stringify({ fixture: `hosted-credential-${generation}` });

function requireRef(path = REF_PATH): Record<string, unknown> {
  const ref = env.store.get(path);
  if (!ref) throw new Error(`expected a secret reference at ${path}`);
  return ref;
}

function versionNameOf(ref: Record<string, unknown>): string {
  const name = ref.secretVersionName;
  if (typeof name !== "string") throw new Error("reference has no secretVersionName");
  return name;
}

function secretNameOf(versionName: string): string {
  const parsed = parseSecretVersionName(versionName);
  if (!parsed) throw new Error(`unparseable version name ${versionName}`);
  return parsed.secretName;
}

/** Connect (or re-connect) the hosted Codex account `times` times; returns every stored version name. */
async function connectHostedCredential(times: number): Promise<string[]> {
  const names: string[] = [];
  for (let generation = 1; generation <= times; generation += 1) {
    await applyHostedQuotaConnect(UID, ACCOUNT_ID, { provider: "codex", credential: CREDENTIAL(generation) });
    names.push(versionNameOf(requireRef()));
  }
  return names;
}

/** Store versions WITHOUT replacement cleanup: the state the pre-fix code left in production. */
async function seedLegacyVersions(accountID: string, provider: string, count: number): Promise<string[]> {
  const names: string[] = [];
  for (let generation = 1; generation <= count; generation += 1) {
    names.push(await storeCredential(UID, provider, CREDENTIAL(generation), accountID));
  }
  seedDoc(env.store, providerAccountSecretRefPath(UID, accountID), {
    uid: UID,
    providerID: provider,
    accountID,
    secretVersionName: names[names.length - 1],
    createdAt: "2026-09-01T00:00:00.000Z",
    updatedAt: "2026-09-01T00:00:00.000Z",
  });
  seedDoc(env.store, `users/${UID}/provider_accounts/${accountID}`, {
    id: accountID,
    providerID: provider,
    label: "Seeded",
    status: "connected",
    credentialKind: "bearer",
    storageScope: provider === "codex" ? "server_private" : "cloud_refreshable",
    redactedLabel: "seeded",
    isDefault: true,
    sortKey: 0,
    schemaVersion: 1,
    createdAt: "2026-09-01T00:00:00.000Z",
    updatedAt: "2026-09-01T00:00:00.000Z",
  });
  return names;
}

function pendingDocs(): PendingProviderSecretErasureDoc[] {
  const db = pathKeyedFirestore(env.store);
  return [...env.store.entries()]
    .filter(([path, data]) => path.startsWith("provider_account_secret_refs/") && typeof data.erasureRetryAfter === "string")
    .map(([path, data]) => ({
      // The harness's structural doc ref satisfies every call the reconciler makes.
      ref: db.doc(path) as unknown as PendingProviderSecretErasureDoc["ref"],
      get: (field: string) => data[field],
    }));
}

async function expectUnavailable(promise: Promise<unknown>): Promise<unknown> {
  try {
    await promise;
  } catch (error) {
    expect(error).toMatchObject({ code: "unavailable" });
    return error instanceof Object && "details" in error ? error.details : undefined;
  }
  throw new Error("expected the call to fail with unavailable");
}

beforeEach(() => {
  env.store.clear();
  fakeSecretManager.reset();
});

describe("version-complete Secret Manager erasure primitives", () => {
  it("destroying a credential secret destroys every version, not only the referenced one", async () => {
    const [v1, v2, v3] = await seedLegacyVersions(ACCOUNT_ID, "codex", 3);

    // Name the MIDDLE version: the pre-fix destroy would have spared v1 and v3.
    const result = await destroyCredentialSecret(v2);

    expect(result).toEqual({ destroyed: 3, alreadyDestroyed: 0 });
    expect(fakeSecretManager.versionStates(secretNameOf(v1))).toEqual({ 1: "DESTROYED", 2: "DESTROYED", 3: "DESTROYED" });
    for (const name of [v1, v2, v3]) expect(fakeSecretManager.readable(name)).toBe(false);
  });

  it("superseded cleanup destroys only versions older than the live credential", async () => {
    const [v1, v2, v3] = await seedLegacyVersions(ACCOUNT_ID, "codex", 3);

    await destroySupersededCredentialVersions(v2);

    expect(fakeSecretManager.versionStates(secretNameOf(v1))).toEqual({ 1: "DESTROYED", 2: "ENABLED", 3: "ENABLED" });
    expect(await retrieveCredential(v3)).toBe(CREDENTIAL(3));
  });

  it("pages through every version of a long-lived secret", async () => {
    const names = await seedLegacyVersions(ACCOUNT_ID, "codex", 5);
    fakeSecretManager.maxPageSize = 2;

    const result = await destroyCredentialSecret(names[4]);

    expect(result.destroyed).toBe(5);
    for (const name of names) expect(fakeSecretManager.readable(name)).toBe(false);
  });

  it("attempts every version before failing closed on a partial failure, then completes on retry", async () => {
    const [v1, v2, v3] = await seedLegacyVersions(ACCOUNT_ID, "codex", 3);
    fakeSecretManager.failingDestroys.add(v2);

    const failure = await destroyCredentialSecret(v3).catch((error: unknown) => error);

    expect(failure).toBeInstanceOf(CredentialErasureIncompleteError);
    expect(failure).toMatchObject({ failedVersions: 1, result: { destroyed: 2, alreadyDestroyed: 0 } });
    expect(fakeSecretManager.readable(v1)).toBe(false);
    expect(fakeSecretManager.readable(v2)).toBe(true);
    expect(fakeSecretManager.readable(v3)).toBe(false);

    fakeSecretManager.failingDestroys.clear();
    expect(await destroyCredentialSecret(v3)).toEqual({ destroyed: 1, alreadyDestroyed: 2 });
    expect(fakeSecretManager.readable(v2)).toBe(false);
  });

  it("treats an absent secret as nothing left to erase", async () => {
    await expect(destroyCredentialSecret("projects/demo-project/secrets/never-created/versions/7")).resolves.toEqual({
      destroyed: 0,
      alreadyDestroyed: 0,
    });
  });

  it("fails closed when the version listing itself is refused", async () => {
    const [, v2] = await seedLegacyVersions(ACCOUNT_ID, "codex", 2);
    fakeSecretManager.listFailure = Object.assign(new Error("permission denied"), { code: 403 });

    await expect(destroyCredentialSecret(v2)).rejects.toMatchObject({ code: 403 });
    expect(fakeSecretManager.readable(v2)).toBe(true);
  });

  it("rejects a reference that does not name a Secret Manager version", async () => {
    await expect(destroyCredentialSecret(" ")).rejects.toBeInstanceOf(MalformedSecretReferenceError);
    await expect(destroySupersededCredentialVersions("projects/p/secrets/s")).rejects.toBeInstanceOf(
      MalformedSecretReferenceError,
    );
  });
});

describe("hosted credential replacement", () => {
  it("destroys the replaced credential when a hosted account reconnects", async () => {
    const [first, second] = await connectHostedCredential(2);

    expect(fakeSecretManager.readable(first)).toBe(false);
    expect(await retrieveCredential(second)).toBe(CREDENTIAL(2));
    const ref = requireRef();
    expect(ref.secretVersionName).toBe(second);
    expect(ref.erasureScope).toBeUndefined();
    expect(ref.erasureRetryAfter).toBeUndefined();
  });

  it("keeps a durable cleanup marker when a superseded version cannot be destroyed, and the reconciler finishes it", async () => {
    const [first] = await connectHostedCredential(1);
    fakeSecretManager.failingDestroys.add(first);

    // The new credential is stored and valid, so the connect itself succeeds.
    await applyHostedQuotaConnect(UID, ACCOUNT_ID, { provider: "codex", credential: CREDENTIAL(2) });
    const pending = requireRef();
    expect(pending).toMatchObject({
      erasureScope: "superseded_versions",
      erasureReason: "credential_replaced",
      erasureAttemptCount: 1,
      erasureLastErrorCode: "credential_erasure_incomplete",
    });
    expect(fakeSecretManager.readable(first)).toBe(true);

    fakeSecretManager.failingDestroys.clear();
    expect(await reconcilePendingProviderSecretErasures(pendingDocs())).toEqual([{ status: "completed" }]);
    expect(fakeSecretManager.readable(first)).toBe(false);
    expect(await retrieveCredential(versionNameOf(requireRef()))).toBe(CREDENTIAL(2));
    expect(requireRef().erasureScope).toBeUndefined();
  });

  it("a reconnect after a refused deletion keeps the new credential and destroys every older one", async () => {
    const [first] = await connectHostedCredential(1);
    fakeSecretManager.failingDestroys.add(first);
    await expectUnavailable(applyProviderAccountDelete(UID, ACCOUNT_ID));
    expect(requireRef().erasureScope).toBe("all_versions");

    fakeSecretManager.failingDestroys.clear();
    await applyHostedQuotaConnect(UID, ACCOUNT_ID, { provider: "codex", credential: CREDENTIAL(2) });

    const ref = requireRef();
    const live = versionNameOf(ref);
    expect(live).not.toBe(first);
    expect(await retrieveCredential(live)).toBe(CREDENTIAL(2));
    expect(fakeSecretManager.readable(first)).toBe(false);
    expect(ref.erasureScope).toBeUndefined();
    // The stale deletion intent must never come back and destroy the new credential.
    await reconcilePendingProviderSecretErasures(pendingDocs());
    expect(await retrieveCredential(live)).toBe(CREDENTIAL(2));
  });
});

describe("provider account deletion", () => {
  it("destroys every version of a replaced credential and drops the reference", async () => {
    const names = await seedLegacyVersions(ACCOUNT_ID, "codex", 3);

    await expect(applyProviderAccountDelete(UID, ACCOUNT_ID)).resolves.toEqual({ success: true, accountID: ACCOUNT_ID });

    for (const name of names) expect(fakeSecretManager.readable(name)).toBe(false);
    expect(env.store.has(REF_PATH)).toBe(false);
    expect(env.store.get(`users/${UID}/provider_accounts/${ACCOUNT_ID}`)?.status).toBe("deleted");
  });

  it("fails closed when Secret Manager refuses: no success, the reference stays as the retry manifest", async () => {
    const names = await seedLegacyVersions(ACCOUNT_ID, "codex", 2);
    fakeSecretManager.failingDestroys.add(names[0]);
    const before = Date.now();

    const details = await expectUnavailable(applyProviderAccountDelete(UID, ACCOUNT_ID));

    expect(details).toMatchObject({ accountID: ACCOUNT_ID, erasurePending: true, errorCode: "credential_erasure_incomplete" });
    const ref = requireRef();
    expect(ref).toMatchObject({
      secretVersionName: names[1],
      erasureScope: "all_versions",
      erasureReason: "provider_account_delete",
      erasureAttemptCount: 1,
      erasureLastErrorCode: "credential_erasure_incomplete",
    });
    const retryAfter = Date.parse(String(ref.erasureRetryAfter));
    expect(retryAfter).toBeGreaterThanOrEqual(before + providerSecretErasureRetryDelayMs(1));
    // Deletion is still honored: the account stops being used immediately.
    expect(env.store.get(`users/${UID}/provider_accounts/${ACCOUNT_ID}`)?.status).toBe("deleted");
    expect(fakeSecretManager.readable(names[0])).toBe(true);
    expect(fakeSecretManager.readable(names[1])).toBe(false);
  });

  it("the reconciler completes a refused deletion once Secret Manager recovers", async () => {
    const names = await seedLegacyVersions(ACCOUNT_ID, "codex", 2);
    fakeSecretManager.failingDestroys.add(names[0]);
    await expectUnavailable(applyProviderAccountDelete(UID, ACCOUNT_ID));

    fakeSecretManager.failingDestroys.clear();
    expect(await reconcilePendingProviderSecretErasures(pendingDocs())).toEqual([{ status: "completed" }]);

    for (const name of names) expect(fakeSecretManager.readable(name)).toBe(false);
    expect(env.store.has(REF_PATH)).toBe(false);
    // A user retry after completion is idempotent success.
    await expect(applyProviderAccountDelete(UID, ACCOUNT_ID)).resolves.toEqual({ success: true, accountID: ACCOUNT_ID });
  });

  it("backs a persistent failure off exponentially instead of hot-looping", async () => {
    const names = await seedLegacyVersions(ACCOUNT_ID, "codex", 1);
    fakeSecretManager.failingDestroys.add(names[0]);
    await expectUnavailable(applyProviderAccountDelete(UID, ACCOUNT_ID));

    const now = new Date("2030-01-01T00:00:00.000Z");
    const results = await reconcilePendingProviderSecretErasures(pendingDocs(), { now: () => now });

    expect(results).toEqual([{ status: "failed", errorCode: "credential_erasure_incomplete" }]);
    const ref = requireRef();
    expect(ref.erasureAttemptCount).toBe(2);
    expect(ref.erasureRetryAfter).toBe(new Date(now.getTime() + providerSecretErasureRetryDelayMs(2)).toISOString());
    expect(providerSecretErasureRetryDelayMs(2)).toBe(2 * providerSecretErasureRetryDelayMs(1));
    expect(providerSecretErasureRetryDelayMs(50)).toBe(6 * 60 * 60 * 1000);
  });

  it("keeps a malformed reference as the retry manifest instead of assuming nothing was stored", async () => {
    seedDoc(env.store, REF_PATH, {
      uid: UID,
      providerID: "codex",
      accountID: ACCOUNT_ID,
      secretVersionName: " ",
      createdAt: "2026-09-01T00:00:00.000Z",
      updatedAt: "2026-09-01T00:00:00.000Z",
    });
    seedDoc(env.store, `users/${UID}/provider_accounts/${ACCOUNT_ID}`, {
      id: ACCOUNT_ID,
      providerID: "codex",
      label: "Malformed",
      status: "connected",
      credentialKind: "session",
      storageScope: "server_private",
      redactedLabel: "x",
      isDefault: true,
      sortKey: 0,
      schemaVersion: 1,
      createdAt: "2026-09-01T00:00:00.000Z",
      updatedAt: "2026-09-01T00:00:00.000Z",
    });

    const details = await expectUnavailable(applyProviderAccountDelete(UID, ACCOUNT_ID));

    expect(details).toMatchObject({ errorCode: "malformed_secret_ref" });
    expect(requireRef()).toMatchObject({ erasureScope: "all_versions", erasureLastErrorCode: "malformed_secret_ref" });
  });

  it("hosted credential deletion is version-complete and fails closed", async () => {
    const names = await seedLegacyVersions(ACCOUNT_ID, "codex", 2);
    fakeSecretManager.failingDestroys.add(names[1]);

    await expectUnavailable(applyHostedQuotaCredentialDelete(UID, ACCOUNT_ID));
    expect(requireRef()).toMatchObject({ erasureScope: "all_versions", erasureReason: "hosted_quota_credential_delete" });
    expect(fakeSecretManager.readable(names[0])).toBe(false);

    fakeSecretManager.failingDestroys.clear();
    await expect(applyHostedQuotaCredentialDelete(UID, ACCOUNT_ID)).resolves.toEqual({ success: true, accountID: ACCOUNT_ID });
    for (const name of names) expect(fakeSecretManager.readable(name)).toBe(false);
    expect(env.store.has(REF_PATH)).toBe(false);
  });

  it("legacy credential deletion no longer swallows a refused destroy", async () => {
    const names = await seedLegacyVersions("openai_default", "openai", 2);
    fakeSecretManager.failingDestroys.add(names[0]);
    const run = callableRunner(deleteProviderCredential);

    await expectUnavailable(run(callableRequest(UID, { provider: "openai" })));
    expect(requireRef(providerAccountSecretRefPath(UID, "openai_default"))).toMatchObject({
      erasureScope: "all_versions",
      erasureReason: "legacy_credential_delete",
    });
    expect(env.store.get(`users/${UID}/provider_connections/openai`)?.status).toBe("disconnected");

    fakeSecretManager.failingDestroys.clear();
    await expect(run(callableRequest(UID, { provider: "openai" }))).resolves.toEqual({ success: true, provider: "openai" });
    for (const name of names) expect(fakeSecretManager.readable(name)).toBe(false);
  });
});

describe("panic revoke", () => {
  it("reports a refused erasure as a failure and keeps the reference instead of deleting it", async () => {
    const names = await seedLegacyVersions(ACCOUNT_ID, "codex", 2);
    fakeSecretManager.failingDestroys.add(names[0]);

    const result = await panicTesting.revokeProviderCredentials(UID);

    expect(result).toEqual({ revoked: 1, secretFailures: 1 });
    expect(requireRef()).toMatchObject({ erasureScope: "all_versions", erasureReason: "panic_revoke" });
    expect(env.store.get(`users/${UID}/provider_accounts/${ACCOUNT_ID}`)?.status).toBe("deleted");

    // A second panic retries the already-deleted account's pending erasure.
    fakeSecretManager.failingDestroys.clear();
    expect(await panicTesting.revokeProviderCredentials(UID)).toEqual({ revoked: 0, secretFailures: 0 });
    for (const name of names) expect(fakeSecretManager.readable(name)).toBe(false);
    expect(env.store.has(REF_PATH)).toBe(false);
  });
});

describe("account erasure", () => {
  function accountErasureDb() {
    const deleted: string[] = [];
    const docRef = (path: string) => ({ path, listCollections: async () => [] });
    const db = {
      collection: (path: string) => ({
        listDocuments: async () => [],
        where: (field: string, _op: "==", value: unknown) => ({
          get: async () => ({
            docs: [...env.store.entries()]
              .filter(([key, data]) => key.startsWith(`${path}/`) && data[field] === value)
              .map(([key, data]) => ({ id: key.slice(path.length + 1), ref: docRef(key), get: (name: string) => data[name] })),
          }),
        }),
      }),
      doc: docRef,
      batch: () => {
        const pending: string[] = [];
        return {
          delete: (ref: { path?: string }) => {
            if (ref.path) pending.push(ref.path);
          },
          commit: async () => {
            deleted.push(...pending.splice(0));
          },
        };
      },
    };
    return { db, deleted };
  }

  it("leaves no readable version of a credential that was replaced before erasure", async () => {
    const names = await seedLegacyVersions(ACCOUNT_ID, "codex", 3);
    const { db, deleted } = accountErasureDb();

    const summary = await eraseUserCloudData(db, UID, {
      destroyCredentialSecret,
      deleteStorageObjects: async () => undefined,
      logger: { warn() {} },
    });

    expect(summary).toMatchObject({ destroyedSecrets: 1, failedSecretDestroys: 0, cloudDataDeleted: true });
    for (const name of names) expect(fakeSecretManager.readable(name)).toBe(false);
    expect(deleted).toContain(REF_PATH);
  });
});

describe("credential serving", () => {
  it("never serves a credential whose erasure is pending", async () => {
    await seedLegacyVersions("openai_default", "openai", 1);
    const refPath = providerAccountSecretRefPath(UID, "openai_default");
    seedDoc(env.store, refPath, { ...requireRef(refPath), erasureScope: "all_versions" });
    const accessSpy = vi.spyOn(fakeSecretManager.projects.secrets.versions, "access");
    const db = quotaFirestore(env.store);

    await expect(refreshUserProviderAccountQuota(db, UID, "openai_default")).rejects.toThrow(
      /Credential erasure is pending/u,
    );
    expect(accessSpy).not.toHaveBeenCalled();
  });
});
