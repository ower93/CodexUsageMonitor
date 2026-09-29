import Darwin
import Foundation

struct SessionFileDescriptor: Sendable {
    let sessionID: String
    let url: URL
    let parentSessionID: String?
    let forkedAt: Date?
    let metadataResolved: Bool

    var isForked: Bool {
        parentSessionID != nil && forkedAt != nil
    }
}

struct SessionUsageSlice: Sendable {
    let usageDay: String
    let model: String
    let counts: TokenCounts
}

struct SessionUsageHistory: Sendable {
    let summary: SessionTokenSummary
    let slices: [SessionUsageSlice]
}

struct SessionLogCursorState: Sendable {
    let completeLineCursor: UInt64
    let currentModel: String
    let summary: SessionTokenSummary?
}

struct SessionHistoryRead: Sendable {
    let history: SessionUsageHistory
    let state: SessionLogCursorState
}

struct SessionIncrementalRead: Sendable {
    let slices: [SessionUsageSlice]
    let state: SessionLogCursorState
}

enum SessionUsageLogReader {
    private static let eventMessageNeedle = #""type":"event_msg""#
    private static let tokenCountNeedle = #""type":"token_count""#
    private static let turnContextNeedle = #""type":"turn_context""#
    private static let sessionMetaNeedle = #""type":"session_meta""#

    static func descriptor(for url: URL) -> SessionFileDescriptor {
        var descriptor = SessionFileDescriptor(
            sessionID: sessionID(from: url.lastPathComponent),
            url: url,
            parentSessionID: nil,
            forkedAt: nil,
            metadataResolved: false
        )

        try? JSONLineFile.forEachLine(at: url) { line in
            guard contains(line, sessionMetaNeedle),
                  let object = jsonObject(line),
                  object["type"] as? String == "session_meta",
                  let payload = object["payload"] as? [String: Any]
            else { return true }

            let sessionID = (payload["id"] as? String) ?? descriptor.sessionID
            let parentID = (payload["forked_from_id"] as? String)
                ?? (payload["parent_thread_id"] as? String)
                ?? ((payload["source"] as? [String: Any])
                    .flatMap(parentSessionID(from:)))
            let timestamp = (payload["timestamp"] as? String)
                .flatMap(SessionTimestampParser.date(from:))
            descriptor = SessionFileDescriptor(
                sessionID: sessionID,
                url: url,
                parentSessionID: parentID,
                forkedAt: parentID == nil ? nil : timestamp,
                metadataResolved: true
            )
            return false
        }
        return descriptor
    }

    static func inheritedBaselines(
        for descriptors: [SessionFileDescriptor],
        childSessionIDs: Set<String>? = nil
    ) -> [String: TokenCounts] {
        var filesByID: [String: URL] = [:]
        for descriptor in descriptors where filesByID[descriptor.sessionID] == nil {
            filesByID[descriptor.sessionID] = descriptor.url
        }
        var requestsByParent: [String: [BaselineRequest]] = [:]

        for descriptor in descriptors {
            if let childSessionIDs,
               !childSessionIDs.contains(descriptor.sessionID) {
                continue
            }
            guard let parentID = descriptor.parentSessionID,
                  let forkedAt = descriptor.forkedAt
            else { continue }
            requestsByParent[parentID, default: []].append(BaselineRequest(
                childSessionID: descriptor.sessionID,
                forkedAt: forkedAt
            ))
        }

        var result: [String: TokenCounts] = [:]
        for (parentID, requests) in requestsByParent {
            guard let parentURL = filesByID[parentID] else { continue }
            let sortedRequests = requests.sorted { $0.forkedAt < $1.forkedAt }
            resolveBaselines(
                requests: sortedRequests,
                parentURL: parentURL,
                into: &result
            )
        }

        // Older Codex builds sometimes wrote forked sessions with the copied
        // token history embedded in the child log while the parent log had no
        // token_count events. In that format, the last child event at or before
        // the fork timestamp is the inherited baseline.
        for descriptor in descriptors {
            if let childSessionIDs,
               !childSessionIDs.contains(descriptor.sessionID) {
                continue
            }
            guard result[descriptor.sessionID] == nil,
                  descriptor.parentSessionID != nil,
                  let forkedAt = descriptor.forkedAt,
                  let baseline = localInheritedBaseline(
                      childURL: descriptor.url,
                      forkedAt: forkedAt
                  )
            else { continue }
            result[descriptor.sessionID] = baseline
        }
        return result
    }

