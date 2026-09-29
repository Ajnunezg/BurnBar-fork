import GRDB

extension OpenBurnBarDatabase {
    /// v71: pricing provenance on `token_usage`.
    ///
    /// `pricingSource` records where a row's dollars came from — a rate the
    /// catalog lists (`catalog`), the fallback table because none is listed
    /// (`fallback`), a figure the source reported (`reported`) — and
    /// `tokenConfidence` the confidence of its token counts alone. A
    /// fallback-priced row's `provenanceConfidence` is capped at
    /// `low_confidence_estimate`; the upsert precedence ladder compares
    /// `tokenConfidence` instead, so a pricing estimate never decides which
    /// token counts win.
    ///
    /// Additive: rows written before v71 read `unknown` and a NULL
    /// `tokenConfidence` (the ladder falls back to `provenanceConfidence`,
    /// which for those rows is the token confidence). They are restamped the
    /// next time their source is parsed.
    static func registerUsagePricingProvenanceMigration(on migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v71_token_usage_pricing_provenance") { db in
            try db.alter(table: "token_usage") { t in
                t.add(column: "pricingSource", .text).notNull().defaults(to: "unknown")
                t.add(column: "tokenConfidence", .text)
            }
        }
    }
}
