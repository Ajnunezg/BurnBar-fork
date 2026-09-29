import * as React from "react";
import { cva, type VariantProps } from "class-variance-authority";
import { cn } from "@/lib/utils";

const badgeVariants = cva(
  "inline-flex items-center gap-1.5 rounded-pill border px-2.5 py-0.5 text-xs font-medium font-mono tracking-tight",
  {
    variants: {
      tier: {
        server_readable:
          "border-tier-server-readable/40 text-tier-server-readable bg-tier-server-readable/10",
        zero_access:
          "border-tier-zero-access/40 text-tier-zero-access bg-tier-zero-access/10",
        end_to_end:
          "border-tier-end-to-end/40 text-tier-end-to-end bg-tier-end-to-end/10",
        neutral: "border-glass-line text-content-mute bg-mercury-wash",
      },
    },
    defaultVariants: { tier: "neutral" },
  },
);

export interface BadgeProps
  extends React.HTMLAttributes<HTMLSpanElement>,
    VariantProps<typeof badgeVariants> {}

export function Badge({ className, tier, ...props }: BadgeProps) {
  return <span className={cn(badgeVariants({ tier }), className)} {...props} />;
}
