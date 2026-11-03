import Foundation

/// Catalog metadata is separate from frozen ledger snapshots. Loading a newer
/// catalog must never edit a previously recorded price or amount.
struct PricingCatalog: Codable, Sendable {
    let schemaVersion: Int
    let revision: Int
    let verifiedAt: String
    let sourceURL: String
    let basis: String
    let entries: [Entry]

    struct Entry: Codable, Sendable {
        let modelID: String
        let price: APIModelPrice
    }

    static let bundled: PricingCatalog? = {
        guard let url = Bundle.module.url(forResource: "pricing-catalog", withExtension: "json"),
              let data = try? Data(contentsOf: url)
        else { return nil }
        return try? decodeValidated(data)
    }()

    static func decodeValidated(_ data: Data) throws -> PricingCatalog {
        let catalog = try JSONDecoder().decode(Self.self, from: data)
        guard catalog.schemaVersion == 1, catalog.revision > 0,
              AnalyticsFilter.date(catalog.verifiedAt, Calendar(identifier: .gregorian)) != nil,
              catalog.sourceURL == APIModelPrice.pricingSourceURL,
              !catalog.entries.isEmpty,
              Set(catalog.entries.map(\.modelID)).count == catalog.entries.count,
              catalog.entries.allSatisfy({ entry in
                  !entry.modelID.isEmpty && entry.modelID == entry.modelID.lowercased()
                      && !entry.price.version.isEmpty
                      && [entry.price.inputPerMillion, entry.price.cachedInputPerMillion,
                          entry.price.outputPerMillion].allSatisfy { $0.isFinite && $0 >= 0 }
              })
        else { throw CatalogError.invalidCatalog }
        return catalog
    }

    func price(for rawModel: String) -> APIModelPrice? {
        let model = rawModel.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return entries.first { entry in
            if model == entry.modelID { return true }
            let prefix = entry.modelID + "-"
            guard model.hasPrefix(prefix) else { return false }
            let suffix = String(model.dropFirst(prefix.count))
            // Do not accidentally price a new tier (pro/fast/mini/etc.) as the
            // base model. Only canonical IDs and explicit dated snapshots match.
            return AnalyticsFilter.date(suffix, Calendar(identifier: .gregorian)) != nil
        }?.price
    }

    enum CatalogError: Error { case invalidCatalog }
}
