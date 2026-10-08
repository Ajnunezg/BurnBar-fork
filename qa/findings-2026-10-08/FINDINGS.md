# BurnBar web smoke test: findings

**Date:** 2026-10-08 (testing ran about 11:58 to 13:40 CT)
**Author:** Grok Bot (automated headless crawl plus manual screenshot review)
**Audience:** coding agent (Devin) fixing these issues. Every finding has evidence: a screenshot in `screenshots/` or a captured log in `logs/`.

---

## 1. Environment and URLs tested

| Surface | URL | What's deployed (HTTP `Last-Modified`) | Notes |
|---|---|---|---|
| Staging marketing (primary) | https://burnbar-staging.web.app (and `burnbar-staging.firebaseapp.com`, same bytes) | **Sat 2026-08-08 17:49 CT** | Firebase project `burnbar-staging`, Hosting target `marketing`. Older than prod. See BB-03. |
| Production marketing | https://burnbar.ai (and `www.burnbar.ai`) | **Sat 2026-09-19 22:25 CT** | Behind Cloudflare. Public pages only. I did not sign in, submit anything, or click consent. |
| Staging console | https://burnbar-staging-console.web.app | **Not deployed.** Firebase "Site Not Found" (404) | The real hostname per `.firebaserc` (`targets.burnbar-staging.hosting.console = ["burnbar-staging-console"]`). `burnbar-staging-console.firebaseapp.com` is also 404. See BB-12. |
| Prod console (reference only) | https://app.burnbar.ai, https://burnbar-console.web.app | 200 | HTTP status check only. Not crawled, not signed in (out of scope: production plus login). |
| Repo | `Imagine-That-Ai/BurnBar` @ `main` = `2f37655` (2026-10-02 04:44 CT) | | Tree listed with the GitHub connector (`cursor-github`). A public sparse clone was used to grep `website/`, `apps/console/`, `docs/ops/`, `firebase.json`, `.firebaserc`. |

**Important context.** Neither deployment matches `main`. Staging is about 6 weeks behind prod, and prod is about 2 weeks behind `main`. Each finding says where it reproduces and whether the bug is still in `main` source.

## 2. Viewports, themes, tooling

- Headless Chromium 153 (Playwright 1.63, Python), own instance under `/workspace`. I did not use the desktop browser.
- Viewports: **desktop 1440×900** and **mobile 390×844** (iPhone UA, `isMobile`, touch).
- Themes: `prefers-color-scheme: light` and `dark`. The site picks the theme from this when there is no `localStorage['burnbar-theme']`, and every context was fresh.
- Per page and per config I collected: full-page PNG, console errors and warnings, page errors, failed requests, HTTP ≥400 responses, title/meta/OG/canonical/robots, broken images, unnamed controls, horizontal overflow (`scrollWidth > innerWidth` plus offending elements), font-size inventory, tap targets, and axe-core 4.x (WCAG 2 A/AA) for desktop-light, desktop-dark and mobile-light.
- Link check: all 143 unique absolute links found on desktop-light pages, using curl GET with redirects followed.
- Then I **looked at the screenshots** (tiles plus targeted viewport captures) and judged them visually.

**Capture caveats (not product bugs):**
1. Chromium can't render a full-page capture taller than about 16,384 px. On pages taller than that (home on desktop and mobile, `/memory`, `/bench`, `/bench/data`, most mobile pages), everything below 16,384 px is blank in `screenshots/fullpage/`. Those files are cropped to the valid region.
2. `/control` and `/floo` vignettes only paint while they are in the viewport, so they look empty in full-page shots. Findings use targeted viewport captures (`BB*.png`) instead.
3. The box was shared with other heavy jobs (load average up to about 90). One capture timed out and was retried, and timing data is noisy. No performance findings are claimed.

## 3. Coverage

Each URL below was captured in **4 configs** (desktop-light, desktop-dark, mobile-light, mobile-dark): 248 page-captures total. Full-page PNGs were captured for all of them; only the ones referenced in findings are committed (see §8).

**Staging (29 URLs):** `/`, `/beta` (404), `/control`, `/link`, `/hermes/connect`, `/floo`, `/mcp`, `/subscribe`, `/router`, `/router/daily`, `/router/daily/2026-07-12` (latest), `/bench`, `/bench/arena`, `/bench/report`, `/benefits`, `/download`, `/faq`, `/legal/privacy-policy`, `/legal/source`, `/legal/terms`, `/platforms`, `/pricing`, `/privacy`, `/product`, `/providers`, `/security`, `/support`, `/trust`, `/this-page-does-not-exist-qa` (404 template).
- These routes exist in `main` but return **404 on staging**: `/bench/arena/vote`, `/bench/data`, `/bench/methodology`, `/memory`, `/beta`.
- The other 12 dated `/router/daily/*` pages were HTTP-checked (all 200) but not screenshotted.

**Prod (33 URLs):** all of the staging list plus `/bench/arena/vote`, `/bench/data`, `/bench/methodology`, `/memory`. The latest daily page is `/router/daily/2026-08-19`. `/beta` is 404 on prod too. The other 13 dated daily pages were HTTP-checked (all 200).

**Console:** `burnbar-staging-console.web.app` is not deployed, so there was nothing to crawl. The console routes in source (`apps/console/app/`: `/`, `/dashboard`, `/escrow`, `/experimental`, `/inventory`, `/pensieve`, `/profile`, `/settings`) could not be exercised anywhere without a login. Probing them on staging marketing (`/console`, `/dashboard`) returns the marketing 404.

**Mobile horizontal overflow:** none found on any page, in either environment or either theme.

---

## 4. Executive Top 5 (fix first)

1. **BB-01 (P0): Staging ships the production Firebase config.** `projectId: burnbar`, the prod apiKey and the prod reCAPTCHA key are in staging's `firebaseClient` bundle. Staging auth pages talk to prod Auth, which rejects the domain. Evidence: `logs/BB01_staging-uses-prod-firebase.txt`
2. **BB-02 (P0): `/beta` (Free Ultra beta claim) is 404 on prod and staging.** The route is in `main` and in the CHANGELOG, but it was never deployed. Any launch code sent to `burnbar.ai/beta?code=…` lands on "This page went up in smoke." Evidence: `screenshots/BB02_prod_beta-404_desktop-light.png`
3. **BB-04 (P0): The hero product mockup is unreadable in light mode,** and light mode is the default for most visitors. It is dark-on-dark text in the first thing people see on burnbar.ai. Evidence: `screenshots/BB04_prod_home-hero-mockup-zoom_desktop-light.png`
4. **BB-03 (P0): Staging is stale and not a valid pre-prod.** It was deployed 2026-08-08: 4 routes 404, the router-rundown function 404s ("LIVE FEED UNAVAILABLE"), and the Arena CTA points to a personal Tailscale host. Evidence: `screenshots/BB03_staging_bench-arena-tailscale-link_desktop-light.png`
5. **BB-05 (P1): The home "Reaches from the menu bar…" cards render as raw unstyled text.** The `companion__*` CSS doesn't exist anywhere in `main`. Evidence: `screenshots/BB05_prod_home-companion-cards-unstyled_desktop-light.png`

