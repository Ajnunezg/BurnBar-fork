#!/usr/bin/env node
/**
 * test-firebase-config.mjs — built-output gate for the live Firebase web config.
 *
 * THE REGRESSION THIS POLICES SHIPPED TO PRODUCTION (finding C2): for months
 * website/src/lib/firebaseClient.ts fell back to a fake apiKey
 * ("AIzaSyFakeKeyPlaceholderForBuild") whenever PUBLIC_FIREBASE_* env was unset.
 * CI deploys burnbar.ai with NO .env (the real public config is committed once, in
 * config/firebase-web-public.json, and both web clients fall back to it), so any
 * reintroduced placeholder gets inlined into the shipped bundle and sign-in on
 * /link and /hermes/connect dies silently — every gate stayed green because none
 * looked at the built output.
 *
 * This gate fails closed on three independent checks:
 *   1. The committed public config is complete and is not a placeholder.
 *   2. NO fake/placeholder Firebase identifier may appear anywhere in dist/.
 *   3. The expected apiKey, project id, and App Check site key MUST appear in
 *      at least one built asset (proving the live config made it into the bundle).
 *
 * These are PUBLIC client identifiers (not secrets — they ship in every client
 * bundle regardless; security is enforced server-side by Firestore rules + App
 * Check). Reading them from one reviewed config file is the intended pattern.
 */

import { readFileSync, readdirSync, statSync } from "node:fs";
import { dirname, join, relative } from "node:path";
import { fileURLToPath } from "node:url";
import assert from "node:assert";

const HERE = dirname(fileURLToPath(import.meta.url));
const ROOT = join(HERE, "..");
const DIST = join(ROOT, "dist");
const PUBLIC_CONFIG_PATH = join(ROOT, "..", "config", "firebase-web-public.json");
const PUBLIC_CONFIG = JSON.parse(readFileSync(PUBLIC_CONFIG_PATH, "utf8"));

// Fragments that must NEVER appear in a shipped asset. Any one of these means a
// fake placeholder fallback was re-inlined and the build would deploy broken auth.
const FORBIDDEN_FRAGMENTS = [
  "FakeKeyPlaceholder",
  "AIzaSyFakeKeyPlaceholderForBuild",
  "1:123456789:web:abcdef",
  "messagingSenderId:\"123456789\"",
];

// Check 1: the committed defaults are real values, not blanks or placeholders.
for (const [name, value] of Object.entries({
  projectId: PUBLIC_CONFIG.projectId,
  apiKey: PUBLIC_CONFIG.apiKey,
  messagingSenderId: PUBLIC_CONFIG.messagingSenderId,
  appId: PUBLIC_CONFIG.appId,
  recaptchaEnterpriseSiteKey: PUBLIC_CONFIG.recaptchaEnterpriseSiteKey,
  "website.authDomain": PUBLIC_CONFIG.website?.authDomain,
  "website.storageBucket": PUBLIC_CONFIG.website?.storageBucket
})) {
  assert.ok(typeof value === "string" && value.trim() === value && value.length > 0, `${PUBLIC_CONFIG_PATH}: ${name} must be a non-empty trimmed string`);
  assert.ok(
    !FORBIDDEN_FRAGMENTS.some((fragment) => value.includes(fragment)),
    `${PUBLIC_CONFIG_PATH}: ${name} is a placeholder`
  );
}
assert.match(PUBLIC_CONFIG.apiKey, /^AIza[0-9A-Za-z_-]{35}$/u, `${PUBLIC_CONFIG_PATH}: apiKey is not a Firebase web API key`);

// CI/deploy environments can override these public identifiers when building
// the isolated staging site. A normal production build falls back to the
// reviewed "burnbar" values in config/firebase-web-public.json.
const EXPECTED_PROJECT_ID = process.env.PUBLIC_FIREBASE_PROJECT_ID || PUBLIC_CONFIG.projectId;
const EXPECTED_API_KEY = process.env.PUBLIC_FIREBASE_API_KEY || PUBLIC_CONFIG.apiKey;
const EXPECTED_RECAPTCHA_ENTERPRISE_SITE_KEY =
  process.env.PUBLIC_RECAPTCHA_ENTERPRISE_KEY || PUBLIC_CONFIG.recaptchaEnterpriseSiteKey;

function walk(dir, out = []) {
  for (const entry of readdirSync(dir)) {
    const p = join(dir, entry);
    if (statSync(p).isDirectory()) walk(p, out);
    else out.push(p);
  }
  return out;
}

const files = walk(DIST).filter((f) => /\.(js|mjs|html)$/.test(f));
assert.ok(files.length > 10, `expected a built dist/, found ${files.length} JS/HTML files`);

// Check 1: no placeholder may survive into the build (scan ALL assets).
for (const file of files) {
  const text = readFileSync(file, "utf8");
  for (const forbidden of FORBIDDEN_FRAGMENTS) {
    assert.ok(
      !text.includes(forbidden),
      `${relative(ROOT, file)} contains forbidden Firebase placeholder "${forbidden}". ` +
        `The fake fallback was re-introduced in src/lib/firebaseClient.ts — restore the real ` +
        `public "burnbar" project config so sign-in works on /link and /hermes/connect.`
    );
  }
}

// Check 2: the selected environment's real public identifiers must actually be
// present in the bundle. This prevents a staging deploy from silently shipping
// a production Firebase client (and vice versa).
const projectIdPresent = files.some((file) =>
  readFileSync(file, "utf8").includes(EXPECTED_PROJECT_ID)
);
assert.ok(
  projectIdPresent,
  `the expected Firebase project id ("${EXPECTED_PROJECT_ID}") is missing from every built asset in dist/.`
);

const apiKeyPresent = files.some((file) => readFileSync(file, "utf8").includes(EXPECTED_API_KEY));
assert.ok(
  apiKeyPresent,
  `the expected Firebase apiKey ("${EXPECTED_API_KEY}") is missing from every built asset in dist/. ` +
    `Without it, signInWithPopup fails and /link + /hermes/connect cannot authenticate. ` +
    `Verify the build environment selects the intended Firebase project.`
);

const appCheckSiteKeyPresent = files.some((file) =>
  readFileSync(file, "utf8").includes(EXPECTED_RECAPTCHA_ENTERPRISE_SITE_KEY)
);
assert.ok(
  appCheckSiteKeyPresent,
  `the expected reCAPTCHA Enterprise site key for "${EXPECTED_PROJECT_ID}" is missing from every built asset in dist/. ` +
    "Without it, App Check-enforced billing and account callables fail from the website."
);

console.log(
  `✓ Firebase config: scanned ${files.length} built asset(s); no placeholder present and ${EXPECTED_PROJECT_ID} Auth + App Check config is bundled.`
);
