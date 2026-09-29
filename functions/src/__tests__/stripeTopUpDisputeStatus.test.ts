import { describe, expect, it } from "vitest";

import { isStripeTopUpDisputeStatus } from "@openburnbar/functions-shared/shared/stripeTopUpReversal.js";

describe("isStripeTopUpDisputeStatus", () => {
  it("accepts every dispute status the top-up reversal models", () => {
    for (const status of [
      "warning_needs_response",
      "warning_under_review",
      "warning_closed",
      "needs_response",
      "under_review",
      "won",
      "lost",
      "prevented",
    ]) {
      expect(isStripeTopUpDisputeStatus(status)).toBe(true);
    }
  });

  it("rejects a status Stripe 22's open enum can carry but the reversal does not model", () => {
    expect(isStripeTopUpDisputeStatus("some_future_status")).toBe(false);
    expect(isStripeTopUpDisputeStatus("")).toBe(false);
  });
});