**Finding counts:** P0 = 4, P1 = 8, P2 = 11, P3 = 11 (**34 total**).

---

## 5. Findings

### P0: must fix

#### BB-01: Staging marketing site is wired to the PRODUCTION Firebase project
- **Severity:** P0 (environment isolation and security; also blocks all staging auth testing)
- **Where:** staging. `https://burnbar-staging.web.app/link`, `/hermes/connect`, `/subscribe` (every page that imports `firebaseClient`)
- **Viewport/theme:** all. The Auth warning was logged on mobile-light and mobile-dark.
- **Repro:**
  1. `curl -s https://burnbar-staging.web.app/link`, then find the `link.astro…js` chunk and its import `/_assets/firebaseClient.DDb0EQIj.js`.
  2. The bundle contains `{apiKey:"AIzaSyBiAIHwf1MKZ6LN5HrsaPYsAR3UTe8hyw4", authDomain:"burnbar.firebaseapp.com", projectId:"burnbar", appId:"1:246956661961:web:…"}` and reCAPTCHA key `6Ld3bAktAAAAAABiZujpMLmUcvSMUPiJk6qENbOg`. These are byte-identical to prod.
  3. Load `/link` on mobile. The console shows `Info: The current domain is not authorized for OAuth operations… Add your domain (burnbar-staging.web.app)…` from `https://burnbar.firebaseapp.com/__/auth/iframe.js`.
- **Expected:** `docs/ops/STAGING.md` says staging marketing Hosting "is deployed with staging-only Firebase/Auth/App Check identifiers", and `website/scripts/build-staging.mjs` asserts no production identifiers appear in `dist/`.
- **Actual:** the deployed staging artifact uses the prod project. Sign-in on staging is broken (domain not authorized), and if it were authorized it would create and modify production users, entitlements and Stripe sessions.
- **Evidence:** `logs/BB01_staging-uses-prod-firebase.txt`, `logs/console_network_errors.md` (staging section), `screenshots/fullpage/staging_link_mobile-light.png`
- **Suspected source:** the deploy that produced the 2026-08-08 artifact bypassed `npm --prefix website run build:staging` (`website/scripts/build-staging.mjs`, `website/scripts/staging-firebase-public-config.mjs`). Also check `website/src/lib/firebaseClient.ts` (`website.*` fallback defaults to prod when `PUBLIC_FIREBASE_*` env is missing) and `.github/workflows/deploy-staging.yml`.
- **Fix:**
  1. Redeploy staging only through the `deploy-staging.yml` candidate lane, using `build-staging.mjs`.
  2. Make `firebaseClient.ts` fail the build, not silently fall back to prod, when `PUBLIC_FIREBASE_PROJECT_ID` is unset for a staging build.
  3. Add a post-deploy probe to `verify-staging-deployment.mjs` that greps the live `/_assets/firebaseClient.*.js` for `projectId:"burnbar"`.

