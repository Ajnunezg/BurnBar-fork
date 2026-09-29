import assert from "node:assert/strict";
import test from "node:test";

import { assertOfficialLibsignalReady } from "./index.js";

test("official libsignal client loads with the pinned Signal Protocol surface", () => {
  assert.equal(assertOfficialLibsignalReady().ok, true);
});
