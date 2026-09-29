import type { QuotaSnapshotDoc } from "./types.js";
import { logInfo } from "./logging.js";
import { QuotaRefreshPolicy } from "./quotaRefreshPolicy.js";

type QuotaSnapshotMetadataWindowKind =
  | "rollingHours"
  | "rollingDays"
  | "daily"
  | "weekly"
  | "monthly"
  | "lifetime"
  | "custom";

function quotaSnapshotAgeMsBucket(fetchedAt: string | undefined, now: Date = new Date()): string {
  if (!fetchedAt) return "unknown";
  const fetchedAtMs = Date.parse(fetchedAt);
  if (!Number.isFinite(fetchedAtMs)) return "unknown";
  const ageMs = now.getTime() - fetchedAtMs;
  if (ageMs < 0) return "future";
  if (ageMs < 60_000) return "<1m";
  if (ageMs < 5 * 60_000) return "1-5m";
  if (ageMs < 20 * 60_000) return "5-20m";
  if (ageMs < 60 * 60_000) return "20-60m";
  if (ageMs < 4 * 60 * 60_000) return "1-4h";
  return ">=4h";
}

/**
 * Fields of the `quota.snapshot_written` event, the quota-freshness SLI.
 *
 * `age_ms_bucket` is the new snapshot's fetch-to-write latency, so it is
 * almost always `<1m`. Freshness is `replaced_age_s`: how old the snapshot this
 * write replaces had grown (its `fetchedAt`, carried on the account doc as
 * `quotaSnapshotFetchedAt`), graded per `remaining_tier` because the adaptive
 * TTL deliberately refreshes accounts with ample headroom less often.
 */
export function quotaSnapshotWrittenFields(
  snapshot: QuotaSnapshotDoc,
  now: Date,
  replacedFetchedAt: unknown,
): Parameters<typeof logInfo>[0] {
  const replacedFetchedAtMs = typeof replacedFetchedAt === "string" ? Date.parse(replacedFetchedAt) : Number.NaN;
  const replacedAgeSeconds = Number.isFinite(replacedFetchedAtMs)
    ? Math.max(0, Math.round((now.getTime() - replacedFetchedAtMs) / 1000))
    : null;
  const remainingFraction = quotaAccountRefreshMetadata(snapshot, now).quotaRemainingFraction;
  return {
    event: "quota.snapshot_written",
    provider: snapshot.providerID ?? snapshot.provider,
    source: snapshot.sourceKind,
    age_ms_bucket: quotaSnapshotAgeMsBucket(snapshot.fetchedAt, now),
    replaced_age_s: replacedAgeSeconds,
    remaining_tier: QuotaRefreshPolicy.remainingTier(typeof remainingFraction === "number" ? remainingFraction : null),
  };
}

export function emitQuotaSnapshotWritten(snapshot: QuotaSnapshotDoc, now: Date, replacedFetchedAt: unknown): void {
  logInfo(quotaSnapshotWrittenFields(snapshot, now, replacedFetchedAt));
}

export function quotaAccountRefreshMetadata(snapshot: QuotaSnapshotDoc, now: Date): Record<string, unknown> {
  const buckets = Array.isArray(snapshot.buckets) ? snapshot.buckets : [];
  let remainingFraction: number | null = null;
  let windowKind: QuotaSnapshotMetadataWindowKind = "custom";
  let resetsAt: string | null = snapshot.resetAt ?? null;

  for (const bucket of buckets) {
    const limit = typeof bucket.limit === "number" && Number.isFinite(bucket.limit) ? bucket.limit : undefined;
    const remaining =
      typeof bucket.remaining === "number" && Number.isFinite(bucket.remaining) ? bucket.remaining : undefined;
    if (limit !== undefined && limit > 0 && remaining !== undefined) {
      const candidate = Math.min(Math.max(remaining / limit, 0), 1);
      remainingFraction = remainingFraction === null ? candidate : Math.min(remainingFraction, candidate);
    }
    if (!resetsAt) {
      const resetCandidate = bucket.resetAt ?? bucket.resetsAt;
      if (typeof resetCandidate === "string") {
        resetsAt = resetCandidate;
      }
    }
    if (windowKind === "custom") {
      windowKind = quotaWindowKindFromBucket(bucket.window);
    }
  }

  let quotaNextRefreshAt: string;
  try {
    quotaNextRefreshAt = QuotaRefreshPolicy.nextRefreshAfter(
      {
        fetchedAt: snapshot.fetchedAt,
        remainingFraction,
        windowKind,
        resetsAt,
      },
      now,
    ).toISOString();
  } catch {
    quotaNextRefreshAt = now.toISOString();
  }

  return {
    quotaSnapshotFetchedAt: snapshot.fetchedAt,
    quotaRemainingFraction: remainingFraction,
    quotaWindowKind: windowKind,
    quotaResetsAt: resetsAt,
    quotaNextRefreshAt,
  };
}

function quotaWindowKindFromBucket(window: unknown): QuotaSnapshotMetadataWindowKind {
  if (typeof window !== "string") return "custom";
  const normalized = window.toLowerCase().trim();
  if (normalized.includes("month")) return "monthly";
  if (normalized.includes("hour") || /^\d+(?:\.\d+)?h$/.test(normalized)) return "rollingHours";
  if (normalized.includes("day") || /^\d+(?:\.\d+)?d$/.test(normalized)) return "rollingDays";
  if (normalized.includes("week")) return "weekly";
  if (normalized.includes("life")) return "lifetime";
  return "custom";
}