#### BB-02: `/beta` (Free Ultra beta claim) returns 404 on prod and staging
- **Severity:** P0 (a launch funnel that dead-ends)
- **Where:** prod `https://burnbar.ai/beta` and staging `https://burnbar-staging.web.app/beta`
- **Viewport/theme:** all 4
- **Repro:** open `/beta` or `/beta?code=TEST`. You get the 404 template ("This page went up in smoke.").
- **Expected:** the claim page with Google/Apple sign-in and code entry (`website/src/pages/beta.astro`). CHANGELOG `[Unreleased]` says visitors redeem codes "at <https://burnbar.ai/beta> (or one-click via `/beta?code=…`)". `firebase.json` already has a `/beta` CSP header block.
- **Actual:** 404 in both environments. The page was added to `main` on 2026-09-28 (commit `99c2049`, "wave 2 … beta+analytics"), after both deploys. I could not test the beta flow at all (it's the primary app-like staging target).
- **Evidence:** `screenshots/BB02_prod_beta-404_desktop-light.png`, `screenshots/BB02_staging_beta-404_mobile-dark.png`
- **Source:** `website/src/pages/beta.astro`, `website/scripts/test-beta-claim.mjs`, `firebase.json` (`/beta` header block), deploy pipeline
- **Fix:** deploy `main` to staging (after BB-01 is fixed), smoke-test `/beta` signed out and signed in with a staging test account, then ship to prod **before** any codes go out. Add `/beta` to `website/scripts/verify-staging-deployment.mjs` route probes.

#### BB-03: Staging is stale (deployed 2026-08-08) and diverges from prod and `main`
- **Severity:** P0 (staging can't be used to validate anything that ships)
- **Where:** staging, site-wide
- **Viewport/theme:** all
- **Repro / evidence (each item captured):**
  - `Last-Modified: Sat, 08 Aug 2026 22:49:23 GMT` on staging, versus prod `Sun, 20 Sep 2026 03:25:29 GMT` (`logs/BB03_BB12_BB22_headers-and-routes.txt`).
  - **404 on staging, 200 on prod:** `/bench/arena/vote` (`screenshots/BB03_staging_bench-arena-vote-404_desktop-light.png`), `/bench/data`, `/bench/methodology`, `/memory`.
  - **`/api/router-rundown/latest` → 404** (the `latestRouterRundown` function is not deployed to staging). It fires on `/`, `/router`, `/platforms`, `/product`, `/router/daily/*` in all configs, and the daily page shows a user-visible "LIVE FEED UNAVAILABLE · SHOWING BUILD-TIME FALLBACK" pill (`screenshots/BB03_staging_router-daily-live-feed-unavailable_desktop-light.png`).
  - **Private infrastructure leak:** the staging `/bench/arena` "Open the voting console" CTA links to `https://tikkas-mac-mini.tail602e93.ts.net:8443/arena`, a personal Tailscale machine that is unreachable for the public (`screenshots/BB03_staging_bench-arena-tailscale-link_desktop-light.png`). This is already gone from `main`.
  - **Staging-only visual bug (fixed on prod):** on `/product` (light), the feature cards are dark brown with dark text (axe contrast 2.14:1; `.feat.glass-pane` fg `#16140f` on `#4c4c4d`). Compare `screenshots/BB03_staging_product-cards-unreadable_desktop-light.png` with `screenshots/BB03_prod_product-cards-same-section_desktop-light.png`.
  - **Unintended staging/prod differences:** old flat nav (Product · Router · Bench · Floo · Agent Control · Platforms · Providers · Pricing · Trust · Download · FAQ) versus prod's dropdown nav; hero "Watch your AI agents." (`V1.0.29`) versus prod "Watch your agents." (`1.0.40+repair.41`); `gpt-5.4/5.5` versus `gpt-5.6` model copy; staging axe colour-contrast counts are 10 to 1,500 per page versus ~0 on prod.
- **Expected:** staging runs `main` (or the release candidate) ahead of prod.
- **Source:** `.github/workflows/deploy-staging.yml`, `website/scripts/build-staging.mjs`, `website/scripts/verify-staging-deployment.mjs`, `functions/staging-deploy-targets.json` (add `latestRouterRundown`, or stub the rewrite on staging).
- **Fix:** re-run the staging candidate lane from `main` (Hosting plus the function targets behind the `firebase.json` rewrites: `latestRouterRundown`, `startCliLink`, `pollCliLink`, `benchAssistant`, `burnBarHermesGateway`). Add a freshness check that fails if staging `Last-Modified` is older than prod.

#### BB-04: Light mode: dark-only components render dark-on-dark (worst case: the home hero mockup)
- **Severity:** P0 (first impression on burnbar.ai looks broken)
- **Where:** prod and staging `/` hero (worst). Same class of bug: prod `/platforms` "Surface registry" section, and the hero mockup's "Settings" button on mobile.
- **Viewport/theme:** desktop-light and mobile-light. Dark theme is fine (reference: `screenshots/BB04_prod_home-hero-mockup-reference_desktop-dark.png`).
- **Repro:** open https://burnbar.ai/ in a light-scheme browser. Look at the menu-bar popover mockup on the right.
- **Expected:** a legible product preview, like the dark-theme render.
- **Actual:** the card backgrounds are hard-coded dark (`#1a1822`, `#1f1b2a`, …) while text uses theme tokens (`var(--text-bright)`, `--text-base`, `--text-mute`) that flip to near-black in light mode. "OpenBurnBar", "Anthropic", "Codex", "Claude Code", all percentages and the "Settings" button are effectively invisible. On `/platforms` (light), the "Surface registry / Declare the physical schema" block becomes a muddy `#444` band with gray cards and unreadable code, full-bleed to both viewport edges.
- **Evidence:** `screenshots/BB04_prod_home-hero-mockup-unreadable_desktop-light.png`, `screenshots/BB04_prod_home-hero-mockup-zoom_desktop-light.png` (2×), `screenshots/BB04_prod_platforms-registry-muddy_desktop-light.png`, `screenshots/BB25_prod_home-duplicate-mockup-captions_mobile-light.png` (dark "Settings" label)
- **Source:** `website/src/components/BarMockup.astro` (lines ~213–536: hard-coded backgrounds plus token colours), `website/src/pages/platforms/index.astro` (registry / "Registry Config Paths" section has no `[data-theme="light"]` overrides)
- **Fix:** pin the mockup to a fixed dark palette, either with a scoped `data-theme="dark"` wrapper or by redefining `--text-*` inside `.bar-mockup`. Alternatively, give it a real light variant. Do the same for the platforms registry section. Add a light-theme visual regression test for the hero.

### P1

#### BB-05: Home "Reaches from the menu bar to your phone and agents." cards are completely unstyled
- **Severity:** P1
- **Where:** prod `https://burnbar.ai/` (staging has an older variant with the same bug: "It doesn't just watch. It reaches.")
- **Viewport/theme:** all (worst on desktop-light)
- **Repro:** scroll the home page to "Beyond the dashboard".
- **Expected:** a two-card grid (Floo / Agent Control) with glass cards, tag chips and "Explore →" links.
- **Actual:** raw stacked text with no card, no grid and no spacing. The Agent Control tag ("Direct download · behind your grant") floats inline next to "Explore Floo →", and body copy runs about 900 px wide.
- **Evidence:** `screenshots/BB05_prod_home-companion-cards-unstyled_desktop-light.png`, `screenshots/BB05_prod_home-companion-cards-unstyled_mobile-light.png`
- **Source:** `website/src/pages/index.astro` lines ~590–630 use `.companion__grid`, `.companion__card`, `.companion__tag`, `.companion__more`. **None of these classes has any CSS in `main`** (grep finds markup only).
- **Fix:** add the missing styles (two-column grid → one column under ~760 px, card padding, tag margin, "more" link row), or reuse the existing `SurfaceCard` / `glass-pane` card pattern.

#### BB-06: Arena voting: CSP blocks the Firebase Auth iframe on `/bench/arena/vote`
- **Severity:** P1 (sign-in or anonymous auth for voting is likely broken on mobile; I couldn't verify end to end without logging in)
- **Where:** prod `https://burnbar.ai/bench/arena/vote`
- **Viewport/theme:** mobile-light and mobile-dark (2 of 2 mobile runs; not seen on desktop runs)
- **Repro:** open the vote page on a 390×844 mobile emulation and watch the console.
- **Actual (log):** `Framing 'https://burnbar.ai/__/auth/iframe?apiKey=…&appName=arena-public…' violates the following Content Security Policy directive: "frame-src https://burnbar-arena-artifacts.web.app https://burnbar-arena-artifacts.firebaseapp.com https://*.firebaseapp.com https://accounts.google.com https://appleid.apple.com https://www.google.com/recaptcha/"`
- **Expected:** the Auth iframe loads.
- **Cause:** `website/src/scripts/bench-arena.ts` (~line 161) sets `arenaFirebaseConfig.authDomain = location.hostname` (burnbar.ai), so Firebase loads `https://burnbar.ai/__/auth/iframe`. But the `/bench/arena/vote` CSP in `firebase.json` has no `'self'` in `frame-src`.
- **Evidence:** `logs/console_network_errors.md` (prod section), `screenshots/fullpage/prod_bench_arena_vote_mobile-light.png`
- **Source:** `firebase.json` (`/bench/arena/vote` header block), `website/scripts/update-csp-hashes.mjs` (generator), `website/scripts/test-security-headers.mjs`
- **Fix:** add `'self'` to `frame-src` for `/bench/arena/vote` (and `/link`, `/beta`, `/hermes/connect`, `/subscribe` if they also use `location.hostname` as authDomain). Add a header test asserting that.

#### BB-07: Privacy page "Read the full analysis" links to a GitHub 404
- **Severity:** P1 (a broken link on the trust page, in a section about data leakage)
- **Where:** prod and staging `/privacy`
- **Viewport/theme:** all
- **Repro:** `/privacy`, then the section ending "…we say so out loud.", then click **Read the full analysis**.
- **Expected:** the leakage analysis doc.
- **Actual:** `https://github.com/Imagine-That-Ai/BurnBar/blob/main/docs/pensieve-leakage-analysis.md` returns **404**. No file with that name exists anywhere in the repo tree.
- **Evidence:** `screenshots/BB07_prod_privacy-broken-analysis-link_desktop-light.png`, `logs/broken_links.txt`
- **Source:** `website/src/pages/privacy.astro:31` (`leakageUrl`) and `:256`
- **Fix:** point it at the real doc (or write it). Add `privacy.astro` external links to `website/scripts/check-links.mjs`.

#### BB-08: Mobile header: wordmark collides with the theme toggle; hamburger is an 18 px-wide sliver
- **Severity:** P1 (shows on every page on phones)
- **Where:** prod and staging, all pages
- **Viewport/theme:** mobile-light and mobile-dark
- **Repro:** open any page at 390×844.
- **Actual:** the "OpenBurnBar" wordmark text runs into the theme-toggle button (link box ends at x=141, but the glyphs reach about x=168, and the toggle starts at x=165). The menu button is a bordered capsule 18 × 36 px (x=355–373), which is far below the 44 px / 24 px tap-target guidance and looks like a rendering glitch.
- **Evidence:** `screenshots/BB08_prod_mobile-header-collision_mobile-light.png`, plus geometry from the DOM (`logs/raw_results/prod_mobile-light.json`)
- **Source:** `website/src/components/Header.astro` (`.site-header__menu`, brand and actions layout)
- **Fix:** under ~420 px, hide the GitHub/theme pill or shrink the Download button to an icon, give the wordmark `white-space: nowrap; flex-shrink: 0`, and make `.site-header__menu` at least 44×44 with a borderless icon.

#### BB-09: Primary CTA and hero eyebrow expose a raw build string "1.0.40+repair.41"
- **Severity:** P1 (looks unfinished; breaks the hero button layout)
- **Where:** prod `/` (CTA plus eyebrow `V1.0.40+REPAIR.41 MACOS`), `/download` (card, "Release · 1.0.40+repair.41" chip, button)
- **Viewport/theme:** all. The layout break is on desktop.
- **Actual:** "Download for Mac — 1.0.40+repair.41 →". The long label widens the primary button, so "Read the privacy model" drops to its own orphan row. On mobile, the eyebrow wraps into three ragged lines. Also, `website/public/downloads/release-metadata.json` says `1.0.40+repair.36` while `site.ts` says `repair.41`.
- **Expected:** "Download for Mac" with a quiet version caption (e.g. "v1.0.40 · macOS 14+"). All three CTAs on one row.
- **Evidence:** `screenshots/BB09_prod_home-cta-build-string_desktop-light.png`, `screenshots/BB09_prod_download-build-string_desktop-light.png`
- **Source:** `website/src/pages/index.astro:131` (`Download for Mac — {SITE.macReleaseLatest}`), `website/src/data/site.ts:117–122`, `website/public/downloads/release-metadata.json`, `website/src/pages/download.astro`
- **Fix:** add a `macReleaseDisplay` (semver without build metadata) for UI copy, keep the full tag in the download URL, and reconcile `release-metadata.json`.

#### BB-10: Internal dev notes, file paths and raw Markdown are shown to visitors
- **Severity:** P1 (reads as AI-generated scaffolding, not marketing; confusing for new users)
- **Where:** prod. Worst case is `/` (Nest Hub card). Also `/platforms`, `/product`, `/router`, `/subscribe`, `/memory`, `/router/daily/2026-08-19`, `/download`, `/faq`.
- **Viewport/theme:** all
- **Actual (verbatim, captured from rendered text):**
  - "Acceptance probe before "healthy" — \`docs/SMART_DISPLAY_DEVICE_QA.md\`": literal backticks (`/`, `/product`, `/router`, `/platforms`).
  - "Faithful re-render · mirrors NestHubMiniPreview.swift" and "…PixelClockPreviewView.swift".
  - CLI card: "(Distinct from the npm package \`openburnbar\`…)": literal backticks.
  - `/platforms`: "Registry Config Paths: website/src/data/surfaces.ts / website/src/data/platform-surfaces.ts", a fake code editor with `surfaces.ts`, and unrendered `- [ ] **Acceptance**: Run \`scripts/qa-tvos-relay\``.
  - `/subscribe`: "Your Firebase UID is the durable link between web billing and every BurnBar app." and "Payment by Stripe · Firebase Auth + App Check".
  - `/router/daily/*`: "OPERATOR NOTES: Generated by \`node website/scripts/run-research.mjs\`… Snapshots from research: 1221. Catalog matches: 15."
  - `/memory`: "server.py \`_memory_write_enabled()\`; PensieveKnowledgeWatcher.swift".
  - Android status chip: "Remediation in progress · Play Store pending".
- **Evidence:** `screenshots/BB10_prod_home-nesthub-dev-notes_desktop-light.png`, `screenshots/BB10_prod_platforms-registry-config-paths_desktop-light.png`, `screenshots/BB10_prod_subscribe-firebase-uid-copy_desktop-light.png`, `screenshots/BB10_prod_router-daily-operator-notes_desktop-light.png`, `screenshots/BB26_prod_home-nine-surfaces-orphan-card_desktop-light.png` (CLI and Android cards)
- **Source:** `website/src/data/platform-surfaces.ts:55,60,79`, `website/src/data/surfaces.ts:162`, `website/src/pages/platforms/index.astro:~100–200`, `website/src/pages/subscribe.astro:91`, `website/src/components/RouterRundownReport.astro:265`, `website/src/pages/memory.astro`, `website/src/pages/download.astro:516`
- **Fix:** strip backticks or render them as `<code>`. Remove file and Swift names from captions (move them into HTML comments or the repo docs). Remove the registry/how-to-add-a-surface section from the public page (or move it to a contributor doc). Replace the auth jargon on `/subscribe` with "Use the same account as the BurnBar app so your plan follows you." Hide operator notes behind a "Methodology" disclosure. Add a test that fails on `` ` `` or `**` in rendered text.

#### BB-11: "Daily" model board is 7 weeks stale but promises 24-hour refreshes
- **Severity:** P1 (credibility; the product leans on "honest" data)
- **Where:** prod `/router/daily` (newest 2026-08-19, 50 days ago). Staging newest is 2026-07-12.
- **Viewport/theme:** all
- **Actual:** "BurnBar refreshes its model-landscape snapshot once every twenty-four hours…" sits above "14 dated rundowns · newest · 2026-08-19". The home Nest Hub mockup is "hydrated from the latest router rundown", so it shows stale picks too.
- **Evidence:** `screenshots/BB11_prod_router-daily-stale-archive_desktop-light.png`
- **Source:** `website/src/pages/router/daily/index.astro:39`, `website/src/data/router-rundown-history/` (latest JSON is `2026-08-19.json`), `website/scripts/generate-rundown.mjs` / the scheduled job
- **Fix:** restore the daily generation job and redeploy. Otherwise change the copy to the real cadence, and show a "last updated N days ago" warning when the newest board is more than 48 h old.

#### BB-12: Staging console (`burnbar-staging-console`) is not deployed
- **Severity:** P1 (the console surface can't be tested before prod)
- **Where:** `https://burnbar-staging-console.web.app/` and `.firebaseapp.com`
- **Actual:** Firebase "Site Not Found" (404). `.firebaserc` maps `targets.burnbar-staging.hosting.console` to `burnbar-staging-console`, and `firebase.json` hosting target `console` serves `apps/console/out`. Prod console `app.burnbar.ai` / `burnbar-console.web.app` returns 200.
- **Evidence:** `screenshots/BB12_staging-console_site-not-found.png`, `logs/BB03_BB12_BB22_headers-and-routes.txt`
- **Source:** `.firebaserc`, `firebase.json` (console target), `apps/console/`, `docs/PENSIEVE_CONTROL_CENTER_RUNBOOK.md` (prod-only setup steps), `.github/workflows/deploy-staging.yml`
- **Fix:** create the `burnbar-staging-console` Hosting site (if missing), build `apps/console` with staging `NEXT_PUBLIC_FIREBASE_*` values, deploy it through the staging lane, and add the domain to staging Auth authorized domains.

### P2

#### BB-13: Consent banner covers the primary CTA on the mobile first view
- **Severity:** P2
- **Where:** prod and staging `/` (the banner appears on every page until dismissed)
- **Viewport/theme:** mobile-light and mobile-dark (worst). On desktop it overlaps the hero mockup.
- **Actual:** on first load at 390×844, the fixed banner (about 150 px tall) sits exactly over "Download for Mac". No CTA is visible above the fold.
- **Evidence:** `screenshots/BB13_prod_home-first-view-consent-covers-cta_mobile-light.png`, `screenshots/BB13_prod_home-first-view-consent-covers-cta_mobile-dark.png`
- **Source:** `website/src/components/ConsentBanner.astro`
- **Fix:** on mobile, make it a compact bottom sheet (single line plus two small buttons) or delay it until first scroll. Also reduce the hero's top padding and eyebrow wrapping so the CTA sits higher.

#### BB-14: Home sections use two different left edges (28 px vs 97 px)
- **Severity:** P2 (layout misalignment)
- **Where:** prod and staging `/`
- **Viewport/theme:** desktop (all themes)
- **Actual:** the headings of "Three commitments", "Providers" and "Beyond the dashboard" start at x≈97. Hero, "Inside the app", "Where it shows up", "Hermes", "Trust" and "Pricing" start at x≈28. Scrolling, the page visibly zig-zags.
- **Evidence:** `screenshots/BB14_prod_home-section-left-edges-misaligned_desktop-light.png` ("Hermes" at 28 px directly above "Beyond the dashboard" at 97 px)
- **Source:** `website/src/pages/index.astro`. Sections `pillars` (l.212), `provshow` (l.306) and `companion` (l.591) use `.container`; the rest use `.container container--wide`. See `website/src/styles/globals.css:390–403`.
- **Fix:** use one container width for section heads (keep narrow measure via `max-width` on the text, not the container).

#### BB-15: Three sign-in screens, three different button designs (plus a placeholder logo)
- **Severity:** P2 (feels stitched together right at the conversion step)
- **Where:** prod (and staging) `/link`, `/hermes/connect`, `/subscribe`
- **Viewport/theme:** all
- **Actual:**
  - `/link`: orange ember "Sign in with Google" and white "Sign in with Apple", no logos.
  - `/hermes/connect`: white Google button with G logo, black Apple button with logo, and a "BB" text monogram in a circle instead of the brand mark.
  - `/subscribe`: grey-gradient "Continue with Google/Apple" on a dark card, which looks disabled.
  - Labels are inconsistent ("Sign in with" vs "Continue with"), and heading fonts differ (regular serif vs the condensed display face).
- **Evidence:** `screenshots/BB15_prod_link-auth-buttons_desktop-light.png`, `screenshots/BB15_prod_hermes-connect-auth-buttons_desktop-light.png`, `screenshots/BB15_prod_subscribe-auth-buttons_desktop-light.png`, `screenshots/BB15_prod_hermes-connect-bb-monogram_desktop-light.png`
- **Source:** `website/src/pages/link.astro`, `website/src/pages/hermes/connect.astro`, `website/src/pages/subscribe.astro`, `website/src/pages/beta.astro` (4th variant: `btn--ember` plus `btn--secondary`)
- **Fix:** extract one `<AuthButtons>` component following Google/Apple brand guidelines (logo, same label verb), and use `Brandmark.astro` instead of "BB".

#### BB-16: Light-theme dot-crest background paints a boxy pixel blob behind headlines and CTAs
- **Severity:** P2 (looks like a rendering glitch)
- **Where:** prod and staging, all pages in light mode. Clearest on staging `/this-page-does-not-exist-qa` (404) and `/router/daily/2026-07-12`; faint on prod 404 (it's animated, so position varies).
- **Viewport/theme:** desktop-light (also mobile-light)
- **Actual:** a crest-shaped cluster of coloured dots, with a visible lighter rectangular backing, assembles behind body copy and buttons ("That URL doesn't resolve…" / "Back to home"; the daily-page intro paragraph).
- **Evidence:** `screenshots/BB16_staging_404-dot-blob-crop_desktop-light.png`, `screenshots/BB03_staging_router-daily-live-feed-unavailable_desktop-light.png` (blob behind the intro text), `screenshots/BB16_prod_404-dot-blob-behind-copy_desktop-light.png`
- **Source:** `website/src/scripts/dotConstellation.ts`, `website/src/layouts/BaseLayout.astro:~159–198`
- **Fix:** keep crests out of text and CTA bounding boxes (sample `main` element rects, like the existing rect logic), drop the rectangular offscreen backing (clear to transparent), and lower the opacity behind content.

#### BB-17: `/control` and `/floo` feature vignettes bleed off both viewport edges with a muddy grey gradient
- **Severity:** P2
- **Where:** prod and staging `/control`, `/floo`
- **Viewport/theme:** desktop-light (worst)
- **Actual:** alternating vignette panels touch x=0 on the left or are clipped at the right edge, while the text column sits about 145 px in. The panel fill fades white → charcoal (`#555`), which looks dirty on the cream page.
- **Evidence:** `screenshots/BB17_prod_control-vignettes-bleed-off-edges_desktop-light.png`
- **Source:** `website/src/components/FeatureVignette.astro` (background ~l.481), `website/src/components/RuleVignette.astro`, `website/src/data/capabilities.ts`
- **Fix:** constrain the vignettes to the container, and give light mode a light surface (`--ink-surface` light token) instead of the dark gradient.

#### BB-18: Arena page contradicts itself and is all placeholders
- **Severity:** P2 (confusing)
- **Where:** prod `/bench/arena`
- **Viewport/theme:** all
- **Actual:** the status pill says "voting opens soon", but the hero CTA says "Cast a blind vote" and the ballot box says "Open the ballot… no sign-in needed". "Current Arena standings" is empty. The "Artifact gallery" is six "ARTIFACT PENDING" grey frames (5 + 1 orphan on desktop).
- **Evidence:** `screenshots/BB18_prod_bench-arena-voting-opens-soon-vs-cta_desktop-light.png`, `screenshots/BB18_prod_bench-arena-artifact-pending-gallery_desktop-light.png`
- **Source:** `website/src/pages/bench/arena.astro:65` (`votingOpen ? … : "voting opens soon"`), `:251`, `:274`
- **Fix:** derive the pill from the same flag as the CTA ("Voting open · N votes" or a disabled CTA). Hide the gallery until real thumbnails exist, or show 3 real ones.

#### BB-19: Pricing "Ultra" badge text runs under the plan logo
- **Severity:** P2
- **Where:** prod `/pricing` (also the home pricing teaser)
- **Viewport/theme:** desktop (both themes)
- **Actual:** "FOR YOUR WHOLE SECOND BRAIN" is clipped behind the cloud logo ("…SECOND B").
- **Evidence:** `screenshots/BB19_prod_pricing-ultra-badge-clipped_desktop-light.png`
- **Source:** `website/src/components/PricingPlans.astro:313` (`.plan__badge`)
- **Fix:** shorten it to "Your second brain", or reserve logo width (`padding-right` on the badge row / `max-width: calc(100% - 72px)`).

#### BB-20: Typography sprawl: 52 distinct font sizes on home; lots of text below 11 px
- **Severity:** P2 (inconsistent and hard to read)
- **Where:** prod `/` (52 sizes on desktop, 48 on mobile; 85–91 text nodes under 11 px, smallest 7.2 px desktop / 6.1 px mobile, partly inside mockups), `/bench/arena/vote` (mono labels 9.28–9.92 px on mobile), `/bench/*`, `/pricing` (9.9 px "SAVE ~18%").
- **Viewport/theme:** all
- **Evidence:** `screenshots/BB20_prod_bench-arena-vote-tiny-mono_mobile-light.png`, `logs/raw_results/prod_desktop-light.json` (`m.fs`, `m.small`)
- **Source:** `website/src/styles/tokens.css`, `website/src/styles/globals.css` (`.eyebrow`, `.mono`, `.tag`), `website/src/styles/bench-instrument.css`
- **Fix:** collapse to a type scale of about 8 steps. Set the floor at 12 px for real copy (11 px for all-caps eyebrows), and don't scale mockup text below ~9 px.

#### BB-21: Accessibility violations (axe, prod)
- **Severity:** P2
- **Where / what:**
  - `/bench/data`, `/bench/methodology`, `/bench/report`: **critical** `aria-allowed-attr` ×5. `<a class="ins-segment__btn" aria-selected=…>` (aria-selected isn't allowed on links).
  - `/router` (`.lcsm__list`) and `/product` (`.surfaces__grid`): `list`. `<ul>` children are `[role=button]` / `<article>`, not `<li>`.
  - `/download`: `scrollable-region-focusable`. The code `<pre>` in step 1 can't be reached by keyboard.
  - Staging adds hundreds of colour-contrast failures (e.g. `/bench/report` ×1,536, `/mcp` ×85), which are fixed on prod.
- **Evidence:** `screenshots/BB21_prod_bench-data_desktop-light.png`, `logs/raw_results/prod_desktop-light.json` (`axe`)
- **Source:** `website/src/components/bench/BenchNav.astro` (`ins-segment__btn`), `website/src/components/LifecycleStateMachine.astro` (`.lcsm__list`), `website/src/pages/product.astro` (`.surfaces__grid`), `website/src/pages/download.astro` (step `<pre>`)
- **Fix:** use `aria-current="page"` on the nav links, wrap list children in `<li>` (or drop the `<ul>`), and add `tabindex="0"` to scrollable `<pre>`.

#### BB-22: Staging is publicly indexable
- **Severity:** P2
- **Where:** staging, site-wide
- **Actual:** no `X-Robots-Tag` header, `robots.txt` is `Allow: /`, and most pages have no `<meta name=robots>`. Canonicals point to burnbar.ai, which helps, but STAGING.md says the promotion lane "adds `X-Robots-Tag: noindex, nofollow, noarchive`". In `firebase.json`, only the `console` target has that header.
- **Evidence:** `logs/BB03_BB12_BB22_headers-and-routes.txt`
- **Source:** `firebase.json` (marketing headers), `website/scripts/build-staging.mjs`, `website/scripts/verify-staging-deployment.mjs`
- **Fix:** have the staging build inject `X-Robots-Tag: noindex, nofollow, noarchive` (or a staging-only `robots.txt` with `Disallow: /`), and assert it in `verify-staging-deployment.mjs`.

#### BB-23: "macOS , iOS , and Linux": shrink-wrap script inserts spaces before commas
- **Severity:** P2 (visible typo directly under the H1)
- **Where:** prod and staging `/download` lead paragraph
- **Viewport/theme:** all
- **Actual:** the source is `<strong>macOS</strong>, <strong>iOS</strong>, and <strong>Linux</strong>`. After hydration, the DOM is `<span class="glass-line-pill">macOS , iOS , and Linux ship today…</span>`: bold is lost and stray spaces are added.
- **Evidence:** `screenshots/BB23_prod_download-space-before-comma_desktop-light.png` (2×)
- **Source:** `website/src/scripts/pretextShrinkwrap.ts` (selector includes `.pagehead__lead`; it rebuilds lines from text nodes joined with spaces), `website/src/pages/download.astro:34–36`
- **Fix:** preserve inline element boundaries and don't add a separator before punctuation. Alternatively, exclude leads containing inline markup from shrink-wrapping (`data-pretext-native`).

### P3: polish

#### BB-24: Stats band "7·2" is unreadable as a stat
- **Where:** prod and staging `/` stats band. Desktop and mobile, all themes.
- **Actual:** "7 ·2 / Upstream providers routed across two same-format pools (OpenAI · Anthropic)". The small "·2" reads like a typo. On mobile, each stat also keeps a stray right-hand vertical divider.
- **Evidence:** `screenshots/BB24_prod_home-stats-strip-7-2_desktop-light.png`
- **Source:** `website/src/pages/index.astro:~173–205` (`band__num-unit`, `band__sep`)
- **Fix:** "7 providers / 2 pools" as two stats, or a single plain-language label. Hide `.band__sep` when the band stacks.

#### BB-25: Duplicate captions under the hero mockup
- **Where:** prod `/` (mobile is worst)
- **Actual:** "Synthetic demo data · representative menu-bar render" and then, directly below, "menu-bar popover · synthetic demo data".
- **Evidence:** `screenshots/BB25_prod_home-duplicate-mockup-captions_mobile-light.png`
- **Source:** `website/src/components/BarMockup.astro:195` and `website/src/pages/index.astro:164`
- **Fix:** keep one caption.

#### BB-26: "Nine surfaces, one daemon" grid orphans the 9th card
- **Where:** prod and staging `/` at desktop width
- **Actual:** a 4-column grid with 9 cards leaves "Android companion" alone on row 3.
- **Evidence:** `screenshots/BB26_prod_home-nine-surfaces-orphan-card_desktop-light.png`
- **Source:** `website/src/pages/index.astro` (`.surfaces` grid, l.~336), `website/src/components/SurfaceCard.astro`
- **Fix:** use a 3-column grid at desktop (3×3), or make the last card span.

#### BB-27: Pricing H1 ends with a one-word widow ("money.")
- **Where:** prod `/pricing`, desktop
- **Evidence:** `screenshots/BB27_prod_pricing-h1-widow_desktop-light.png`
- **Source:** `website/src/pages/pricing.astro` (pagehead)
- **Fix:** `text-wrap: balance` on page H1s, or a wider max-width.

#### BB-28: Download page repeats the six platform icons and reuses the Apple logo for the App Store
- **Where:** prod `/download`, desktop
- **Actual:** six platform cards are followed by a redundant row of the same six mini-icons. The "App Store" card and the macOS card both use the Apple glyph.
- **Evidence:** `screenshots/BB28_prod_download-duplicate-icon-row_desktop-light.png`
- **Source:** `website/src/pages/download.astro`, `website/src/components/DownloadPlatformIcon.astro`
- **Fix:** drop the icon row (or make it the only jump-nav), and use the App Store glyph.

#### BB-29: Ember gradient buttons pass through a muddy olive midpoint
- **Where:** prod and staging, all primary CTAs (light mode is most visible)
- **Actual:** the animated 135° gradient red → fire → amber → red, at `background-size: 200%`, shows a brown/olive band mid-button, with white text on the amber section.
- **Evidence:** `screenshots/BB29_prod_header-ember-button-muddy_desktop-light.png` (3×)
- **Source:** `website/src/styles/globals.css:643–690` (`.btn--ember`, `emberFlow`)
- **Fix:** use a two-stop red → orange gradient (no amber), or darken the amber stop. Check text contrast at every animation frame.

#### BB-30: Nest Hub mockup shows "resets May 8 / May 14" next to a live "Thu, Oct 8" clock
- **Where:** prod `/`, `/product`, `/platforms`, `/router`
- **Evidence:** `screenshots/BB30_prod_home-nesthub-stale-reset-dates_desktop-light.png`
- **Source:** `website/src/components/platform/NestHubScreen.astro:136,143`
- **Fix:** compute the reset dates relative to now, or drop the live clock.

#### BB-31: "Workos session token" vs "WorkOS browser session" in the same provider table
- **Where:** prod `/` providers table and `/providers`
- **Evidence:** `screenshots/BB31_prod_providers-workos-casing_desktop-light.png`
- **Source:** `website/src/data/providers.ts:80`
- **Fix:** "WorkOS".

#### BB-32: Cloudflare Email Obfuscation rewrites every `mailto:` on prod
- **Where:** prod (Cloudflare only), every page with an email (footer, `/support`, `/privacy`, `/legal/*`, `/bench*`, `/subscribe`)
- **Actual:** raw HTML has `<a href="/cdn-cgi/l/email-protection#…">[email protected]</a>`. With JS, it's decoded. Without JS, crawlers, reader modes and link checkers see "[email protected]", and `/cdn-cgi/l/email-protection` returns 404. My HTML-level crawler flagged it as a broken internal link.
- **Evidence:** `logs/BB32_cloudflare-email-obfuscation.txt`
- **Source:** Cloudflare dashboard → Scrape Shield → Email Address Obfuscation (not in repo)
- **Fix:** turn it off for burnbar.ai (the addresses are public role inboxes anyway).

#### BB-33: Arena vote page console noise
- **Where:** prod `/bench/arena/vote`
- **Actual:**
  - `Failed to execute 'postMessage' on 'DOMWindow': The target origin provided ('https://burnbar.ai') does not match the recipient window's origin ('null')` ×2 per load (3 of 4 configs). The sandboxed artifact iframe has an opaque origin, so these messages are dropped.
  - Intermittent `pageerror: canvas.getContext is not a function` (1 of 4 configs plus 4 manual reloads: 1 hit).
- **Evidence:** `logs/console_network_errors.md`, `screenshots/fullpage/prod_bench_arena_vote_desktop-dark.png`
- **Source:** `website/src/scripts/bench-arena.ts` (postMessage target origin, ~l.1094 canvas), `website/src/scripts/arena-net.ts`, `website/src/scripts/emberSwarm.ts` (`#bgCanvas` lookup)
- **Fix:** post to `'*'` and validate on receipt (the iframe is sandboxed), or drop `allow-same-origin` assumptions. Guard `canvas instanceof HTMLCanvasElement` before `getContext`.

#### BB-34: Daily board cites a raw API endpoint as a "source" (401)
- **Where:** staging `/router/daily/2026-07-12` (links to `https://artificialanalysis.ai/api/v2/data/llms/models`, which returns 401). The same URLs are in repo data `website/src/data/router-rundown-history/2026-05-18.json`.
- **Evidence:** `logs/broken_links.txt`
- **Source:** `website/src/components/RouterRundownReport.astro`, `website/scripts/lib/rundown-generator.mjs`, history JSON
- **Fix:** map API source URLs to their public human pages before rendering.

---

## 6. Untested / blocked

| Area | Why | What's needed |
|---|---|---|
| `/beta` claim flow (signed-out state, code entry, success or error) | Not deployed on staging or prod (BB-02) | Deploy `main` to staging, plus a staging test account |
| All signed-in flows: `/link` CLI linking, `/hermes/connect` approval, `/subscribe` checkout (Stripe), arena voting identity | No test login. Instructions said not to create accounts or sign in. Staging is also wired to prod Firebase (BB-01) | Fix BB-01, then provide a staging-only test user and Stripe test mode |
| Staging console (`apps/console`: `/`, `/dashboard`, `/escrow`, `/experimental`, `/inventory`, `/pensieve`, `/profile`, `/settings`) | Not deployed (BB-12) | Deploy the console to `burnbar-staging-console`, plus a test user |
| Prod console `app.burnbar.ai` | Production plus login (out of scope) | Only HTTP 200 was checked |
| Forms: waitlist, subscribe and beta submissions, consent "Enable analytics" / "Not now" | Not submitted or clicked by instruction. The banner was hidden via inline style for some evidence shots only. | n/a |
| Arena vote end to end (play artifacts, cast vote) | Would submit a vote | Staging with BB-03 fixed |
| Theme toggle button (manual override) and mobile nav drawer interaction | Out of time and scope for a passive crawl. `prefers-color-scheme` was tested instead | Quick manual pass |
| Performance / Core Web Vitals | Shared box was overloaded (load average about 90), so numbers would be meaningless | Run Lighthouse on a quiet machine |
| Pages taller than 16,384 px below that line in full-page PNGs | Chromium capture limit (see §2) | Targeted viewport captures were used for findings |
| Older `/router/daily/<date>` pages | HTTP 200 checked only; layout is the same template as the latest | n/a |

## 7. Appendix: raw console and network errors (all 248 captures)

Full aggregated list: `logs/console_network_errors.md`. Per-capture JSON with metrics and axe: `logs/raw_results/*.json`. Link check: `logs/links_checked.json` and `logs/broken_links.txt`.

### Staging
- `console.error: Failed to load resource: 404 [src: https://burnbar-staging.web.app/api/router-rundown/latest]`: 20 captures (`/`, `/platforms`, `/product`, `/router`, `/router/daily/2026-07-12` × 4 configs). Source of the "LIVE FEED UNAVAILABLE" pill (BB-03).
- `HTTP 404 (document) /beta`: 4 captures (BB-02).
- `console.warning: Info: The current domain is not authorized for OAuth operations… Add your domain (burnbar-staging.web.app)… [src: https://burnbar.firebaseapp.com/__/auth/iframe.js]`: `/link`, `/hermes/connect`, `/subscribe` × mobile-light and mobile-dark (BB-01).
- `requestfailed net::ERR_ABORTED https://www.google.com/recaptcha/enterprise/clr?k=6Ld3bAktAAAAAABiZujpMLmUcvSMUPiJk6qENbOg`: `/link`, `/hermes/connect`, `/subscribe` × 4. This is the **prod** reCAPTCHA key (BB-01). The abort itself is likely benign.
- `HTTP 404 /this-page-does-not-exist-qa`: expected (404 template test).
- Broken links: `https://tikkas-mac-mini.tail602e93.ts.net:8443/arena` (DNS fail, from `/bench/arena`); `https://github.com/Imagine-That-Ai/BurnBar/blob/main/docs/pensieve-leakage-analysis.md` 404 (from `/privacy`); `https://artificialanalysis.ai/api/v2/data/llms/models` 401 (from `/router/daily/2026-07-12`).

### Prod
- `HTTP 404 (document) /beta`: 4 captures (BB-02).
- `console.error: Framing 'https://burnbar.ai/__/auth/iframe?apiKey=AIzaSyBiAIHwf1MKZ6LN5HrsaPYsAR3UTe8hyw4&appName=arena-public&v=12.17.0…' violates the following Content Security Policy directive: "frame-src https://burnbar-arena-artifacts.web.app https://bur…" [src: https://apis.google.com/]`: `/bench/arena/vote` mobile-light and mobile-dark (BB-06).
- `console.warning: Failed to execute 'postMessage' on 'DOMWindow': The target origin provided ('https://burnbar.ai') does not match the recipient window's origin ('null').`: `/bench/arena/vote` × 3 configs (BB-33).
- `pageerror: canvas.getContext is not a function`: `/bench/arena/vote` desktop-dark, once (BB-33).
- `requestfailed net::ERR_ABORTED https://www.google.com/recaptcha/enterprise/clr?k=6Ld3bAktAAAAAABiZujpMLmUcvSMUPiJk6qENbOg`: `/link`, `/hermes/connect`, `/subscribe`, `/bench/arena/vote` × 4. Likely benign (App Check token prefetch aborted on navigation).
- `HTTP 404 /this-page-does-not-exist-qa`: expected.
- Broken links: `docs/pensieve-leakage-analysis.md` 404 (from `/privacy`, BB-07). HTML-level: `/cdn-cgi/l/email-protection` 404 (BB-32).
- No failed images, no mixed content, and every page has a title, meta description, `og:title`, `og:image` (`/og/default.png` returns 200) and canonical. `/beta` and the 404 pages correctly set `noindex, nofollow`.

## 8. Screenshot index

- `screenshots/BBxx_<env>_<what>_<viewport>-<theme>.png`: targeted evidence for finding BB-xx (viewport-sized or clipped; 2–3× where noted).
- `screenshots/fullpage/<env>_<page>_<viewport>-<theme>.png`: only the full-page captures referenced above are committed to this branch. All 248 captures (one per page per config; desktop downscaled 50%, palette-quantized, cropped at 16,384 px) were left out of the repo to keep this public repo small. They are on the QA box at `/workspace/findings/burnbar/screenshots/fullpage/` and can be shared on request.
