import CryptoKit
import Foundation

enum AnalyticsExport {
    static func privateChatName(_ id: String) -> String {
        let digest = SHA256.hash(data: Data(id.utf8)).prefix(4).map { String(format: "%02x", $0) }.joined()
        return "Chat " + digest
    }

    static func csv(_ result: AnalyticsResult, data: AnalyticsData, privacy: Bool = true) -> String {
        var lines = [["date", "chat", "model", "input_tokens", "cached_input_tokens", "output_tokens", "total_tokens",
                      "estimated_usd", "price_version", "input_per_million", "cached_per_million", "output_per_million",
                      "backfill_date", "status"].joined(separator: ",")]
        for row in result.records {
            let r = row.value
            let values = [r.usageDay, privacy ? privateChatName(r.sessionID) : AnalyticsEngine.title(for: r.sessionID, in: data),
                r.model, String(r.counts.inputTokens), String(r.counts.cachedInputTokens), String(r.counts.outputTokens),
                String(r.counts.totalTokens), r.price != nil ? String(format: "%.8f", r.usd) : "",
                r.price?.version ?? "", r.price.map { String($0.inputPerMillion) } ?? "",
                r.price.map { String($0.cachedInputPerMillion) } ?? "", r.price.map { String($0.outputPerMillion) } ?? "",
                r.pricingBackfill?.appliedAt ?? "", r.accountingNote ?? (r.price == nil ? "unpriced-model" : "estimated-api-equivalent")]
            lines.append(values.map(escape).joined(separator: ","))
        }
        return lines.joined(separator: "\r\n") + "\r\n"
    }

    private static func escape(_ value: String) -> String {
        // Prevent spreadsheet formula execution from an untrusted chat title.
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let safe = ["=", "+", "-", "@"].contains(where: { trimmed.hasPrefix($0) }) ? "'" + value : value
        return "\"" + safe.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}
