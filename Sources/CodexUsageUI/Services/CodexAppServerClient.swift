import Darwin
import Foundation

final class CodexAppServerClient: @unchecked Sendable {
    private let queue = DispatchQueue(
        label: "com.kevinchen.CodexUsageMonitor.app-server",
        qos: .utility
    )
    private let stateLock = NSLock()
    private let executableURL: URL?
    private let responseTimeout: TimeInterval
    private let shutdownTimeout: TimeInterval
    private var session: CodexAppServerSession?
    private var isShuttingDown = false
    private var quotaChangeHandler: (@Sendable () -> Void)?

    func setQuotaChangeHandler(_ handler: (@Sendable () -> Void)?) {
        stateLock.lock()
        quotaChangeHandler = handler
        stateLock.unlock()
    }

    private func quotaChanged() {
        stateLock.lock()
        let callback = isShuttingDown ? nil : quotaChangeHandler
        stateLock.unlock()
        callback?()
    }

    init(
        executableURL: URL? = nil,
        responseTimeout: TimeInterval = 12,
        shutdownTimeout: TimeInterval = 2
    ) {
        // An explicit override must fail visibly if invalid; silently falling
        // back could connect to a different installation/account than intended.
        self.executableURL = executableURL ?? CodexEnvironment.executableOverride()
        self.responseTimeout = responseTimeout
        self.shutdownTimeout = shutdownTimeout
    }

    func fetchUsage(apiCostEstimate: CodexAPICostEstimate?) async throws -> CodexLiveUsage {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                do {
                    guard !shuttingDown else {
                        throw CodexUsageClientError.shuttingDown
                    }
                    continuation.resume(returning: try fetchUsageSynchronously(
                        apiCostEstimate: apiCostEstimate
                    ))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func shutdown() async {
        let activeSession = beginShutdown()
        if let activeSession {
            await Task.detached(priority: .userInitiated) {
                activeSession.shutdown()
            }.value
        }

        // Drain the request queue after interrupting the active process. This
        // covers the narrow race where a request has launched a process but
        // has not published the session yet when shutdown begins.
        await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume()
            }
        }
    }

    private func fetchUsageSynchronously(
        apiCostEstimate: CodexAPICostEstimate?
    ) throws -> CodexLiveUsage {
        var lastError: Error?
        var authenticationFailureUsage: CodexLiveUsage?
        for attempt in 0..<2 {
            var attemptedSession: CodexAppServerSession?
            do {
                guard !shuttingDown else {
                    throw CodexUsageClientError.shuttingDown
                }
                let currentSession = try sessionForRequest()
                attemptedSession = currentSession
                let result = try currentSession.fetchUsage(apiCostEstimate: apiCostEstimate)
                guard !shuttingDown else {
                    throw CodexUsageClientError.shuttingDown
                }
                if result.requiresAuthenticationRecovery {
                    // RPC errors are valid transport responses. Do not keep a
                    // live helper whose in-memory credentials were revoked.
                    // Restart from the configured path to load current Codex
                    // credentials/binary, without changing authentication files.
                    authenticationFailureUsage = result.usage
                    discardSession(currentSession)
                    currentSession.shutdown()
                    if attempt == 0 {
                        UsageTelemetry.connection.notice("Authentication rejected; reconnecting app-server once")
                        continue
                    }
                    UsageTelemetry.connection.error("Authentication retry exhausted; preserving per-source failure state")
                } else if authenticationFailureUsage != nil {
                    UsageTelemetry.connection.notice("Authentication retry completed")
                }
                guard !shuttingDown else { throw CodexUsageClientError.shuttingDown }
                return result.usage
            } catch {
                lastError = error
                if let attemptedSession {
                    discardSession(attemptedSession)
                    attemptedSession.shutdown()
                }
                if shuttingDown {
                    throw CodexUsageClientError.shuttingDown
                }
                if error is CancellationError { throw error }
                if attempt == 1 {
                    // A failed reconnect must not discard an account/thread
                    // response already obtained before the authentication retry.
                    if let authenticationFailureUsage {
                        UsageTelemetry.connection.error("Authentication reconnect failed; retaining successful partial responses")
                        return authenticationFailureUsage
                    }
                    throw error
                }
            }
        }
        throw lastError ?? CodexUsageClientError.connectionClosed
    }

