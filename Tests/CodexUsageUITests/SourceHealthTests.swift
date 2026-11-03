import Foundation
import Testing
@testable import CodexUsageUI

struct SourceHealthTests {
    @Test(arguments: [
        #"{"error":{"code":-32000,"message":"401 Unauthorized: token_revoked"}}"#,
        #"{"error":{"message":"Encountered invalidated oauth token for user"}}"#,
        #"{"error":{"message":"Access token has expired"}}"#,
        #"{"error":{"message":"HTTP status: 401"}}"#,
        #"{"error":{"code":401,"message":"Request rejected"}}"#,
        #"{"error":{"message":"Request failed","data":{"httpStatusCode":401}}}"#,
        #"{"error":{"message":"Request failed","data":{"error":{"code":"token_revoked"}}}}"#,
        #"{"error":{"message":"Your refresh token was already used"}}"#
    ])
    func authenticationErrorsRequestRecovery(_ json: String) {
        #expect(CodexUsageResponseDecoder.requiresAuthenticationRecovery(responses: [.limits: Self.data(json)]))
        #expect(CodexUsageResponseDecoder.requiresAuthenticationRecovery(responses: [.account: Self.data(json)]))
        #expect(!CodexUsageResponseDecoder.requiresAuthenticationRecovery(responses: [.threads: Self.data(json)]))
    }

    @Test(arguments: [
        #"{"error":{"code":-32601,"message":"Endpoint unavailable"}}"#,
        #"{"error":{"code":429,"message":"Too many requests"}}"#,
        #"{"error":{"code":500,"message":"Internal server error"}}"#,
        #"{"error":{"code":403,"message":"Forbidden by workspace policy"}}"#,
        #"{"error":{"message":"Request 401 timed out"}}"#,
        #"{"result":{"limitName":"token_revoked Unauthorized"}}"#,
        #"{"result":null}"#,
        "not-json"
    ])
    func otherFailuresAndSuccessfulPayloadsDoNotRequestRecovery(_ json: String) {
        #expect(!CodexUsageResponseDecoder.requiresAuthenticationRecovery(responses: [.limits: Self.data(json), .account: Self.data(json)]))
    }

