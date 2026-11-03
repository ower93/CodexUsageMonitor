import Foundation
import Testing
@testable import CodexUsageUI

struct PricingCatalogTests {
    @Test
    func bundledCatalogIsValidAndIncludesCurrentModels() throws {
        let catalog = try #require(PricingCatalog.bundled)
        #expect(catalog.verifiedAt == "2026-10-06")
        for (id, expected) in [
            ("gpt-6.1-sol", [2.0, 0.1, 10.0]),
            ("gpt-6-sol", [2.0, 0.2, 10.0]),
            ("gpt-6-luna", [0.1, 0.01, 0.5])
        ] {
            let price = try #require(catalog.price(for: id))
            #expect([price.inputPerMillion, price.cachedInputPerMillion, price.outputPerMillion] == expected)
            #expect(catalog.price(for: id + "-2026-10-01") == price)
            #expect(catalog.price(for: id + "-pro") == nil)
        }
    }

    @Test
    func rejectsDuplicateIDsNegativeRatesAndUnexpectedSources() throws {
        let valid = try #require(PricingCatalog.bundled)
        let entry = try #require(valid.entries.first)
        let duplicate = PricingCatalog(schemaVersion: 1, revision: 2, verifiedAt: "2026-10-06",
                                       sourceURL: valid.sourceURL, basis: valid.basis, entries: [entry, entry])
        #expect(throws: (any Error).self) { try PricingCatalog.decodeValidated(JSONEncoder().encode(duplicate)) }
        let negative = PricingCatalog.Entry(modelID: "bad", price: APIModelPrice(
            version: "test", displayName: "Bad", inputPerMillion: -1, cachedInputPerMillion: 0, outputPerMillion: 1))
        let invalid = PricingCatalog(schemaVersion: 1, revision: 2, verifiedAt: "2026-10-06",
                                     sourceURL: valid.sourceURL, basis: valid.basis, entries: [negative])
        #expect(throws: (any Error).self) { try PricingCatalog.decodeValidated(JSONEncoder().encode(invalid)) }
        let untrusted = PricingCatalog(schemaVersion: 1, revision: 2, verifiedAt: "2026-10-06",
                                       sourceURL: "https://example.com", basis: valid.basis, entries: [entry])
        #expect(throws: (any Error).self) { try PricingCatalog.decodeValidated(JSONEncoder().encode(untrusted)) }
    }
}
