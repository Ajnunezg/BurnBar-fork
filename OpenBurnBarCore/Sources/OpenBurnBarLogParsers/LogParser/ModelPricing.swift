import Foundation

import OpenBurnBarKernel

public enum ModelPricingError: Error, Sendable {
    case domainCoreRejected
}

public struct ModelPricing: Sendable {
    public let inputPerMToken: Double
    public let outputPerMToken: Double
    public let cacheCreationPerMToken: Double?
    public let cacheReadPerMToken: Double
    /// `.catalog` when these are rates the catalog lists for the model;
    /// `.fallback` when the model is unknown or its catalog entry lists no
    /// rate and these are the default rates. Stamp it on the usage row as
    /// `pricingSource` so an estimated dollar figure is never shown as exact.
    public let source: UsagePricingSource

    public init(
        inputPerMToken: Double,
        outputPerMToken: Double,
        cacheReadPerMToken: Double
    ) {
        self.init(
            inputPerMToken: inputPerMToken,
            outputPerMToken: outputPerMToken,
            cacheReadPerMToken: cacheReadPerMToken,
            cacheCreationPerMToken: nil
        )
    }

    public init(
        inputPerMToken: Double,
        outputPerMToken: Double,
        cacheReadPerMToken: Double,
        cacheCreationPerMToken: Double?,
        source: UsagePricingSource = .catalog
    ) {
        self.inputPerMToken = inputPerMToken
        self.outputPerMToken = outputPerMToken
        self.cacheCreationPerMToken = cacheCreationPerMToken
        self.cacheReadPerMToken = cacheReadPerMToken
        self.source = source
    }

    /// The model's listed catalog rate, or the default rates marked
    /// `.fallback` — never silently: callers stamp `source` on the row.
    public static func lookup(model: String, providerID: String? = nil) -> ModelPricing {
        let normalizedModel = TokenExtractionUtility.normalizeModelName(model)
        #if canImport(OpenBurnBarKernel)
        guard let catalogModel = OpenBurnBarCatalogLookup.shared.pricedModel(
            forModelName: normalizedModel,
            providerID: providerID
        ), catalogModel.hasListedPricing else {
            return ModelPricing(.defaultFallback, source: .fallback)
        }
        return ModelPricing(catalogModel.pricing, source: .catalog)
        #else
        return .fallback
        #endif
    }

    /// True only when the catalog lists a rate for the model; a catalog entry
    /// without a pricing block does not count.
    public static func hasCatalogPricing(model: String, providerID: String? = nil) -> Bool {
        lookup(model: model, providerID: providerID).source == .catalog
    }

    public func cost(
        inputTokens: Int,
        outputTokens: Int,
        cacheCreationTokens: Int = 0,
        cacheReadTokens: Int = 0,
        reasoningTokens: Int = 0
    ) throws -> Double {
        guard let cost = DomainCorePricingAdapter.cost(
            inputPerMToken: inputPerMToken,
            outputPerMToken: outputPerMToken,
            cacheCreationPerMToken: cacheCreationPerMToken,
            cacheReadPerMToken: cacheReadPerMToken,
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            cacheCreationTokens: cacheCreationTokens,
            cacheReadTokens: cacheReadTokens,
            environment: DomainCorePricingAdapter.runtimeEnvironment,
            legacy: {
                let cacheCreationRate = cacheCreationPerMToken ?? inputPerMToken
                return Double(inputTokens) / 1_000_000 * inputPerMToken
                    + Double(outputTokens) / 1_000_000 * outputPerMToken
                    + Double(cacheCreationTokens) / 1_000_000 * cacheCreationRate
                    + Double(cacheReadTokens) / 1_000_000 * cacheReadPerMToken
            }
        ) else {
            throw ModelPricingError.domainCoreRejected
        }
        return cost
    }
}

private extension ModelPricing {
    #if canImport(OpenBurnBarKernel)
    init(_ pricing: BurnBarModelPricing, source: UsagePricingSource) {
        self.init(
            inputPerMToken: pricing.inputPerMToken,
            outputPerMToken: pricing.outputPerMToken,
            cacheReadPerMToken: pricing.cacheReadPerMToken,
            cacheCreationPerMToken: pricing.cacheCreationPerMToken,
            source: source
        )
    }
    #endif

    static let fallback = ModelPricing(
        inputPerMToken: 2.5,
        outputPerMToken: 10,
        cacheReadPerMToken: 1.25,
        cacheCreationPerMToken: nil,
        source: .fallback
    )
}

private struct OpenBurnBarCatalogLookup {
    static let shared = OpenBurnBarCatalogLookup()

    #if canImport(OpenBurnBarKernel)
    private let catalog: BurnBarCatalog?
    #endif

    private init() {
        #if canImport(OpenBurnBarKernel)
        self.catalog = try? BurnBarCatalogLoader.loadBundledCatalog() // try?-ok(catalog load has fallback)
        #endif
    }

    #if canImport(OpenBurnBarKernel)
    func pricedModel(forModelName modelName: String, providerID: String? = nil) -> BurnBarCatalogModel? {
        guard let catalog else { return nil }
        if let providerID, let providerModel = catalog.pricedModel(forModelName: modelName, providerID: providerID) {
            return providerModel
        }
        return catalog.pricedModel(forModelName: modelName)
    }
    #endif
}
