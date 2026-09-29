"use client";

import { useCallback, useEffect, useState } from "react";
import { collection, doc, getDoc, getDocs } from "firebase/firestore";

import { db } from "@/lib/firebaseClient";
import { useAuth } from "@/lib/useAuth";
import { rebuildUsageRollups } from "@/lib/api";
import {
  currentMonthKey,
  emptyRollup,
  normalizeAllowance,
  normalizeQuotaSnapshot,
  normalizeRollup,
  type FusionAllowance,
  type QuotaSnapshot,
  type UsageRollup,
  type UsageWindowKey,
} from "@/lib/usage";

export type DashboardSource = "live" | "empty" | "unavailable";

export interface DashboardData {
  rollup: UsageRollup;
  /** Null when the quota snapshots are unreadable (denied / offline); never an empty list. */
  quotas: QuotaSnapshot[] | null;
  /** Null when the fusion allowance is unreadable (rule not deployed / denied). */
  fusion: FusionAllowance | null;
  /**
   * "live" when a rollup doc exists; "empty" when the member has never synced;
   * "unavailable" when the rollup read FAILED — its zeroed rollup is a
   * placeholder that must never render as real usage.
   */
  source: DashboardSource;
  computedAt: string | null;
}

/** Shown when the primary rollup read fails, so a failure never reads as zero usage. */
export const DASHBOARD_USAGE_UNAVAILABLE_MESSAGE =
  "Couldn't load your usage right now. These numbers are unavailable, not zero. Refresh to try again.";

export interface DashboardUsageResult {
  data: DashboardData;
  loading: boolean;
  error: string | null;
  /** Re-read; pass true to force a server recompute (rebuildUsageRollups) first. */
  reload: (rebuild?: boolean) => void;
}

function emptyData(window: UsageWindowKey): DashboardData {
  return {
    rollup: emptyRollup(window),
    quotas: [],
    fusion: null,
    source: "empty",
    computedAt: null,
  };
}

/**
 * Reads the member's real usage from Firestore (project `burnbar`):
 *   - users/{uid}/usage_rollups/{window}        → totals + breakdowns + daily series
 *   - users/{uid}/quota_snapshots/*             → provider limits
 *   - users/{uid}/billing/allowances/months/{m} → fusion ("The Wand") meter
 *
 * Each source is read independently: a denied quota or allowance read never
 * blanks the usage cards, and a member who has never synced renders a real
 * zeroed "empty" state — never mock data. A FAILED read is never folded into
 * "empty": the rollup becomes `source: "unavailable"` with an error, and
 * unreadable quotas become `null`, so the UI can say "unavailable" instead of
 * presenting a failure as zero usage.
 */
export function useDashboardUsage(window: UsageWindowKey = "30d"): DashboardUsageResult {
  const { user, loading: authLoading } = useAuth();
  const [data, setData] = useState<DashboardData>(() => emptyData(window));
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  // nonce bumps re-read; rebuildNonce additionally forces a server recompute.
  const [nonce, setNonce] = useState(0);
  const [rebuildPending, setRebuildPending] = useState(false);

  const reload = useCallback((rebuild = false) => {
    if (rebuild) setRebuildPending(true);
    setNonce((n) => n + 1);
  }, []);

  useEffect(() => {
    if (authLoading) return;
    if (!user) {
      setData(emptyData(window));
      setLoading(false);
      return;
    }
    const uid = user.uid;
    let cancelled = false;
    setLoading(true);
    setError(null);

    // Consume the rebuild intent immediately so it's a one-shot: a run that gets
    // cancelled (e.g. the window changes mid-flight) can't leave the flag set for
    // the next run to fire an unrequested recompute. (rebuildPending is not a
    // dep, so clearing it here does not re-trigger the effect.)
    const shouldRebuild = rebuildPending;
    if (shouldRebuild) setRebuildPending(false);

    const run = async () => {
      if (shouldRebuild) {
        try {
          await rebuildUsageRollups(true);
        } catch {
          // Recompute is best-effort; fall through to read whatever exists.
        }
      }

      const rollupP = getDoc(doc(db(), "users", uid, "usage_rollups", window))
        .then((snap) =>
          snap.exists()
            ? { rollup: normalizeRollup(snap.data(), window), source: "live" as const }
            : { rollup: emptyRollup(window), source: "empty" as const },
        )
        // A denied/offline read is NOT a member with no usage.
        .catch(() => ({ rollup: emptyRollup(window), source: "unavailable" as const }));

      const quotasP = getDocs(collection(db(), "users", uid, "quota_snapshots"))
        .then((qs) =>
          qs.docs
            .map((d) => normalizeQuotaSnapshot(d.data()))
            .filter((q): q is QuotaSnapshot => q !== null),
        )
        .catch(() => null);

      const monthKey = currentMonthKey(new Date());
      const fusionP = getDoc(
        doc(db(), "users", uid, "billing", "allowances", "months", monthKey),
      )
        .then((snap) =>
          snap.exists()
            ? normalizeAllowance(snap.data(), monthKey)
            : normalizeAllowance({}, monthKey),
        )
        .catch(() => null);

      const [r, quotas, fusion] = await Promise.all([rollupP, quotasP, fusionP]);
      if (cancelled) return;
      setData({
        rollup: r.rollup,
        quotas,
        fusion,
        source: r.source,
        computedAt: r.rollup.computedAt,
      });
      if (r.source === "unavailable") setError(DASHBOARD_USAGE_UNAVAILABLE_MESSAGE);
    };

    run()
      .catch((err: unknown) => {
        if (!cancelled)
          setError(err instanceof Error ? err.message : "Could not load your usage.");
      })
      .finally(() => {
        if (!cancelled) setLoading(false);
      });

    return () => {
      cancelled = true;
    };
    // rebuildPending is intentionally not a dep: reload() sets it then bumps
    // nonce, so nonce already gates the re-run; adding it would double-fire.
  }, [user, authLoading, window, nonce]);

  return { data, loading, error, reload };
}
