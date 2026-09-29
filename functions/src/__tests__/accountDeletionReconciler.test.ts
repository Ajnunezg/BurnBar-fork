import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import { describe, expect, it, vi } from "vitest";

const firestore = vi.hoisted(() => {
  type RecordedQuery = { collection: string; where: unknown[][]; orderBy: unknown[][]; limit?: number };
  const queries: RecordedQuery[] = [];
  const docsByCollection = new Map<string, unknown[]>();
  const failingCollections = new Set<string>();
  function collection(name: string) {
    const recorded: RecordedQuery = { collection: name, where: [], orderBy: [] };
    const chain = {
      where: (...args: unknown[]) => {
        recorded.where.push(args);
        return chain;
      },
      orderBy: (...args: unknown[]) => {
        recorded.orderBy.push(args);
        return chain;
      },
      limit: (count: number) => {
        recorded.limit = count;
        return chain;
      },
      get: async () => {
        queries.push(recorded);
        if (failingCollections.has(name)) throw new Error(`${name} query unavailable`);
        return { docs: docsByCollection.get(name) ?? [] };
      },
    };
    return chain;
  }
  return { queries, docsByCollection, failingCollections, db: { collection } };
});

vi.mock("firebase-functions/v2/scheduler", () => ({ onSchedule: (_options: unknown, handler: unknown) => ({ run: handler }) }));
vi.mock("../../../packages/functions-shared/src/adminRuntime.js", () => ({ db: firestore.db, auth: {} }));
vi.mock("../../../packages/functions-shared/src/providerSecretErasure.js", () => ({
  reconcilePendingProviderSecretErasures: vi.fn(async (docs: unknown[]) => docs.map(() => ({ status: "completed" }))),
}));
vi.mock("../../../packages/functions-shared/src/accountDeletion.js", () => ({ eraseUserAccount: vi.fn(), isAccountErasureResumable: vi.fn() }));
vi.mock("../../../packages/functions-shared/src/logging.js", () => ({ logError: vi.fn(), logInfo: vi.fn() }));
vi.mock("../../../packages/functions-shared/src/runtimeOptions.js", () => ({ FUNCTIONS_REGION: "us-central1" }));
vi.mock("../../../packages/functions-shared/src/secrets.js", async (importOriginal) => ({
  ...(await importOriginal<typeof import("../../../packages/functions-shared/src/secrets.js")>()),
  destroyCredentialSecret: vi.fn(),
}));

import {
  PROVIDER_SECRET_RECONCILE_BATCH_LIMIT,
  reconcileAccountErasures,
  reconcilePendingAccountErasures,
  reconcileProviderSecretErasureQueue,
} from "../domains/lifecycle/accountDeletionReconciler.js";
import { reconcilePendingProviderSecretErasures } from "../../../packages/functions-shared/src/providerSecretErasure.js";

function tombstone(id: string, attemptCount = 0) {
  const patches: Record<string, unknown>[] = [];
  return {
    document: {
      id,
      get: (field: string) => (field === "reconciliationAttemptCount" ? attemptCount : undefined),
      ref: {
        set: async (data: Record<string, unknown>) => {
          patches.push(data);
        },
      },
    },
    patches,
  };
}

describe("account erasure reconciler", () => {
  const now = new Date("2026-07-10T12:00:00.000Z");

  it("quarantines a poison tombstone without removing the account barrier", async () => {
    const poison = tombstone("poison");
    const results = await reconcilePendingAccountErasures([poison.document], {
      isResumable: async () => false,
      erase: async () => undefined,
      now: () => now,
    });

    expect(results).toEqual([{ uid: "poison", status: "quarantined", errorCode: "missing_resumable_receipt" }]);
    expect(poison.patches).toEqual([
      expect.objectContaining({
        pending: false,
        reconciliationStatus: "quarantined",
        updatedAt: now.toISOString(),
      }),
    ]);
  });

  it("moves a transient failure to the back and increments its attempt count", async () => {
    const retry = tombstone("retry", 2);
    const results = await reconcilePendingAccountErasures([retry.document], {
      isResumable: async () => true,
      erase: async () => {
        throw new Error("temporary outage");
      },
      now: () => now,
    });

    expect(results).toEqual([{ uid: "retry", status: "failed", errorCode: "Error" }]);
    expect(retry.patches).toEqual([
      expect.objectContaining({
        reconciliationStatus: "retry_pending",
        reconciliationAttemptCount: 3,
        updatedAt: now.toISOString(),
      }),
    ]);
  });

  it("leaves successful completion to the canonical erasure transaction", async () => {
    const success = tombstone("success");
    const erase = vi.fn(async () => undefined);
    const results = await reconcilePendingAccountErasures([success.document], {
      isResumable: async () => true,
      erase,
      now: () => now,
    });

    expect(results).toEqual([{ uid: "success", status: "completed" }]);
    expect(erase).toHaveBeenCalledWith("success");
    expect(success.patches).toEqual([]);
  });

  it("retries when canonical erasure reports incomplete cloud cleanup", async () => {
    const retry = tombstone("incomplete", 1);
    const results = await reconcilePendingAccountErasures([retry.document], {
      isResumable: async () => true,
      erase: async () => ({
        cloudDataDeleted: false,
        retryRequired: true,
      }),
      now: () => now,
    });

    expect(results).toEqual([{ uid: "incomplete", status: "failed", errorCode: "external_cleanup_incomplete" }]);
    expect(retry.patches).toEqual([
      expect.objectContaining({
        reconciliationStatus: "retry_pending",
        reconciliationErrorCode: "external_cleanup_incomplete",
        reconciliationAttemptCount: 2,
        updatedAt: now.toISOString(),
      }),
    ]);
  });

  it("drains due provider-credential erasures, most overdue first, in a bounded batch", async () => {
    firestore.queries.length = 0;
    const due = [{ id: "a" }, { id: "b" }];
    firestore.docsByCollection.set("provider_account_secret_refs", due);

    await reconcileProviderSecretErasureQueue(now);

    expect(firestore.queries).toEqual([
      {
        collection: "provider_account_secret_refs",
        where: [["erasureRetryAfter", "<=", now.toISOString()]],
        orderBy: [["erasureRetryAfter", "asc"]],
        limit: PROVIDER_SECRET_RECONCILE_BATCH_LIMIT,
      },
    ]);
    expect(reconcilePendingProviderSecretErasures).toHaveBeenCalledWith(due);
  });

  it("still drains the credential-erasure queue when the tombstone query fails, then fails the run", async () => {
    firestore.queries.length = 0;
    firestore.failingCollections.add("account_erasure_tombstones");
    await expect(reconcileAccountErasures.run({ scheduleTime: "2026-09-28T00:00:00.000Z" })).rejects.toThrow("account_erasure_tombstones query unavailable");
    expect(firestore.queries.map((query) => query.collection)).toEqual([
      "account_erasure_tombstones",
      "provider_account_secret_refs",
    ]);
    firestore.failingCollections.clear();
  });

  it("declares the oldest-first pending tombstone index", () => {
    const manifest: {
      indexes: Array<{
        collectionGroup: string;
        queryScope: string;
        fields: Array<{ fieldPath: string; order: string }>;
      }>;
    } = JSON.parse(readFileSync(resolve(process.cwd(), "../firestore.indexes.json"), "utf8"));
    expect(manifest.indexes).toContainEqual({
      collectionGroup: "account_erasure_tombstones",
      queryScope: "COLLECTION",
      fields: [
        { fieldPath: "pending", order: "ASCENDING" },
        { fieldPath: "updatedAt", order: "ASCENDING" },
      ],
    });
  });
});
