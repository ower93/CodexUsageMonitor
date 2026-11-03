import Darwin
import Foundation

/// Continuously drains stdout, including notifications while no RPC is active.
/// The blocking RPC consumer waits on a condition, not a polling timer.
final class SessionOutputReader: @unchecked Sendable {
    private let condition = NSCondition()
    private let source: DispatchSourceRead
    private var responses: [Data] = []
    private var ended = false
    private var buffer = Data()
    private var lastQuotaNotification: Data?
    private let quotaChanged: @Sendable () -> Void

    init(handle: FileHandle, quotaChanged: @escaping @Sendable () -> Void) {
        self.quotaChanged = quotaChanged
        let descriptor = handle.fileDescriptor
        _ = fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL) | O_NONBLOCK)
        source = DispatchSource.makeReadSource(fileDescriptor: descriptor,
            queue: DispatchQueue(label: "com.kevinchen.CodexUsageMonitor.stdout", qos: .utility))
        source.setEventHandler { [weak self] in self?.drain(descriptor) }
        // The reader owns the handle. Close only after the last drain callback,
        // avoiding a reused-descriptor race during shutdown.
        source.setCancelHandler { try? handle.close() }
        source.resume()
    }

    deinit { stop() }

    func next(timeout: TimeInterval) throws -> Data {
        let deadline = Date().addingTimeInterval(timeout)
        condition.lock()
        defer { condition.unlock() }
        while responses.isEmpty && !ended {
            guard condition.wait(until: deadline) else { throw CodexUsageClientError.responseTimedOut }
        }
        guard !responses.isEmpty else { throw CodexUsageClientError.connectionClosed }
        return responses.removeFirst()
    }

    func stop() {
        condition.lock()
        let wasEnded = ended
        ended = true
        condition.broadcast()
        condition.unlock()
        if !wasEnded { source.cancel() }
    }

    private func drain(_ descriptor: Int32) {
        for _ in 0..<64 {
            condition.lock()
            let shouldStop = ended
            condition.unlock()
            if shouldStop { return }
            var bytes = [UInt8](repeating: 0, count: 16_384)
            let count = bytes.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress!, $0.count) }
            if count < 0 {
                if errno == EINTR { continue }
                if errno == EAGAIN { return }
                stop(); return
            }
            guard count > 0 else { stop(); return }
            buffer.append(contentsOf: bytes.prefix(count))
            // A quota/thread-list response is small; malformed unbounded stdout
            // must not turn this background utility into a memory sink.
            guard buffer.count <= 4 * 1024 * 1024 else { stop(); return }
            while let newline = buffer.firstIndex(of: 0x0A) {
                let line = Data(buffer.prefix(upTo: newline))
                buffer.removeSubrange(...newline)
                consume(line)
            }
        }
    }

    private func consume(_ line: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { return }
        if object["id"] != nil {
            condition.lock()
            // Delayed responses from an old timed-out batch are harmless and
            // bounded. Request IDs are never reused within a session.
            if responses.count >= 128 { responses.removeFirst() }
            responses.append(line)
            condition.signal()
            condition.unlock()
        } else if object["method"] as? String == "account/rateLimits/updated",
                  let params = object["params"],
                  let normalized = try? JSONSerialization.data(withJSONObject: params, options: [.sortedKeys]),
                  normalized != lastQuotaNotification {
            lastQuotaNotification = normalized
            quotaChanged()
        }
    }
}
