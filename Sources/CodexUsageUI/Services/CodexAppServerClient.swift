import Foundation

struct CodexAppServerClient: Sendable {
    func fetchUsage() async throws -> CodexLiveUsage {
        try await Task.detached(priority: .userInitiated) {
            try Self.fetchUsageSynchronously()
        }.value
    }

    private static func fetchUsageSynchronously() throws -> CodexLiveUsage {
        let executable = try resolveCodexExecutable()
        let process = Process()
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let errorPipe = Pipe()

        process.executableURL = executable
        process.arguments = ["app-server", "--stdio"]
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        do {
            try process.run()
        } catch {
            throw CodexUsageClientError.launchFailed
        }

        let messages: [[String: Any]] = [
            [
                "id": 1,
                "method": "initialize",
                "params": [
                    "clientInfo": [
                        "name": "codex-usage-monitor",
                        "title": "Codex Usage Monitor",
                        "version": "1.0.0"
                    ],
                    "capabilities": [
                        "experimentalApi": true,
                        "requestAttestation": false
                    ]
                ]
            ],
            ["method": "initialized"],
            ["id": 2, "method": "account/rateLimits/read"],
            ["id": 3, "method": "account/usage/read"],
            [
                "id": 4,
                "method": "thread/list",
                "params": [
                    "limit": 3,
                    "sortKey": "updated_at",
                    "sortDirection": "desc",
                    "useStateDbOnly": true
                ]
            ]
        ]

        let inputData = try messages.reduce(into: Data()) { data, message in
            data.append(try JSONSerialization.data(withJSONObject: message))
            data.append(0x0A)
        }
        inputPipe.fileHandleForWriting.write(inputData)

        var rateLimits: RateLimitsResult?
        var accountUsage: AccountUsageResult?
        var threadList: ThreadListResult?
        let decoder = JSONDecoder()

        while rateLimits == nil || accountUsage == nil || threadList == nil {
            guard let line = readLine(from: outputPipe.fileHandleForReading) else { break }
            guard
                let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                let id = (object["id"] as? NSNumber)?.intValue
            else { continue }

            switch id {
            case 2:
                let envelope = try decoder.decode(RPCEnvelope<RateLimitsResult>.self, from: line)
                try envelope.throwIfNeeded()
                rateLimits = envelope.result
            case 3:
                let envelope = try decoder.decode(RPCEnvelope<AccountUsageResult>.self, from: line)
                try envelope.throwIfNeeded()
                accountUsage = envelope.result
            case 4:
                let envelope = try decoder.decode(RPCEnvelope<ThreadListResult>.self, from: line)
                try envelope.throwIfNeeded()
                threadList = envelope.result
            default:
                continue
            }
        }

        try? inputPipe.fileHandleForWriting.close()
        if process.isRunning {
            process.terminate()
        }
        process.waitUntilExit()
        let errors = errorPipe.fileHandleForReading.readDataToEndOfFile()

        guard let rateLimits else {
            let detail = String(data: errors, encoding: .utf8) ?? ""
            throw CodexUsageClientError.missingRateLimits(detail)
        }
        guard let accountUsage else {
            throw CodexUsageClientError.missingAccountUsage
        }

        let threads = (threadList?.data ?? []).map { thread in
            CodexThreadUsage(
                id: thread.id,
                title: thread.displayTitle,
                updatedAt: Date(timeIntervalSince1970: thread.updatedAt),
                totalTokens: SessionTokenReader.latestTotalTokens(at: thread.path)
            )
        }
        let apiCostEstimate = SessionAPICostEstimator.estimate()

        return CodexLiveUsage(
            rateLimits: CodexRateLimitSnapshot(
                planType: rateLimits.rateLimits.planType,
                primary: rateLimits.rateLimits.primary?.liveValue,
                secondary: rateLimits.rateLimits.secondary?.liveValue
            ),
            availableResetCount: rateLimits.rateLimitResetCredits?.availableCount ?? 0,
            lifetimeTokens: accountUsage.summary.lifetimeTokens,
            dailyUsage: (accountUsage.dailyUsageBuckets ?? []).map {
                CodexDailyUsage(startDate: $0.startDate, tokens: $0.tokens)
            },
            recentThreads: threads,
            apiCostEstimate: apiCostEstimate
        )
    }