    private func sessionForRequest() throws -> CodexAppServerSession {
        if let currentSession {
            return currentSession
        }
        guard !shuttingDown else {
            throw CodexUsageClientError.shuttingDown
        }

        let newSession = try CodexAppServerSession(
            executable: try executableURL ?? Self.resolveCodexExecutable(),
            responseTimeout: responseTimeout,
            shutdownTimeout: shutdownTimeout,
            quotaChanged: { [weak self] in self?.quotaChanged() }
        )
        guard publishSession(newSession) else {
            newSession.shutdown()
            throw CodexUsageClientError.shuttingDown
        }
        UsageTelemetry.connection.info("Created one app-server session")

        do {
            try newSession.initialize()
            return newSession
        } catch {
            discardSession(newSession)
            newSession.shutdown()
            throw error
        }
    }

    private var currentSession: CodexAppServerSession? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return session
    }

    private var shuttingDown: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return isShuttingDown
    }

    private func publishSession(_ candidate: CodexAppServerSession) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard !isShuttingDown else { return false }
        session = candidate
        return true
    }

    private func discardSession(_ candidate: CodexAppServerSession) {
        stateLock.lock()
        defer { stateLock.unlock() }
        if session === candidate {
            session = nil
        }
    }

    private func beginShutdown() -> CodexAppServerSession? {
        stateLock.lock()
        defer { stateLock.unlock() }
        isShuttingDown = true
        let activeSession = session
        session = nil
        return activeSession
    }

    static var defaultCodexExecutableCandidates: [URL] {
        let applications = [
            URL(fileURLWithPath: "/Applications/Codex.app", isDirectory: true),
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Applications/Codex.app", isDirectory: true)
        ]
        return applications.flatMap { app in
            [
                app.appendingPathComponent(
                    "Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex"
                ),
                app.appendingPathComponent("Contents/Resources/codex")
            ]
        } + [
            URL(fileURLWithPath: "/opt/homebrew/bin/codex"),
            URL(fileURLWithPath: "/usr/local/bin/codex")
        ]
    }

    static func resolveCodexExecutable(candidates: [URL]? = nil) throws -> URL {
        let fileManager = FileManager.default
        for candidate in candidates ?? defaultCodexExecutableCandidates {
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: candidate.path, isDirectory: &isDirectory),
                  !isDirectory.boolValue,
                  fileManager.isExecutableFile(atPath: candidate.path)
            else { continue }
            return candidate
        }
        throw CodexUsageClientError.executableNotFound
    }
}

protocol CodexUsageFetching: Sendable {
    func fetchUsage(apiCostEstimate: CodexAPICostEstimate?) async throws -> CodexLiveUsage
    func shutdown() async
    func setQuotaChangeHandler(_ handler: (@Sendable () -> Void)?)
}

extension CodexUsageFetching {
    func setQuotaChangeHandler(_ handler: (@Sendable () -> Void)?) {}
}

extension CodexAppServerClient: CodexUsageFetching {}

private struct CodexUsageFetchResult {
    let usage: CodexLiveUsage
    let requiresAuthenticationRecovery: Bool
}

private final class CodexAppServerSession: @unchecked Sendable {
    private let process: Process
    private let inputHandle: FileHandle
    private let outputReader: SessionOutputReader
    private let responseTimeout: TimeInterval
    private let shutdownTimeout: TimeInterval
    private let shutdownLock = NSLock()
    private var nextRequestID = 1
    private var didShutdown = false
    private var didLogSuccessfulQuotaRead = false

