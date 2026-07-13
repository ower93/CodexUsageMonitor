import Testing
@testable import CodexUsageUI

struct SessionAPICostEstimatorTests {
    @Test
    func pricesCachedInputSeparatelyFromRegularInput() throws {
        let usd = try #require(SessionAPICostEstimator.estimatedUSD(
            model: "gpt-5.5",
            inputTokens: 1_000_000,
            cachedInputTokens: 400_000,
            outputTokens: 100_000
        ))

        // 600k regular input × $5/M + 400k cached input × $0.50/M
        // + 100k output × $30/M = $6.20.
        #expect(abs(usd - 6.20) < 0.000_001)
    }

    @Test
    func clampsCachedInputToTotalInput() throws {
        let usd = try #require(SessionAPICostEstimator.estimatedUSD(
            model: "gpt-5.6-sol",
            inputTokens: 1_000_000,
            cachedInputTokens: 2_000_000,
            outputTokens: 0
        ))

        #expect(abs(usd - 0.50) < 0.000_001)
    }

    @Test
    func doesNotPriceUnknownModels() {
        let usd = SessionAPICostEstimator.estimatedUSD(
            model: "unpriced-model",
            inputTokens: 1_000_000,
            cachedInputTokens: 0,
            outputTokens: 0
        )

        #expect(usd == nil)
    }
}