    static func history(
        for descriptor: SessionFileDescriptor,
        inheritedBaseline: TokenCounts
    ) -> SessionUsageHistory? {
        historyAndState(
            for: descriptor,
            inheritedBaseline: inheritedBaseline
        )?.history
    }

    static func historyAndState(
        for descriptor: SessionFileDescriptor,
        inheritedBaseline: TokenCounts
    ) -> SessionHistoryRead? {
        var currentModel = "unknown"
        var previousBillable = TokenCounts.zero
        var latestBillable = TokenCounts.zero
        var latestRawSummary: SessionTokenSummary?
        var sawComparableUsage = false
        var slicesByKey: [SliceKey: TokenCounts] = [:]
        let cursor: UInt64

        do {
            cursor = try JSONLineFile.forEachCompleteLine(at: descriptor.url) { line in
                if contains(line, turnContextNeedle),
                   let object = jsonObject(line),
                   object["type"] as? String == "turn_context",
                   let payload = object["payload"] as? [String: Any],
                   let model = payload["model"] as? String {
                    currentModel = model
                    return true
                }

                guard contains(line, eventMessageNeedle),
                      contains(line, tokenCountNeedle),
                      let event = tokenCountEvent(line)
                else { return true }

                guard let currentBillable = event.counts.subtracting(inheritedBaseline) else {
                    return true
                }
                sawComparableUsage = true
                guard let delta = currentBillable.delta(since: previousBillable) else {
                    return true
                }
                previousBillable = currentBillable
                latestBillable = currentBillable
                latestRawSummary = SessionTokenSummary(
                    model: currentModel,
                    inputTokens: event.counts.inputTokens,
                    cachedInputTokens: event.counts.cachedInputTokens,
                    outputTokens: event.counts.outputTokens,
                    totalTokens: event.counts.totalTokens
                )
                guard delta.totalTokens > 0 else { return true }

                let key = SliceKey(usageDay: event.usageDay, model: currentModel)
                if slicesByKey[key] == nil {
                    slicesByKey[key] = .zero
                }
                slicesByKey[key]?.add(delta)
                return true
            }
        } catch {
            return nil
        }

        guard sawComparableUsage else { return nil }
        let summary = SessionTokenSummary(
            model: latestRawSummary?.model ?? currentModel,
            inputTokens: latestBillable.inputTokens,
            cachedInputTokens: latestBillable.cachedInputTokens,
            outputTokens: latestBillable.outputTokens,
            totalTokens: latestBillable.totalTokens
        )
        let slices = slicesByKey.map {
            SessionUsageSlice(usageDay: $0.key.usageDay, model: $0.key.model, counts: $0.value)
        }
        return SessionHistoryRead(
            history: SessionUsageHistory(summary: summary, slices: slices),
            state: SessionLogCursorState(
                completeLineCursor: cursor,
                currentModel: currentModel,
                summary: latestRawSummary
            )
        )
    }

    static func warmState(
        for descriptor: SessionFileDescriptor,
        fileSize: UInt64
    ) -> SessionLogCursorState? {
        for byteLimit in [131_072, 1_048_576] {
            if let tail = tailState(
                for: descriptor.url,
                fileSize: fileSize,
                byteLimit: byteLimit
            ), tail.summary?.model != "unknown" {
                return tail
            }
        }
        return fullState(for: descriptor.url)
    }