    init(
        executable: URL,
        responseTimeout: TimeInterval,
        shutdownTimeout: TimeInterval,
        quotaChanged: @escaping @Sendable () -> Void
    ) throws {
        process = Process()
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        inputHandle = inputPipe.fileHandleForWriting
        outputReader = SessionOutputReader(handle: outputPipe.fileHandleForReading, quotaChanged: quotaChanged)
        self.responseTimeout = responseTimeout
        self.shutdownTimeout = shutdownTimeout

        process.executableURL = executable
        process.arguments = ["app-server", "--stdio"]
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            throw CodexUsageClientError.launchFailed
        }
    }

    func initialize() throws {
        do {
            let initializeID = takeRequestID()
            try send([
                [
                    "id": initializeID,
                    "method": "initialize",
                    "params": [
                        "clientInfo": [
                            "name": "codex-usage-monitor",
                            "title": "Codex Usage Monitor",
                            "version": "2.0.1"
                        ],
                        "capabilities": [
                            "experimentalApi": true,
                            "requestAttestation": false
                        ]
                    ]
                ]
            ])
            _ = try response(for: initializeID)
            try send([["method": "initialized"]])
        } catch {
            shutdown()
            throw error
        }
    }

    deinit {
        shutdown()
    }

    func fetchUsage(apiCostEstimate: CodexAPICostEstimate?) throws -> CodexUsageFetchResult {
        let rateLimitsID = takeRequestID()
        let accountUsageID = takeRequestID()
        let threadListID = takeRequestID()
        try send([
            ["id": rateLimitsID, "method": "account/rateLimits/read"],
            ["id": accountUsageID, "method": "account/usage/read"],
            [
                "id": threadListID,
                "method": "thread/list",
                "params": [
                    "limit": 3,
                    "sortKey": "updated_at",
                    "sortDirection": "desc",
                    "useStateDbOnly": true
                ]
            ]
        ])

        var pending = Set([rateLimitsID, accountUsageID, threadListID])
        var responses: [Int: Data] = [:]
        var transportError: Error?
        let deadline = Date().addingTimeInterval(responseTimeout)
        while !pending.isEmpty {
            do {
                let remaining = deadline.timeIntervalSinceNow
                guard remaining > 0 else { throw CodexUsageClientError.responseTimedOut }
                let line = try readLine(timeout: remaining)
                guard
                    let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                    let id = (object["id"] as? NSNumber)?.intValue,
                    pending.remove(id) != nil
                else { continue }
                responses[id] = line
            } catch {
                transportError = error
                break
            }
        }
        // Recover a broken connection only if nothing was returned. A missing
        // optional endpoint must not discard a healthy quota/account response.
        if responses.isEmpty, let transportError { throw transportError }
        let sourceResponses: [UsageSource: Data] = [
            .limits: responses[rateLimitsID], .account: responses[accountUsageID],
            .threads: responses[threadListID]
        ].compactMapValues { $0 }
        let needsRecovery = CodexUsageResponseDecoder.requiresAuthenticationRecovery(responses: sourceResponses)
        let usage = CodexUsageResponseDecoder.decode(
            responses: sourceResponses,
            missingMessage: transportError?.localizedDescription,
            apiCostEstimate: apiCostEstimate
        )
        if !needsRecovery, !didLogSuccessfulQuotaRead, usage.sourceHealth[.limits]?.state == .live {
            didLogSuccessfulQuotaRead = true
            let accountLive = usage.sourceHealth[.account]?.state == .live
            let threadsLive = usage.sourceHealth[.threads]?.state == .live
            // Once per connection; no credentials, quota values or chat titles.
            UsageTelemetry.connection.info("Usage sources live: quota=true account=\(accountLive, privacy: .public) threads=\(threadsLive, privacy: .public)")
        }
        return CodexUsageFetchResult(usage: usage, requiresAuthenticationRecovery: needsRecovery)
    }

    func shutdown() {
        shutdownLock.lock()
        guard !didShutdown else {
            shutdownLock.unlock()
            return
        }
        didShutdown = true
        shutdownLock.unlock()
        outputReader.stop()

        let startedAt = Date()
        let timeout = max(0, shutdownTimeout)
        let deadline = startedAt.addingTimeInterval(timeout)
        let gracefulDeadline = startedAt.addingTimeInterval(min(0.1, timeout * 0.25))
        let terminationDeadline = startedAt.addingTimeInterval(timeout * 0.75)

        try? inputHandle.close()

        if process.isRunning {
            // Closing stdin is the app-server's normal shutdown signal. Give it
            // a short bounded window to flush and exit before escalating.
            waitForExit(until: gracefulDeadline)
        }
        if process.isRunning {
            process.terminate()
            waitForExit(until: terminationDeadline)
        }
        if process.isRunning {
            Darwin.kill(process.processIdentifier, SIGKILL)
            waitForExit(until: deadline)
        }

    }

    private func takeRequestID() -> Int {
        defer { nextRequestID += 1 }
        return nextRequestID
    }

    private func send(_ messages: [[String: Any]]) throws {
        guard process.isRunning, !hasShutDown else {
            throw CodexUsageClientError.connectionClosed
        }
        let data = try messages.reduce(into: Data()) { result, message in
            result.append(try JSONSerialization.data(withJSONObject: message))
            result.append(0x0A)
        }
        try inputHandle.write(contentsOf: data)
    }

    private func response(for id: Int) throws -> Data {
        let deadline = Date().addingTimeInterval(responseTimeout)
        while true {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else {
                throw CodexUsageClientError.responseTimedOut
            }
            let line = try readLine(timeout: remaining)
            guard
                let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                (object["id"] as? NSNumber)?.intValue == id
            else { continue }
            return line
        }
    }

    private func readLine(timeout: TimeInterval) throws -> Data {
        try outputReader.next(timeout: timeout)
    }

    private var hasShutDown: Bool {
        shutdownLock.lock()
        defer { shutdownLock.unlock() }
        return didShutdown
    }

    private func waitForExit(until deadline: Date) {
        while process.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: min(0.01, max(0, deadline.timeIntervalSinceNow)))
        }
        // `Process.waitUntilExit()` can still block indefinitely after
        // `isRunning` turns false while Foundation waits for its termination
        // notification. The bounded polling above is sufficient here and
        // preserves the shutdown deadline even on that macOS failure mode.
    }
}

