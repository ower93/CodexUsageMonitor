import CryptoKit
import Foundation

/// Signed catalog imports are optional and fail closed when the distributor
/// has not pinned a public key. The private signing key is never in the app.
final class PricingCatalogStore: @unchecked Sendable {
    static let shared = PricingCatalogStore()
    struct Envelope: Codable {
        let payloadBase64: String
        let signatureBase64: String
    }
    enum Failure: Error { case notConfigured, invalidSignature, rollback, invalidVersion, tooLarge }
    private let lock = NSLock()
    private let cacheURL: URL
    private let publicKey: Data?
    private let defaults: UserDefaults
    private var current: PricingCatalog?
    private var highWater: Int
    private var cachedUpdate = false
    private var cacheRejected = false

    init(cacheURL: URL = APICostLedgerStore.defaultURL.deletingLastPathComponent().appendingPathComponent("signed-pricing-catalog.json"),
         publicKey: Data? = (Bundle.main.object(forInfoDictionaryKey: "CUMCatalogPublicKey") as? String).flatMap { Data(base64Encoded: $0) },
         bundled: PricingCatalog? = .bundled, defaults: UserDefaults = .standard) {
        self.cacheURL = cacheURL
        self.publicKey = publicKey
        self.defaults = defaults
        current = bundled
        highWater = max(bundled?.revision ?? 0, defaults.integer(forKey: "pricing.catalog.highWater"))
        if publicKey != nil, let data = try? Data(contentsOf: cacheURL) {
            do {
                let catalog = try verify(data)
                guard catalog.revision >= highWater else { throw Failure.rollback }
                current = catalog
                highWater = catalog.revision
                cachedUpdate = true
            } catch { cacheRejected = true }
        }
    }

    var catalog: PricingCatalog? { lock.lock(); defer { lock.unlock() }; return current }
    var updatesConfigured: Bool { publicKey?.count == 32 }
    var status: String {
        lock.lock(); defer { lock.unlock() }
        if cacheRejected { return "bundled-fallback-cache-rejected" }
        return cachedUpdate ? "verified-signed-cache" : "bundled-offline"
    }

    /// The whole envelope is atomically replaced only after signature, schema,
    /// monotonic revision and changed-rate version checks all pass.
    func install(_ data: Data) throws {
        lock.lock(); defer { lock.unlock() }
        let candidate = try verify(data)
        guard candidate.revision > highWater else { throw Failure.rollback }
        for entry in candidate.entries {
            if let old = current?.entries.first(where: { $0.modelID == entry.modelID })?.price,
               old != entry.price, old.version == entry.price.version { throw Failure.invalidVersion }
        }
        try FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: cacheURL, options: .atomic)
        defaults.set(candidate.revision, forKey: "pricing.catalog.highWater")
        highWater = candidate.revision
        current = candidate
        cachedUpdate = true
        cacheRejected = false
    }

    private func verify(_ data: Data) throws -> PricingCatalog {
        guard data.count <= 512 * 1024 else { throw Failure.tooLarge }
        guard let publicKey, publicKey.count == 32 else { throw Failure.notConfigured }
        let envelope = try JSONDecoder().decode(Envelope.self, from: data)
        guard let payload = Data(base64Encoded: envelope.payloadBase64), payload.count <= 256 * 1024,
              let signature = Data(base64Encoded: envelope.signatureBase64), signature.count == 64,
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: publicKey),
              key.isValidSignature(signature, for: payload)
        else { throw Failure.invalidSignature }
        return try PricingCatalog.decodeValidated(payload)
    }
}