    static func incrementalRead(
        for descriptor: SessionFileDescriptor,
        previous: SessionLogCursorState
    ) -> SessionIncrementalRead? {
        var currentModel = previous.currentModel
        var latestSummary = previous.summary
        var highWatermark = previous.summary.map(TokenCounts.init(summary:))
        var slicesByKey: [SliceKey: TokenCounts] = [:]
        let cursor: UInt64

        do {
            cursor = try JSONLineFile.forEachCompleteLine(
                at: descriptor.url,
                startingAt: previous.completeLineCursor
            ) { line in
                if contains(line, turnContextNeedle),
                   let object = jsonObject(line),
                   object["type"] as? String == "turn_context",
                   let payload = object["payload"] as? [String: Any],
                   let model = payload["model"] as? String {
                    currentModel = model
                    return true
                }

                guard contains(line, eventMessageNeedle),
                      contains(line, tokenCountNeedle),
                      let event = tokenCountEvent(line)
                else { return true }

                guard let prior = highWatermark else {
                    highWatermark = event.counts
                    latestSummary = summary(model: currentModel, counts: event.counts)
                    return true
                }
                guard let delta = event.counts.delta(since: prior) else {
                    // Keep the durable high-water mark across a temporary
                    // truncation or counter reset. Tokens are only resumed once
                    // the cumulative log catches up with the checkpoint.
                    return true
                }

                highWatermark = event.counts
                latestSummary = SessionTokenSummary(
                    model: currentModel,
                    inputTokens: event.counts.inputTokens,
                    cachedInputTokens: event.counts.cachedInputTokens,
                    outputTokens: event.counts.outputTokens,
                    totalTokens: event.counts.totalTokens
                )
                guard delta.totalTokens > 0 else { return true }
                let key = SliceKey(usageDay: event.usageDay, model: currentModel)
                if slicesByKey[key] == nil {
                    slicesByKey[key] = .zero
                }
                slicesByKey[key]?.add(delta)
                return true
            }
        } catch {
            return nil
        }

        let slices = slicesByKey.map {
            SessionUsageSlice(
                usageDay: $0.key.usageDay,
                model: $0.key.model,
                counts: $0.value
            )
        }
        return SessionIncrementalRead(
            slices: slices,
            state: SessionLogCursorState(
                completeLineCursor: cursor,
                currentModel: currentModel,
                summary: latestSummary
            )
        )
    }

    private static func summary(
        model: String,
        counts: TokenCounts
    ) -> SessionTokenSummary {
        SessionTokenSummary(
            model: model,
            inputTokens: counts.inputTokens,
            cachedInputTokens: counts.cachedInputTokens,
            outputTokens: counts.outputTokens,
            totalTokens: counts.totalTokens
        )
    }

    private static func fullState(for url: URL) -> SessionLogCursorState? {
        var currentModel = "unknown"
        var latestSummary: SessionTokenSummary?
        let cursor: UInt64

        do {
            cursor = try JSONLineFile.forEachCompleteLine(at: url) { line in
                if contains(line, turnContextNeedle),
                   let object = jsonObject(line),
                   object["type"] as? String == "turn_context",
                   let payload = object["payload"] as? [String: Any],
                   let model = payload["model"] as? String {
                    currentModel = model
                    return true
                }

                guard contains(line, eventMessageNeedle),
                      contains(line, tokenCountNeedle),
                      let event = tokenCountEvent(line)
                else { return true }
                latestSummary = SessionTokenSummary(
                    model: currentModel,
                    inputTokens: event.counts.inputTokens,
                    cachedInputTokens: event.counts.cachedInputTokens,
                    outputTokens: event.counts.outputTokens,
                    totalTokens: event.counts.totalTokens
                )
                return true
            }
        } catch {
            return nil
        }

        return SessionLogCursorState(
            completeLineCursor: cursor,
            currentModel: currentModel,
            summary: latestSummary
        )
    }