    private static func resolveCodexExecutable() throws -> URL {
        let candidates = [
            "/Applications/Codex.app/Contents/Resources/codex",
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex"
        ]
        if let path = candidates.first(where: FileManager.default.isExecutableFile(atPath:)) {
            return URL(fileURLWithPath: path)
        }
        throw CodexUsageClientError.executableNotFound
    }

    private static func readLine(from handle: FileHandle) -> Data? {
        var line = Data()
        while true {
            let byte = handle.readData(ofLength: 1)
            if byte.isEmpty {
                return line.isEmpty ? nil : line
            }
            if byte[byte.startIndex] == 0x0A {
                return line
            }
            line.append(byte)
        }
    }
}

private enum CodexUsageClientError: LocalizedError {
    case executableNotFound
    case launchFailed
    case server(String)
    case missingRateLimits(String)
    case missingAccountUsage

    var errorDescription: String? {
        switch self {
        case .executableNotFound:
            "未找到 Codex 应用"
        case .launchFailed:
            "无法启动 Codex 用量服务"
        case .server(let message):
            "Codex 返回错误：\(message)"
        case .missingRateLimits:
            "未读取到 Codex 限额"
        case .missingAccountUsage:
            "未读取到账户 token 用量"
        }
    }
}

private struct RPCEnvelope<Result: Decodable>: Decodable {
    let result: Result?
    let error: RPCError?

    func throwIfNeeded() throws {
        if let error {
            throw CodexUsageClientError.server(error.message)
        }
    }
}

private struct RPCError: Decodable {
    let message: String
}

private struct RateLimitsResult: Decodable {
    let rateLimits: RateLimitSnapshotResponse
    let rateLimitResetCredits: ResetCreditsResponse?
}

private struct RateLimitSnapshotResponse: Decodable {
    let primary: RateLimitWindowResponse?
    let secondary: RateLimitWindowResponse?
    let planType: String?
}

private struct RateLimitWindowResponse: Decodable {
    let usedPercent: Double
    let windowDurationMins: Int?
    let resetsAt: TimeInterval?

    var liveValue: CodexRateLimitWindow {
        CodexRateLimitWindow(
            usedPercent: usedPercent,
            windowDurationMinutes: windowDurationMins,
            resetsAt: resetsAt.map(Date.init(timeIntervalSince1970:))
        )
    }
}

private struct ResetCreditsResponse: Decodable {
    let availableCount: Int
}

private struct AccountUsageResult: Decodable {
    let summary: AccountUsageSummaryResponse
    let dailyUsageBuckets: [DailyUsageResponse]?
}

private struct AccountUsageSummaryResponse: Decodable {
    let lifetimeTokens: Int64?
}

private struct DailyUsageResponse: Decodable {
    let startDate: String
    let tokens: Int64
}

private struct ThreadListResult: Decodable {
    let data: [ThreadResponse]
}

private struct ThreadResponse: Decodable {
    let id: String
    let preview: String
    let updatedAt: TimeInterval
    let path: String?
    let name: String?

    var displayTitle: String {
        let candidate = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallback = preview.trimmingCharacters(in: .whitespacesAndNewlines)
        let value = (candidate?.isEmpty == false ? candidate : nil) ?? fallback
        if value.count <= 24 { return value }
        return String(value.prefix(23)) + "…"
    }
}

private enum SessionTokenReader {
    static func latestTotalTokens(at path: String?) -> Int64? {
        guard let path, let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }

        do {
            let end = try handle.seekToEnd()
            let bytesToRead = min(end, 2_000_000)
            try handle.seek(toOffset: end - bytesToRead)
            let data = try handle.readToEnd() ?? Data()
            for rawLine in data.split(separator: 0x0A).reversed() {
                guard
                    let object = try? JSONSerialization.jsonObject(with: Data(rawLine)) as? [String: Any],
                    let type = object["type"] as? String,
                    type == "event_msg",
                    let payload = object["payload"] as? [String: Any],
                    payload["type"] as? String == "token_count",
                    let info = payload["info"] as? [String: Any],
                    let total = info["total_token_usage"] as? [String: Any],
                    let tokens = total["total_tokens"] as? NSNumber
                else { continue }
                return tokens.int64Value
            }
        } catch {
            return nil
        }
        return nil
    }
}
