#!/usr/bin/env node

// eslint-plugin-astro 3 (ESLint 10) requires ^22.22.3 || ^24.16.0 || >=26.3.0,
// matching package.json "engines". Each entry is a floor within its major; the
// last one also admits every later major.
const supported = [
  { major: 22, minor: 22, patch: 3 },
  { major: 24, minor: 16, patch: 0 },
  { major: 26, minor: 3, patch: 0, orLater: true },
];
const supportedRange = "^22.22.3 || ^24.16.0 || >=26.3.0";

function parseVersion(raw) {
  const match = /^v?(\d+)\.(\d+)\.(\d+)/.exec(raw);
  if (!match) return null;
  return {
    major: Number(match[1]),
    minor: Number(match[2]),
    patch: Number(match[3]),
  };
}

function isAtLeast(current, minimum) {
  if (current.major !== minimum.major) return current.major > minimum.major;
  if (current.minor !== minimum.minor) return current.minor > minimum.minor;
  return current.patch >= minimum.patch;
}

function isSupported(current) {
  return supported.some((floor) =>
    floor.orLater
      ? isAtLeast(current, floor)
      : current.major === floor.major && isAtLeast(current, floor),
  );
}

const current = parseVersion(process.version);

if (!current || !isSupported(current)) {
  console.error(
    [
      `OpenBurnBar website requires Node ${supportedRange}.`,
      `Current Node is ${process.version}.`,
      "Run `nvm use` from the repo root or website/ before running website commands.",
    ].join("\n"),
  );
  process.exit(1);
}
