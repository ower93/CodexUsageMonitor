import CryptoKit
import Foundation
import Testing
@testable import CodexUsageUI

struct SignedCatalogTests {
    @Test
    func verifiesSignaturePersistsOfflineAndRejectsRollbackAndTampering() throws {
        let key = Curve25519.Signing.PrivateKey()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let name = "catalog-test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { try? FileManager.default.removeItem(at: directory); defaults.removePersistentDomain(forName: name) }
        let url = directory.appendingPathComponent("catalog.json")
        let bundle = try #require(PricingCatalog.bundled)
        let store = PricingCatalogStore(cacheURL: url, publicKey: key.publicKey.rawRepresentation, bundled: bundle, defaults: defaults)
        let catalog = PricingCatalog(schemaVersion: 1, revision: bundle.revision + 1, verifiedAt: "2026-10-06",
            sourceURL: bundle.sourceURL, basis: bundle.basis, entries: bundle.entries)
        let payload = try JSONEncoder().encode(catalog)
        let signed = try JSONEncoder().encode(PricingCatalogStore.Envelope(payloadBase64: payload.base64EncodedString(),
            signatureBase64: key.signature(for: payload).base64EncodedString()))
        try store.install(signed)
        #expect(store.catalog?.revision == catalog.revision)
        #expect(store.status == "verified-signed-cache")
        #expect(throws: PricingCatalogStore.Failure.self) { try store.install(signed) }
        let offline = PricingCatalogStore(cacheURL: url, publicKey: key.publicKey.rawRepresentation, bundled: bundle, defaults: defaults)
        #expect(offline.catalog?.revision == catalog.revision)
        var altered = payload
        altered.append(32)
        let invalid = try JSONEncoder().encode(PricingCatalogStore.Envelope(payloadBase64: altered.base64EncodedString(),
            signatureBase64: key.signature(for: payload).base64EncodedString()))
        #expect(throws: PricingCatalogStore.Failure.self) { try store.install(invalid) }
        #expect(try Data(contentsOf: url) == signed)
        let notConfigured = PricingCatalogStore(cacheURL: url, publicKey: nil, bundled: bundle, defaults: defaults)
        #expect(!notConfigured.updatesConfigured)
        #expect(notConfigured.catalog?.revision == bundle.revision)
        #expect(throws: PricingCatalogStore.Failure.self) { try notConfigured.install(signed) }

        let original = bundle.entries[0].price
        var entries = bundle.entries
        entries[0] = PricingCatalog.Entry(modelID: entries[0].modelID,
            price: APIModelPrice(version: original.version, displayName: original.displayName,
                inputPerMillion: original.inputPerMillion + 1,
                cachedInputPerMillion: original.cachedInputPerMillion, outputPerMillion: original.outputPerMillion))
        let changed = PricingCatalog(schemaVersion: 1, revision: catalog.revision + 1,
            verifiedAt: catalog.verifiedAt, sourceURL: catalog.sourceURL, basis: catalog.basis, entries: entries)
        let changedPayload = try JSONEncoder().encode(changed)
        let changedEnvelope = try JSONEncoder().encode(PricingCatalogStore.Envelope(
            payloadBase64: changedPayload.base64EncodedString(), signatureBase64: key.signature(for: changedPayload).base64EncodedString()))
        #expect(throws: PricingCatalogStore.Failure.self) { try store.install(changedEnvelope) }
        #expect(try Data(contentsOf: url) == signed)

        try Data("corrupted-cache".utf8).write(to: url)
        let fallback = PricingCatalogStore(cacheURL: url, publicKey: key.publicKey.rawRepresentation, bundled: bundle, defaults: defaults)
        #expect(fallback.status == "bundled-fallback-cache-rejected")
        #expect(fallback.catalog?.revision == bundle.revision)
        #expect(throws: PricingCatalogStore.Failure.self) { try fallback.install(signed) }
    }
}