    private static func tailState(
        for url: URL,
        fileSize: UInt64,
        byteLimit: Int
    ) -> SessionLogCursorState? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }

        let readSize = min(fileSize, UInt64(byteLimit))
        let offset = fileSize - readSize
        do {
            try handle.seek(toOffset: offset)
            let data = try handle.read(upToCount: Int(readSize)) ?? Data()
            guard !data.isEmpty || fileSize == 0 else { return nil }

            var lowerBound = data.startIndex
            if offset > 0 {
                guard let firstNewline = data[lowerBound...].firstIndex(of: 0x0A) else {
                    return nil
                }
                lowerBound = data.index(after: firstNewline)
            }
            let upperBound: Data.Index
            if data.last == 0x0A {
                upperBound = data.endIndex
            } else if let lastNewline = data.lastIndex(of: 0x0A) {
                upperBound = data.index(after: lastNewline)
            } else {
                upperBound = lowerBound
            }

            var currentModel = "unknown"
            var latestSummary: SessionTokenSummary?
            if lowerBound < upperBound {
                for rawLine in data[lowerBound..<upperBound].split(separator: 0x0A) {
                    autoreleasepool {
                        guard let object = try? JSONSerialization.jsonObject(
                            with: Data(rawLine)
                        ) as? [String: Any],
                        let type = object["type"] as? String,
                        let payload = object["payload"] as? [String: Any]
                        else { return }

                        if type == "turn_context",
                           let model = payload["model"] as? String {
                            currentModel = model
                            return
                        }
                        guard type == "event_msg",
                              payload["type"] as? String == "token_count",
                              let info = payload["info"] as? [String: Any],
                              let usage = info["total_token_usage"] as? [String: Any]
                        else { return }
                        let input = int64(usage["input_tokens"]) ?? 0
                        let cached = int64(usage["cached_input_tokens"]) ?? 0
                        let output = int64(usage["output_tokens"]) ?? 0
                        let total = int64(usage["total_tokens"]) ?? (input + output)
                        latestSummary = SessionTokenSummary(
                            model: currentModel,
                            inputTokens: input,
                            cachedInputTokens: cached,
                            outputTokens: output,
                            totalTokens: total
                        )
                    }
                }
            }

            let incompleteBytes = data.distance(from: upperBound, to: data.endIndex)
            return SessionLogCursorState(
                completeLineCursor: fileSize - UInt64(incompleteBytes),
                currentModel: currentModel,
                summary: latestSummary
            )
        } catch {
            return nil
        }
    }

    private static func resolveBaselines(
        requests: [BaselineRequest],
        parentURL: URL,
        into result: inout [String: TokenCounts]
    ) {
        guard !requests.isEmpty else { return }
        var requestIndex = 0
        var latestCounts: TokenCounts?

        do {
            try JSONLineFile.forEachLine(at: parentURL) { line in
                guard contains(line, eventMessageNeedle),
                      contains(line, tokenCountNeedle),
                      let event = tokenCountEvent(line, includeDate: true),
                      let eventDate = event.date
                else { return true }

                while requestIndex < requests.count,
                      requests[requestIndex].forkedAt < eventDate {
                    if let latestCounts {
                        result[requests[requestIndex].childSessionID] = latestCounts
                    }
                    requestIndex += 1
                }
                latestCounts = event.counts
                return requestIndex < requests.count
            }
        } catch {
            return
        }

        while requestIndex < requests.count {
            if let latestCounts {
                result[requests[requestIndex].childSessionID] = latestCounts
            }
            requestIndex += 1
        }
    }

    private static func localInheritedBaseline(
        childURL: URL,
        forkedAt: Date
    ) -> TokenCounts? {
        var latestCounts: TokenCounts?
        do {
            try JSONLineFile.forEachLine(at: childURL) { line in
                guard contains(line, eventMessageNeedle),
                      contains(line, tokenCountNeedle),
                      let event = tokenCountEvent(line, includeDate: true),
                      let eventDate = event.date
                else { return true }
                guard eventDate <= forkedAt else { return false }
                latestCounts = event.counts
                return true
            }
        } catch {
            return nil
        }
        return latestCounts
    }

    private static func tokenCountEvent(
        _ line: UnsafeBufferPointer<CChar>,
        includeDate: Bool = false
    ) -> TokenCountEvent? {
        guard let object = jsonObject(line),
              object["type"] as? String == "event_msg",
              let payload = object["payload"] as? [String: Any],
              payload["type"] as? String == "token_count",
              let info = payload["info"] as? [String: Any],
              let usage = info["total_token_usage"] as? [String: Any],
              let timestamp = object["timestamp"] as? String
        else { return nil }

        let parsedDate = SessionTimestampParser.date(from: timestamp)
        let input = int64(usage["input_tokens"]) ?? 0
        let cached = int64(usage["cached_input_tokens"]) ?? 0
        let output = int64(usage["output_tokens"]) ?? 0
        let total = int64(usage["total_tokens"]) ?? (input + output)
        return TokenCountEvent(
            usageDay: parsedDate.map(usageDay(for:)) ?? String(timestamp.prefix(10)),
            date: includeDate ? parsedDate : nil,
            counts: TokenCounts(
                inputTokens: input,
                cachedInputTokens: cached,
                outputTokens: output,
                totalTokens: total
            )
        )
    }

    private static func parentSessionID(from source: [String: Any]) -> String? {
        guard let subagent = source["subagent"] as? [String: Any],
              let spawn = subagent["thread_spawn"] as? [String: Any]
        else { return nil }
        return spawn["parent_thread_id"] as? String
    }

    private static func sessionID(from fileName: String) -> String {
        let stem = URL(fileURLWithPath: fileName).deletingPathExtension().lastPathComponent
        return String(stem.suffix(36))
    }

    private static func contains(_ line: UnsafeBufferPointer<CChar>, _ needle: String) -> Bool {
        guard let baseAddress = line.baseAddress else { return false }
        return needle.withCString { strstr(baseAddress, $0) != nil }
    }

    private static func usageDay(for date: Date) -> String {
        let components = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(
            format: "%04d-%02d-%02d",
            components.year ?? 0,
            components.month ?? 0,
            components.day ?? 0
        )
    }

    private static func jsonObject(_ line: UnsafeBufferPointer<CChar>) -> [String: Any]? {
        guard let baseAddress = line.baseAddress else { return nil }
        let data = Data(bytes: baseAddress, count: line.count)
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private static func int64(_ value: Any?) -> Int64? {
        (value as? NSNumber)?.int64Value
    }
}

