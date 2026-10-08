import { test, expect, type Page, type Response } from "@playwright/test";
import { AxeBuilder } from "@axe-core/playwright";

/**
 * Public-route smoke test. Every route at two viewports in both color
 * schemes. Fails on: console errors, failed same-origin requests, broken
 * internal links, missing title/description/OG, mobile horizontal
 * overflow, and serious/critical axe violations.
 *
 * Known-issue allowlist keys entries by the BB finding id so an allowance
 * is auditable and dies with the fix.
 */

const ROUTES = [
  "/",
  "/404",
  "/bench",
  "/bench/arena",
  "/bench/arena/vote",
  "/bench/data",
  "/bench/methodology",
  "/bench/report",
  "/benefits",
  "/beta",
  "/control",
  "/download",
  "/faq",
  "/floo",
  "/hermes/connect",
  "/legal/privacy-policy",
  "/legal/source",
  "/legal/terms",
  "/link",
  "/mcp",
  "/memory",
  "/platforms",
  "/pricing",
  "/privacy",
  "/product",
  "/providers",
  "/router",
  "/router/daily",
  "/security",
  "/subscribe",
  "/support",
  "/trust",
] as const;

/** axe rule ids allowed while a fix is tracked, keyed "route|rule". */
const AXE_ALLOWLIST: Record<string, string> = {
  // BB-33: postMessage warnings + ad-network noise come from
  // Firebase/Google-injected frames, not first-party source.
};

/** Console messages that are third-party noise rather than page defects. */
const CONSOLE_NOISE = [
  /Failed to load resource/i, // counted separately via requestFailed below
  /postMessage/i, // BB-33: Firebase/Google iframe internals, not repo code
  /\[Report Only\]/i, // CSP report-only noise
  /Deprecat/i,
  /downloadable font/i,
  /net::ERR_/i,
  /favicon/i,
];

async function collectConsoleErrors(page: Page): Promise<string[]> {
  const errors: string[] = [];
  page.on("console", (msg) => {
    if (msg.type() !== "error") return;
    const text = msg.text();
    if (CONSOLE_NOISE.some((re) => re.test(text))) return;
    errors.push(text);
  });
  page.on("pageerror", (err) => errors.push(`pageerror: ${err.message}`));
  return errors;
}

async function failedSameOriginRequests(page: Page, requestFailed: (r: Response) => void) {
  page.on("response", (response) => {
    try {
      const url = new URL(response.url());
      const base = new URL(page.context()._options.baseURL ?? "http://localhost");
      if (url.origin !== base.origin) return;
      if (response.status() >= 400) requestFailed(response);
    } catch {
      /* opaque/chrome- url */
    }
  });
}

test.describe("public routes", () => {
  for (const route of ROUTES) {
    test(`${route}`, async ({ page, baseURL }) => {
      const consoleErrors = await collectConsoleErrors(page);
      const failedResponses: string[] = [];
      const base = new URL(baseURL ?? "http://localhost:4322");

      page.on("response", (response) => {
        try {
          const url = new URL(response.url());
          if (url.origin === base.origin && response.status() >= 400) {
            failedResponses.push(`${response.status()} ${response.url()}`);
          }
        } catch {
          /* ignore */
        }
      });
      page.on("requestfailed", (request) => {
        try {
          const url = new URL(request.url());
          if (url.origin === base.origin) {
            failedResponses.push(`failed ${request.url()}`);
          }
        } catch {
          /* ignore */
        }
      });

      const response = await page.goto(route, { waitUntil: "domcontentloaded" });
      await page.waitForLoadState("networkidle", { timeout: 10_000 }).catch(() => {});

      // 404 page is expected to return 404.
      if (route === "/404") {
        expect(response?.status()).toBe(404);
      } else {
        expect(response?.status(), `${route} should return 200`).toBe(200);
      }

      // Meta sanity.
      await expect(page).toHaveTitle(/.+/);
      const description = page.locator('meta[name="description"]');
      await expect(description, `${route} missing meta description`).toHaveAttribute(
        "content",
        /.+/,
      );
      const ogTitle = page.locator('meta[property="og:title"]');
      await expect(ogTitle, `${route} missing og:title`).toHaveAttribute("content", /.+/);

      // Mobile horizontal overflow.
      const overflow = await page.evaluate(() => {
        const doc = document.documentElement;
        return doc.scrollWidth - doc.clientWidth;
      });
      expect(overflow, `${route} has ${overflow}px horizontal overflow`).toBeLessThanOrEqual(0);

      // Internal links resolve.
      const brokenLinks = await page.evaluate(async (origin) => {
        const hrefs = Array.from(document.querySelectorAll<HTMLAnchorElement>("a[href]"))
          .map((a) => a.getAttribute("href") ?? "")
          .filter((h) => h.startsWith("/") && !h.startsWith("//"));
        const unique = [...new Set(hrefs.map((h) => h.split("#")[0]).filter(Boolean))];
        const broken: string[] = [];
        for (const href of unique) {
          try {
            const res = await fetch(href, { method: "HEAD" });
            if (res.status >= 400) broken.push(`${res.status} ${href}`);
          } catch {
            broken.push(`fetch-failed ${href}`);
          }
        }
        return broken;
      }, base.origin);
      expect(brokenLinks, `${route} internal links`).toEqual([]);

      // axe: serious + critical only.
      const axe = await new AxeBuilder({ page })
        .withTags(["wcag2a", "wcag2aa", "wcag21a", "wcag21aa"])
        .analyze();
      const violations = axe.violations.filter(
        (v) =>
          (v.impact === "serious" || v.impact === "critical") &&
          !AXE_ALLOWLIST[`${route}|${v.id}`] &&
          !AXE_ALLOWLIST[`*|${v.id}`],
      );
      expect(
        violations.map((v) => `${v.id} (${v.impact}) ${v.nodes.length} nodes`),
        `${route} axe violations`,
      ).toEqual([]);

      expect(failedResponses, `${route} same-origin failures`).toEqual([]);
      expect(consoleErrors, `${route} console errors`).toEqual([]);

      await page.screenshot({ path: undefined }).catch(() => {});
    });
  }
});

/**
 * Logged-in smoke: only when staging test-account secrets exist. Never
 * creates accounts, never points at production.
 */
const stagingEmail = process.env.BURNBAR_STAGING_TEST_EMAIL;
const stagingPassword = process.env.BURNBAR_STAGING_TEST_PASSWORD;

test.describe("logged-in smoke", () => {
  test.skip(
    !stagingEmail || !stagingPassword,
    "BURNBAR_STAGING_TEST_EMAIL/PASSWORD not set — skipped",
  );

  test("sign-in surfaces render on /link", async ({ page }) => {
    await page.goto("/link", { waitUntil: "domcontentloaded" });
    await expect(page.locator("#btn-signin")).toBeVisible();
    await expect(page.locator("#btn-signin-apple")).toBeVisible();
  });
});
