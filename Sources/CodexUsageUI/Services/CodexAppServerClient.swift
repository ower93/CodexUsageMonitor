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

    init(
        executableURL: URL? = nil,
        responseTimeout: TimeInterval = 12,
        shutdownTimeout: TimeInterval = 2
    ) {
        self.executableURL = executableURL
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
        for attempt in 0..<2 {
            var attemptedSession: CodexAppServerSession?
            do {
                guard !shuttingDown else {
                    throw CodexUsageClientError.shuttingDown
                }
                let currentSession = try sessionForRequest()
                attemptedSession = currentSession
                let usage = try currentSession.fetchUsage(apiCostEstimate: apiCostEstimate)
                guard !shuttingDown else {
                    throw CodexUsageClientError.shuttingDown
                }
                return usage
            } catch {
                lastError = error
                if let attemptedSession {
                    discardSession(attemptedSession)
                    attemptedSession.shutdown()
                }
                if shuttingDown {
                    throw CodexUsageClientError.shuttingDown
                }
                if attempt == 1 || error is CancellationError {
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
            shutdownTimeout: shutdownTimeout
        )
        guard publishSession(newSession) else {
            newSession.shutdown()
            throw CodexUsageClientError.shuttingDown
        }

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
}

protocol CodexUsageFetching: Sendable {
    func fetchUsage(apiCostEstimate: CodexAPICostEstimate?) async throws -> CodexLiveUsage
    func shutdown() async
}

extension CodexAppServerClient: CodexUsageFetching {}

private final class CodexAppServerSession: @unchecked Sendable {
    private let process: Process
    private let inputHandle: FileHandle
    private let outputHandle: FileHandle
    private let responseTimeout: TimeInterval
    private let shutdownTimeout: TimeInterval
    private let shutdownLock = NSLock()
    private var outputBuffer = Data()
    private var nextRequestID = 1
    private var didShutdown = false

    init(
        executable: URL,
        responseTimeout: TimeInterval,
        shutdownTimeout: TimeInterval
    ) throws {
        process = Process()
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        inputHandle = inputPipe.fileHandleForWriting
        outputHandle = outputPipe.fileHandleForReading
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
                            "version": "1.2.1"
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

    func fetchUsage(apiCostEstimate: CodexAPICostEstimate?) throws -> CodexLiveUsage {
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
        let deadline = Date().addingTimeInterval(responseTimeout)
        while !pending.isEmpty {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else {
                throw CodexUsageClientError.responseTimedOut
            }
            let line = try readLine(timeout: remaining)
            guard
                let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                let id = (object["id"] as? NSNumber)?.intValue,
                pending.remove(id) != nil
            else { continue }
            responses[id] = line
        }

        let decoder = JSONDecoder()
        let rateLimitsEnvelope = try decoder.decode(
            RPCEnvelope<RateLimitsResult>.self,
            from: try requiredResponse(rateLimitsID, in: responses)
        )
        try rateLimitsEnvelope.throwIfNeeded()
        guard let rateLimits = rateLimitsEnvelope.result else {
            throw CodexUsageClientError.missingRateLimits("")
        }

        let accountUsageEnvelope = try decoder.decode(
            RPCEnvelope<AccountUsageResult>.self,
            from: try requiredResponse(accountUsageID, in: responses)
        )
        try accountUsageEnvelope.throwIfNeeded()
        guard let accountUsage = accountUsageEnvelope.result else {
            throw CodexUsageClientError.missingAccountUsage
        }

        let threadListEnvelope = try decoder.decode(
            RPCEnvelope<ThreadListResult>.self,
            from: try requiredResponse(threadListID, in: responses)
        )
        try threadListEnvelope.throwIfNeeded()

        let threads = (threadListEnvelope.result?.data ?? []).map { thread in
            CodexThreadUsage(
                id: thread.id,
                title: thread.displayTitle,
                updatedAt: Date(timeIntervalSince1970: thread.updatedAt),
                totalTokens: SessionTokenReader.latestTotalTokens(at: thread.path)
            )
        }

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

    func shutdown() {
        shutdownLock.lock()
        guard !didShutdown else {
            shutdownLock.unlock()
            return
        }
        didShutdown = true
        shutdownLock.unlock()

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

        try? outputHandle.close()
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

    private func requiredResponse(_ id: Int, in responses: [Int: Data]) throws -> Data {
        guard let response = responses[id] else {
            throw CodexUsageClientError.connectionClosed
        }
        return response
    }

    private func readLine(timeout: TimeInterval) throws -> Data {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            if let newline = outputBuffer.firstIndex(of: 0x0A) {
                let line = outputBuffer.prefix(upTo: newline)
                outputBuffer.removeSubrange(...newline)
                return Data(line)
            }

            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else {
                throw CodexUsageClientError.responseTimedOut
            }
            let remainingMilliseconds = Int32(
                max(1, min(Double(Int32.max), remaining * 1_000))
            )

            var descriptor = pollfd(
                fd: outputHandle.fileDescriptor,
                events: Int16(POLLIN | POLLHUP),
                revents: 0
            )
            let result = Darwin.poll(&descriptor, 1, remainingMilliseconds)
            if result == 0 {
                throw CodexUsageClientError.responseTimedOut
            }
            if result < 0 {
                if errno == EINTR { continue }
                throw CodexUsageClientError.connectionClosed
            }

            var bytes = [UInt8](repeating: 0, count: 16_384)
            let byteCount = bytes.withUnsafeMutableBytes { rawBuffer -> Int in
                guard let baseAddress = rawBuffer.baseAddress else { return 0 }
                return Darwin.read(
                    outputHandle.fileDescriptor,
                    baseAddress,
                    rawBuffer.count
                )
            }
            if byteCount < 0 {
                if errno == EINTR || errno == EAGAIN { continue }
                throw CodexUsageClientError.connectionClosed
            }
            guard byteCount > 0 else {
                throw CodexUsageClientError.connectionClosed
            }
            outputBuffer.append(contentsOf: bytes.prefix(byteCount))
        }
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