private struct BaselineRequest {
    let childSessionID: String
    let forkedAt: Date
}

private struct TokenCountEvent {
    let usageDay: String
    let date: Date?
    let counts: TokenCounts
}

private struct SliceKey: Hashable {
    let usageDay: String
    let model: String
}

private enum SessionTimestampParser {
    static func date(from value: String) -> Date? {
        if let date = try? Date(
            value,
            strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true)
        ) {
            return date
        }
        return try? Date(
            value,
            strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: false)
        )
    }
}

private enum JSONLineFile {
    enum ReadError: Error {
        case cannotOpen
        case cannotSeek
    }

    static func forEachLine(
        at url: URL,
        _ body: (UnsafeBufferPointer<CChar>) -> Bool
    ) throws {
        _ = try forEachCompleteLine(at: url, body)
    }

    @discardableResult
    static func forEachCompleteLine(
        at url: URL,
        startingAt offset: UInt64 = 0,
        _ body: (UnsafeBufferPointer<CChar>) -> Bool
    ) throws -> UInt64 {
        guard let file = fopen(url.path, "r") else { throw ReadError.cannotOpen }
        defer { fclose(file) }
        guard offset <= UInt64(Int64.max),
              fseeko(file, off_t(offset), SEEK_SET) == 0
        else {
            throw ReadError.cannotSeek
        }

        var pointer: UnsafeMutablePointer<CChar>?
        var capacity = 0
        defer { free(pointer) }
        var committedOffset = offset

        while true {
            let lineStart = ftello(file)
            guard lineStart >= 0 else { throw ReadError.cannotSeek }
            let length = getline(&pointer, &capacity, file)
            guard length >= 0 else { break }
            guard let pointer else { continue }
            var contentLength = Int(length)
            guard contentLength > 0, pointer[contentLength - 1] == 0x0A else {
                // A writer may be in the middle of appending a JSON object.
                // Leave the cursor at the beginning of that partial line so
                // the next refresh can read it again once it is complete.
                committedOffset = UInt64(lineStart)
                break
            }
            contentLength -= 1
            let buffer = UnsafeBufferPointer(start: pointer, count: contentLength)
            let afterLine = ftello(file)
            guard afterLine >= 0 else { throw ReadError.cannotSeek }
            committedOffset = UInt64(afterLine)
            let shouldContinue = autoreleasepool {
                body(buffer)
            }
            if !shouldContinue { break }
        }
        return committedOffset
    }
}