    static let now = Date(timeIntervalSince1970: 1_791_216_000)
    static func data(_ json: String) -> Data { Data(json.utf8) }
    static let quota = data(#"{"result":{"rateLimits":{"planType":"pro","primary":{"usedPercent":25},"secondary":null},"rateLimitResetCredits":null}}"#)
    static let account = data(#"{"result":{"summary":{"lifetimeTokens":1000},"dailyUsageBuckets":[]}}"#)
    static let threads = data(#"{"result":{"data":[]}}"#)
    static let unavailable = data(#"{"error":{"code":-32601,"message":"Endpoint unavailable"}}"#)

    @Test
    func independentSourcesAndNullMetrics() {
        let usage = CodexUsageResponseDecoder.decode(responses: [
            .limits: Self.quota,
            .account: Self.data(#"{"result":{"summary":{"lifetimeTokens":null},"dailyUsageBuckets":null}}"#),
            .threads: Self.unavailable
        ], now: Self.now)
        #expect(usage.sourceHealth[.limits]?.state == .live)
        #expect(usage.sourceHealth[.account]?.state == .live)
        #expect(usage.sourceHealth[.threads]?.state == .unavailable)
        #expect(usage.availableResetCount == nil)
        #expect(usage.lifetimeTokens == nil)
        #expect(!usage.dailyUsageAvailable)
        let snapshot = UsageSnapshot(live: usage, language: .english)
        #expect(snapshot.periods.first?.remainingPercent == 75)
        #expect(snapshot.metrics.first { $0.id == "week" }?.value == "—")
        #expect(snapshot.metrics.first { $0.id == "total" }?.value == "—")
        #expect(snapshot.updatedAt == Self.now)
    }

    @Test
    func malformedAndTimedOutSourcesDoNotDiscardSuccessfulAccount() {
        let usage = CodexUsageResponseDecoder.decode(responses: [
            .limits: Self.data("not-json"), .account: Self.account
        ], missingMessage: "Timed out", now: Self.now)
        #expect(usage.lifetimeTokens == 1000)
        #expect(usage.dailyUsageAvailable)
        #expect(usage.sourceHealth[.account]?.state == .live)
        #expect(usage.sourceHealth[.limits]?.state == .unavailable)
        #expect(usage.sourceHealth[.threads]?.state == .unavailable)
        #expect(UsageSnapshot(live: usage, language: .english).updatedAt == nil)
    }

    @Test
    func prefersMultiBucketQuotaAndPreservesWindowIdentity() {
        let usage = CodexUsageResponseDecoder.decode(responses: [.limits: Self.data(#"""
        {"result":{"rateLimits":{"primary":{"usedPercent":99}},
        "rateLimitsByLimitId":{
          "other":{"limitName":"Other models","primary":null,"secondary":{"usedPercent":5,"windowDurationMins":10080}},
          "codex":{"primary":{"usedPercent":20,"windowDurationMins":300}}
        }}}
        """#)])
        #expect(usage.rateLimitBuckets.map(\.id) == ["codex", "other"])
        let snapshot = UsageSnapshot(live: usage, language: .english)
        #expect(snapshot.periods.map(\.id) == ["codex.primary", "other.secondary"])
        #expect(snapshot.periods.map(\.remainingPercent) == [80, 95])
        #expect(snapshot.periods.last?.title == "Other models · 7-Day Limit")
    }

    @Test @MainActor
    func coldStartIsEmptyAndPreviewIsExplicit() async {
        let client = SequenceUsageClient([])
        let store = UsageStore(language: .english, client: client, apiCostEstimator: { nil })
        #expect(store.menuPercent == nil)
        #expect(store.menuText == "—")
        #expect(store.snapshot.periods.isEmpty)
        #expect(store.snapshot.recentTasks.isEmpty)
        #expect(store.snapshot.apiCostEstimate == nil)
        #expect(store.snapshot.availableResets == nil)
        #expect(store.snapshot.updatedAt == nil)
        await store.refreshLive()
        #expect(store.sourceHealth[.limits]?.state == .unavailable)
        #expect(store.snapshot.metrics.allSatisfy { $0.value == "—" })
        #expect(!store.statusText.contains("Demo"))
        let preview = UsageStore(previewOnly: true, language: .english, client: client,
                                 apiCostEstimator: { nil })
        #expect(preview.sourceHealth[.limits]?.state == .demo)
        #expect(!preview.snapshot.periods.isEmpty)
        #expect(preview.statusText.contains("Demo"))
    }

    @Test @MainActor
    func partialFailureKeepsStaleValuesAndOriginalFreshness() async throws {
        let good = CodexUsageResponseDecoder.decode(responses: [
            .limits: Self.quota, .account: Self.account, .threads: Self.threads
        ], now: Self.now)
        let partial = CodexUsageResponseDecoder.decode(responses: [
            .limits: Self.unavailable,
            .account: Self.data(#"{"result":{"summary":{"lifetimeTokens":2000},"dailyUsageBuckets":[]}}"#),
            .threads: Self.threads
        ], now: Self.now.addingTimeInterval(60))
        let suite = "SourceHealthTests-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let client = SequenceUsageClient([good, partial])
        let estimate = CodexAPICostEstimate(currentWeekUSD: 1, lifetimeUSD: 2, pricedTokens: 10,
                                           observedTokens: 10, modelNames: [])
        let store = UsageStore(language: .english, client: client, apiCostEstimator: { estimate }, defaults: defaults)
        await store.refreshLive()
        await store.refreshLive()
        #expect(store.menuText == "75% !")
        #expect(store.sourceHealth[.limits]?.state == .stale)
        #expect(store.sourceHealth[.account]?.state == .live)
        #expect(store.snapshot.metrics.last?.value == "2.0K")
        #expect(store.snapshot.updatedAt == Self.now)
        await store.refreshAPICost()
        store.setLanguage(.simplifiedChinese)
        #expect(store.snapshot.updatedAt == Self.now)
        #expect(store.snapshot.apiCostEstimate?.lifetimeUSD == 2)
        // A transport failure retains prior source data and never manufactures a new success time.
        await store.refreshLive()
        #expect(store.sourceHealth[.account]?.state == .stale)
        #expect(store.snapshot.updatedAt == Self.now)
        await store.shutdown()
    }
}

private actor SequenceUsageClient: CodexUsageFetching {
    private var values: [CodexLiveUsage]
    init(_ values: [CodexLiveUsage]) { self.values = values }
    func fetchUsage(apiCostEstimate: CodexAPICostEstimate?) async throws -> CodexLiveUsage {
        guard !values.isEmpty else { throw CodexUsageClientError.connectionClosed }
        return values.removeFirst()
    }
    func shutdown() async {}
}
