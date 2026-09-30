/**
 * Stateful Secret Manager + Cloud KMS double with real version semantics, in
 * the exact googleapis shape `packages/functions-shared/src/secrets.ts` calls.
 *
 * Versions are numbered from 1 per secret, `versions.list` returns newest
 * first and paginates, `destroy` wipes the payload and refuses a second
 * destroy the way the real API does, and faults are injectable per version.
 * KMS "encrypts" by passing the DEK through, so `storeCredential` and
 * `retrieveCredential` still exercise the real AES-256-GCM envelope.
 */

type FakeVersionState = "ENABLED" | "DISABLED" | "DESTROYED";

interface FakeVersion {
  id: number;
  state: FakeVersionState;
  payload?: string;
}

function apiError(code: number, status: string, message: string): Error {
  return Object.assign(new Error(message), { code, response: { status: code, data: { error: { status, message } } } });
}

class FakeSecretManager {
  private readonly secrets = new Map<string, FakeVersion[]>();
  /** Version names whose `destroy` fails with a transient UNAVAILABLE until cleared. */
  readonly failingDestroys = new Set<string>();
  /** When set, `versions.list` fails with this error. */
  listFailure: Error | undefined;
  /** Server-side page cap (the real API caps at 25,000). */
  maxPageSize = 25_000;
  readonly destroyCalls: string[] = [];

  reset(): void {
    this.secrets.clear();
    this.failingDestroys.clear();
    this.listFailure = undefined;
    this.maxPageSize = 25_000;
    this.destroyCalls.length = 0;
  }

  /** State of every version of `secretName`, keyed by version number. */
  versionStates(secretName: string): Record<number, FakeVersionState> {
    return Object.fromEntries((this.secrets.get(secretName) ?? []).map((version) => [version.id, version.state]));
  }

  /** True while the named version still holds a payload. */
  readable(versionName: string): boolean {
    const version = this.lookup(versionName);
    return version !== undefined && version.state !== "DESTROYED" && version.payload !== undefined;
  }

  private lookup(versionName: string): FakeVersion | undefined {
    const match = /^(.*)\/versions\/(\d+)$/u.exec(versionName);
    if (!match) return undefined;
    return this.secrets.get(match[1])?.find((version) => version.id === Number(match[2]));
  }

  readonly projects = {
    secrets: {
      get: async ({ name }: { name: string }) => {
        if (!this.secrets.has(name)) throw apiError(404, "NOT_FOUND", "Secret not found.");
        return { data: { name } };
      },
      create: async ({ parent, secretId }: { parent: string; secretId: string }) => {
        const name = `${parent}/secrets/${secretId}`;
        if (this.secrets.has(name)) throw apiError(409, "ALREADY_EXISTS", "Secret already exists.");
        this.secrets.set(name, []);
        return { data: { name } };
      },
      addVersion: async ({ parent, requestBody }: { parent: string; requestBody: { payload: { data: string } } }) => {
        const versions = this.secrets.get(parent);
        if (!versions) throw apiError(404, "NOT_FOUND", "Secret not found.");
        const id = versions.length + 1;
        versions.push({ id, state: "ENABLED", payload: requestBody.payload.data });
        return { data: { name: `${parent}/versions/${id}` } };
      },
      versions: {
        list: async ({ parent, pageSize, pageToken }: { parent: string; pageSize?: number; pageToken?: string }) => {
          if (this.listFailure) throw this.listFailure;
          const versions = this.secrets.get(parent);
          if (!versions) throw apiError(404, "NOT_FOUND", "Secret not found.");
          const newestFirst = [...versions].reverse();
          const size = Math.min(pageSize ?? this.maxPageSize, this.maxPageSize);
          const offset = pageToken ? Number(pageToken) : 0;
          const page = newestFirst.slice(offset, offset + size);
          const next = offset + size < newestFirst.length ? String(offset + size) : undefined;
          return {
            data: {
              versions: page.map((version) => ({ name: `${parent}/versions/${version.id}`, state: version.state })),
              ...(next ? { nextPageToken: next } : {}),
            },
          };
        },
        destroy: async ({ name }: { name: string }) => {
          this.destroyCalls.push(name);
          const version = this.lookup(name);
          if (!version) throw apiError(404, "NOT_FOUND", "Secret version not found.");
          if (this.failingDestroys.has(name)) throw apiError(503, "UNAVAILABLE", "The service is currently unavailable.");
          if (version.state === "DESTROYED") {
            throw apiError(400, "FAILED_PRECONDITION", `Secret Version ${name} has been destroyed.`);
          }
          version.state = "DESTROYED";
          version.payload = undefined;
          return { data: { name, state: "DESTROYED" } };
        },
        access: async ({ name }: { name: string }) => {
          const version = this.lookup(name);
          if (!version || version.state !== "ENABLED" || version.payload === undefined) {
            throw apiError(400, "FAILED_PRECONDITION", "Secret version is not enabled.");
          }
          return { data: { name, payload: { data: version.payload } } };
        },
      },
    },
  };

  readonly kms = {
    projects: {
      locations: {
        keyRings: {
          cryptoKeys: {
            encrypt: async ({ requestBody }: { requestBody: { plaintext: string } }) => ({
              data: { ciphertext: requestBody.plaintext },
            }),
            decrypt: async ({ requestBody }: { requestBody: { ciphertext: string } }) => ({
              data: { plaintext: requestBody.ciphertext },
            }),
          },
        },
      },
    },
  };
}

/** One instance per test file: `vi.mock("googleapis")` factories and assertions share it. */
export const fakeSecretManager = new FakeSecretManager();
