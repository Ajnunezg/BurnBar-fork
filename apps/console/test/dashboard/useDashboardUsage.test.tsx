// @vitest-environment jsdom
/**
 * A failed usage read must never masquerade as a member with no usage: the
 * rollup read failing is "unavailable" (with an error the page shows), an
 * unreadable quota read is null (not "no quotas"), and rollup cards render an
 * explicit unavailable hint instead of zeros.
 */
import { act, type ReactNode } from "react";
import { createRoot, type Root } from "react-dom/client";
import { afterEach, beforeAll, beforeEach, describe, expect, it, vi } from "vitest";

const firestore = vi.hoisted(() => ({
  getDoc: vi.fn(),
  getDocs: vi.fn(),
  // One stable auth object: a fresh `user` per render would re-run the effect forever.
  auth: { user: { uid: "member-1" }, loading: false },
}));

vi.mock("firebase/firestore", () => ({
  collection: (_db: unknown, ...segments: string[]) => ({ path: segments.join("/") }),
  doc: (_db: unknown, ...segments: string[]) => ({ path: segments.join("/") }),
  getDoc: firestore.getDoc,
  getDocs: firestore.getDocs,
}));
vi.mock("@/lib/firebaseClient", () => ({ db: () => ({}) }));
vi.mock("@/lib/useAuth", () => ({ useAuth: () => firestore.auth }));
vi.mock("@/lib/api", () => ({ rebuildUsageRollups: vi.fn(async () => undefined) }));

import {
  DASHBOARD_USAGE_UNAVAILABLE_MESSAGE,
  useDashboardUsage,
  type DashboardData,
  type DashboardUsageResult,
} from "../../lib/dashboard/useDashboardUsage";
import { CARD_DEF_BY_ID } from "../../components/dashboard/cardRegistry";
import { CardBody } from "../../components/dashboard/GlassGrid";
import { emptyRollup } from "../../lib/usage";

beforeAll(() => {
  (globalThis as { IS_REACT_ACT_ENVIRONMENT?: boolean }).IS_REACT_ACT_ENVIRONMENT = true;
});

const permissionDenied = Object.assign(new Error("Missing or insufficient permissions."), {
  code: "permission-denied",
});

function snapshot(data: Record<string, unknown> | null) {
  return { exists: () => data !== null, data: () => data ?? undefined };
}

let container: HTMLDivElement | null = null;
let root: Root | null = null;
let latest: DashboardUsageResult | null = null;

function Probe() {
  latest = useDashboardUsage("30d");
  return null;
}

async function loadDashboard(): Promise<DashboardUsageResult> {
  container = document.createElement("div");
  document.body.appendChild(container);
  root = createRoot(container);
  const r = root;
  await act(async () => {
    r.render(<Probe />);
  });
  // Let the three reads settle and the resulting state commit.
  await act(async () => {
    await new Promise((resolve) => setTimeout(resolve, 0));
  });
  if (!latest) throw new Error("hook never rendered");
  expect(latest.loading).toBe(false);
  return latest;
}

function render(node: ReactNode): HTMLDivElement {
  container = document.createElement("div");
  document.body.appendChild(container);
  root = createRoot(container);
  const r = root;
  act(() => r.render(node));
  return container;
}

beforeEach(() => {
  latest = null;
  firestore.getDoc.mockImplementation(async (ref: { path: string }) =>
    ref.path.includes("usage_rollups") ? snapshot({ totals: { tokens: 1200, requests: 3, costUsd: 4.5 }, computedAt: "2026-09-28T00:00:00.000Z" }) : snapshot(null),
  );
  firestore.getDocs.mockResolvedValue({ docs: [] });
});

afterEach(() => {
  if (root && container) {
    const r = root;
    act(() => r.unmount());
    container.remove();
  }
  container = null;
  root = null;
  vi.clearAllMocks();
});

describe("useDashboardUsage failure states", () => {
  it("reports a failed rollup read as unavailable with an error, never as an empty account", async () => {
    firestore.getDoc.mockImplementation(async (ref: { path: string }) => {
      if (ref.path.includes("usage_rollups")) throw permissionDenied;
      return snapshot(null);
    });

    const result = await loadDashboard();

    expect(result.data.source).toBe("unavailable");
    expect(result.error).toBe(DASHBOARD_USAGE_UNAVAILABLE_MESSAGE);
  });

  it("keeps the never-synced state distinct from a failure", async () => {
    firestore.getDoc.mockImplementation(async () => snapshot(null));

    const result = await loadDashboard();

    expect(result.data.source).toBe("empty");
    expect(result.error).toBeNull();
  });

  it("serves a readable rollup as live usage", async () => {
    const result = await loadDashboard();

    expect(result.data.source).toBe("live");
    expect(result.data.rollup.totals.tokens).toBe(1200);
    expect(result.error).toBeNull();
  });

  it("reports unreadable quota snapshots as null, not as an empty list", async () => {
    firestore.getDocs.mockRejectedValue(permissionDenied);

    const result = await loadDashboard();

    expect(result.data.quotas).toBeNull();
    // The quota failure alone does not blank the usage the member can see.
    expect(result.data.source).toBe("live");
  });
});

describe("dashboard cards under a failed read", () => {
  const unavailable: DashboardData = {
    rollup: emptyRollup("30d"),
    quotas: null,
    fusion: null,
    source: "unavailable",
    computedAt: null,
  };

  it("renders rollup cards as unavailable instead of zeros", () => {
    const view = render(<CardBody def={CARD_DEF_BY_ID.burn} data={unavailable} />);

    expect(view.textContent).toContain("Usage unavailable");
    expect(view.textContent).not.toMatch(/\$0/);
  });

  it("renders unreadable provider limits as unavailable, not as none synced", () => {
    const view = render(<CardBody def={CARD_DEF_BY_ID.limits} data={unavailable} />);

    expect(view.textContent).toContain("Provider limits unavailable.");
    expect(view.textContent).not.toContain("No provider quotas synced.");
  });

  it("declares a data source for every card", () => {
    for (const def of Object.values(CARD_DEF_BY_ID)) {
      expect(["rollup", "quotas", "fusion"]).toContain(def.dataSource);
    }
  });
});
