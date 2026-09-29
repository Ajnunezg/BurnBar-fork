import { describe, expect, it } from "vitest";

import {
  quotaAccountRefreshMetadata,
  quotaSnapshotWrittenFields,
} from "../../../packages/functions-shared/src/quotaSnapshotMetadata.js";
import type { QuotaSnapshotDoc } from "../../../packages/functions-shared/src/types.js";

function snapshot(window: string): QuotaSnapshotDoc {
  return {
    sourceKind: "provider",
    sourceId: "default",
    provider: "claude-code",
    fetchedAt: "2026-07-08T00:00:00.000Z",
    source: "default",
    confidence: "high",
    buckets: [{ name: "tokens", window, limit: 100, remaining: 90 }],
    schemaVersion: 1,
    updatedAt: "2026-07-08T00:00:00.000Z",
  };
}

describe("quotaAccountRefreshMetadata", () => {
  it("classifies monthly windows before suffix shorthand checks", () => {
    const metadata = quotaAccountRefreshMetadata(
      snapshot("month"),
      new Date("2026-07-08T00:00:00.000Z"),
    );

    expect(metadata.quotaWindowKind).toBe("monthly");
  });

  it("keeps explicit hour and day shorthands as rolling windows", () => {
    const hourly = quotaAccountRefreshMetadata(
      snapshot("5h"),
      new Date("2026-07-08T00:00:00.000Z"),
    );
    const daily = quotaAccountRefreshMetadata(
      snapshot("7d"),
      new Date("2026-07-08T00:00:00.000Z"),
    );

    expect(hourly.quotaWindowKind).toBe("rollingHours");
    expect(daily.quotaWindowKind).toBe("rollingDays");
  });
});

describe("quotaSnapshotWrittenFields", () => {
  const writtenAt = new Date("2026-07-08T00:00:30.000Z");

  it("reports how old the replaced snapshot had grown, graded by the headroom tier", () => {
    const fields = quotaSnapshotWrittenFields(snapshot("month"), writtenAt, "2026-07-07T23:30:30.000Z");

    expect(fields.event).toBe("quota.snapshot_written");
    // The new snapshot's own age is fetch-to-write latency, not freshness.
    expect(fields.age_ms_bucket).toBe("<1m");
    expect(fields.replaced_age_s).toBe(30 * 60);
    expect(fields.remaining_tier).toBe("high");
  });

  it("reports no replaced age for a first snapshot or an unparseable prior fetch", () => {
    expect(quotaSnapshotWrittenFields(snapshot("month"), writtenAt, undefined).replaced_age_s).toBeNull();
    expect(quotaSnapshotWrittenFields(snapshot("month"), writtenAt, "not-a-date").replaced_age_s).toBeNull();
  });

  it("grades low and unknown headroom separately", () => {
    const low = { ...snapshot("month"), buckets: [{ name: "tokens", window: "month", limit: 100, remaining: 5 }] };
    const unknown = { ...snapshot("month"), buckets: [] };

    expect(quotaSnapshotWrittenFields(low, writtenAt, undefined).remaining_tier).toBe("low");
    expect(quotaSnapshotWrittenFields(unknown, writtenAt, undefined).remaining_tier).toBe("unknown");
  });
});