/// Each RPC is decoded independently. A `null` metric remains unknown even
/// when its endpoint returned successfully; freshness describes the source,
/// not an invented zero for every field in that source.
enum CodexUsageResponseDecoder {
    static func requiresAuthenticationRecovery(responses: [UsageSource: Data]) -> Bool {
        // Only account endpoints can invalidate this connection's login.
        // Never match words in successful results (such as a chat/limit name),
        // nor mistake unsupported endpoints, throttling or 5xx for auth failures.
        [UsageSource.limits, .account].contains { source in
            guard let data = responses[source],
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let error = object["error"] as? [String: Any]
            else { return false }
            let details = error["data"] as? [String: Any] ?? [:]
            let nested = details["error"] as? [String: Any] ?? [:]
            let nodes = [error, details, nested]
            if error["code"] as? Int == 401 { return true }
            if nodes.contains(where: { node in
                ["status", "statusCode", "httpStatusCode", "status_code"].contains { node[$0] as? Int == 401 }
            }) { return true }
            let pattern = #"\b(?:unauthorized|unauthenticated|token_revoked|token_expired|invalid_token|invalid_grant|refresh_token_(?:expired|reused|invalidated)|authentication_error)\b|\binvalidated\s+oauth\s+token\b|\b(?:http(?:\s+status)?|status(?:\s+code)?)\s*[:=]?\s*401\b|\b(?:access|oauth|refresh|auth|authentication)\s+token\b.{0,40}\b(?:expired|revoked|invalidated|already used)\b"#
            return nodes.contains { node in
                ["message", "code", "errorCode", "type", "error_description"].contains { field in
                    guard let value = node[field] as? String else { return false }
                    return value.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
                }
            }
        }
    }

    static func decode(
        responses: [UsageSource: Data],
        missingMessage: String? = nil,
        apiCostEstimate: CodexAPICostEstimate? = nil,
        now: Date = Date()
    ) -> CodexLiveUsage {
        var health: [UsageSource: SourceHealth] = [:]
        func result<Value: Decodable>(_ type: Value.Type, source: UsageSource) -> Value? {
            do {
                guard let data = responses[source] else {
                    throw CodexUsageClientError.server(missingMessage ?? "No response from this data source")
                }
                let envelope = try JSONDecoder().decode(RPCEnvelope<Value>.self, from: data)
                try envelope.throwIfNeeded()
                guard let result = envelope.result else {
                    throw CodexUsageClientError.server("This data source returned no result")
                }
                health[source] = .success(at: now)
                return result
            } catch {
                let message = error is DecodingError
                    ? "Unsupported response format" : error.localizedDescription
                health[source] = SourceHealth.loading.failing(String(message.prefix(240)), at: now)
                return nil
            }
        }
        let limits = result(RateLimitsResult.self, source: .limits)
        let account = result(AccountUsageResult.self, source: .account)
        let threadList = result(ThreadListResult.self, source: .threads)
        var buckets = (limits?.rateLimitsByLimitId ?? [:]).map { id, value in
            CodexRateLimitBucket(id: id, name: value.limitName, snapshot: value.liveValue)
        }.sorted {
            if $0.id == "codex" { return $1.id != "codex" }
            if $1.id == "codex" { return false }
            return $0.id < $1.id
        }
        if buckets.isEmpty, let legacy = limits?.rateLimits {
            buckets = [CodexRateLimitBucket(id: legacy.limitId ?? "codex",
                                           name: legacy.limitName, snapshot: legacy.liveValue)]
        }
        if limits != nil && buckets.isEmpty {
            health[.limits] = SourceHealth.loading.failing("No quota bucket returned", at: now)
        }
        return CodexLiveUsage(
            rateLimits: buckets.first?.snapshot
                ?? CodexRateLimitSnapshot(planType: nil, primary: nil, secondary: nil),
            availableResetCount: limits?.rateLimitResetCredits?.availableCount.flatMap { $0 >= 0 ? $0 : nil },
            lifetimeTokens: account?.summary?.lifetimeTokens.flatMap { $0 >= 0 ? $0 : nil },
            dailyUsage: (account?.dailyUsageBuckets ?? []).map {
                CodexDailyUsage(startDate: $0.startDate, tokens: $0.tokens)
            },
            recentThreads: (threadList?.data ?? []).map { thread in
                CodexThreadUsage(id: thread.id, title: thread.displayTitle,
                                 updatedAt: Date(timeIntervalSince1970: thread.updatedAt),
                                 totalTokens: SessionTokenReader.latestTotalTokens(at: thread.path))
            },
            apiCostEstimate: apiCostEstimate,
            dailyUsageAvailable: account?.dailyUsageBuckets != nil,
            rateLimitBuckets: buckets,
            sourceHealth: health
        )
    }
}

enum CodexUsageClientError: LocalizedError {
    case executableNotFound
    case launchFailed
    case connectionClosed
    case responseTimedOut
    case shuttingDown
    case server(String)
    case missingRateLimits(String)
    case missingAccountUsage

    var errorDescription: String? {
        description(language: .systemMatch())
    }

    func description(language: AppLanguage) -> String {
        switch self {
        case .executableNotFound:
            language == .simplifiedChinese ? "未找到 Codex 应用" : "Codex app not found"
        case .launchFailed:
            language == .simplifiedChinese
                ? "无法启动 Codex 用量服务"
                : "Unable to start the Codex usage service"
        case .connectionClosed:
            language == .simplifiedChinese
                ? "Codex 用量服务连接已关闭"
                : "The Codex usage service connection closed"
        case .responseTimedOut:
            language == .simplifiedChinese
                ? "Codex 用量服务响应超时"
                : "The Codex usage service timed out"
        case .shuttingDown:
            language == .simplifiedChinese
                ? "Codex 用量监控正在退出"
                : "Codex Usage Monitor is shutting down"
        case .server(let message):
            language == .simplifiedChinese
                ? "Codex 返回错误：\(message)"
                : "Codex returned an error: \(message)"
        case .missingRateLimits:
            language == .simplifiedChinese
                ? "未读取到 Codex 限额"
                : "Codex usage limits were not returned"
        case .missingAccountUsage:
            language == .simplifiedChinese
                ? "未读取到账户 token 用量"
                : "Account token usage was not returned"
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
    let rateLimits: RateLimitSnapshotResponse?
    let rateLimitsByLimitId: [String: RateLimitSnapshotResponse]?
    let rateLimitResetCredits: ResetCreditsResponse?
}

private struct RateLimitSnapshotResponse: Decodable {
    let limitId: String?
    let limitName: String?
    let primary: RateLimitWindowResponse?
    let secondary: RateLimitWindowResponse?
    let planType: String?

    var liveValue: CodexRateLimitSnapshot {
        CodexRateLimitSnapshot(planType: planType, primary: primary?.liveValue,
                               secondary: secondary?.liveValue)
    }
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
    let availableCount: Int?
}

private struct AccountUsageResult: Decodable {
    let summary: AccountUsageSummaryResponse?
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
