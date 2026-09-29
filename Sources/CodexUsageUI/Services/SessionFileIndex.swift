import Darwin
import Foundation

struct SessionFileIndex: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 2

    var schemaVersion: Int
    var ledgerRevision: UInt64
    var entries: [String: Entry]

    init(ledgerRevision: UInt64 = 0) {
        schemaVersion = Self.currentSchemaVersion
        self.ledgerRevision = ledgerRevision
        entries = [:]
    }

    static func key(for url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }

    struct Entry: Codable, Equatable, Sendable {
        var identity: FileIdentity
        var observedSize: UInt64
        var modifiedAt: Date
        var completeLineCursor: UInt64
        var prefixFingerprint: FileFingerprint
        var continuityFingerprint: FileFingerprint
        var sessionID: String
        var parentSessionID: String?
        var forkedAt: Date?
        var metadataResolved: Bool
        var currentModel: String
        var summaryModel: String?
        var summaryCounts: TokenCounts?
        var inheritedBaseline: TokenCounts?
        var baselineResolutionAttempted: Bool

        var summary: SessionTokenSummary? {
            guard let summaryModel, let summaryCounts else { return nil }
            return SessionTokenSummary(
                model: summaryModel,
                inputTokens: summaryCounts.inputTokens,
                cachedInputTokens: summaryCounts.cachedInputTokens,
                outputTokens: summaryCounts.outputTokens,
                totalTokens: summaryCounts.totalTokens
            )
        }

        var descriptorParent: String? {
            parentSessionID
        }

        func descriptor(url: URL) -> SessionFileDescriptor {
            SessionFileDescriptor(
                sessionID: sessionID,
                url: url,
                parentSessionID: parentSessionID,
                forkedAt: forkedAt,
                metadataResolved: metadataResolved
            )
        }
    }
}

struct SessionFileIndexStore: Sendable {
    let url: URL

    init(ledgerURL: URL) {
        url = ledgerURL.deletingLastPathComponent()
            .appendingPathComponent("session-file-index.json")
    }

    init(url: URL) {
        self.url = url
    }

    func load() -> SessionFileIndex {
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode(SessionFileIndex.self, from: data),
              decoded.schemaVersion == SessionFileIndex.currentSchemaVersion
        else {
            // This index is only a disposable performance cache. A missing,
            // outdated, or corrupt index must never invalidate the cost ledger.
            return SessionFileIndex()
        }
        return decoded
    }

    func save(_ index: SessionFileIndex) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(index).write(to: url, options: .atomic)
    }
}

struct SessionFileIndexInspection: Sendable {
    enum Change: Equatable, Sendable {
        case unchanged
        case appended
        case rebuilt
    }

    let url: URL
    let facts: SessionFileFacts
    let previousEntry: SessionFileIndex.Entry?
    let change: Change
}

enum SessionFileIndexInspector {
    static func inspect(
        _ url: URL,
        previousEntry: SessionFileIndex.Entry?
    ) -> SessionFileIndexInspection? {
        guard let facts = SessionFileFacts.read(from: url) else { return nil }

        guard let previousEntry else {
            return SessionFileIndexInspection(
                url: url,
                facts: facts,
                previousEntry: nil,
                change: .rebuilt
            )
        }

        if facts.identity == previousEntry.identity,
           facts.size == previousEntry.observedSize,
           facts.modifiedAt == previousEntry.modifiedAt {
            // No file body is opened on this path.
            return SessionFileIndexInspection(
                url: url,
                facts: facts,
                previousEntry: previousEntry,
                change: .unchanged
            )
        }

        if facts.identity == previousEntry.identity,
           facts.size > previousEntry.observedSize,
           previousEntry.completeLineCursor <= previousEntry.observedSize,
           previousEntry.prefixFingerprint.matches(in: url),
           previousEntry.continuityFingerprint.matches(in: url) {
            return SessionFileIndexInspection(
                url: url,
                facts: facts,
                previousEntry: previousEntry,
                change: .appended
            )
        }

        // Truncation, same-size rewrites, inode replacement, or a failed
        // continuity check all discard the cursor and rebuild this one entry.
        return SessionFileIndexInspection(
            url: url,
            facts: facts,
            previousEntry: previousEntry,
            change: .rebuilt
        )
    }

    static func makeEntry(
        inspection: SessionFileIndexInspection,
        descriptor: SessionFileDescriptor,
        state: SessionLogCursorState?,
        inheritedBaseline: TokenCounts?,
        baselineResolutionAttempted: Bool
    ) -> SessionFileIndex.Entry? {
        let cursor = min(
            state?.completeLineCursor ?? 0,
            inspection.facts.size
        )
        guard let prefix = FileFingerprint.makePrefix(
            for: inspection.url,
            observedSize: inspection.facts.size
        ), let continuity = FileFingerprint.makeContinuity(
            for: inspection.url,
            observedSize: inspection.facts.size
        ) else {
            return nil
        }

        let summary = state?.summary
        return SessionFileIndex.Entry(
            identity: inspection.facts.identity,
            observedSize: inspection.facts.size,
            modifiedAt: inspection.facts.modifiedAt,
            completeLineCursor: cursor,
            prefixFingerprint: prefix,
            continuityFingerprint: continuity,
            sessionID: descriptor.sessionID,
            parentSessionID: descriptor.parentSessionID,
            forkedAt: descriptor.forkedAt,
            metadataResolved: descriptor.metadataResolved,
            currentModel: state?.currentModel ?? "unknown",
            summaryModel: summary?.model,
            summaryCounts: summary.map(TokenCounts.init(summary:)),
            inheritedBaseline: inheritedBaseline,
            baselineResolutionAttempted: baselineResolutionAttempted
        )
    }
}

struct FileIdentity: Codable, Equatable, Sendable {
    let device: UInt64
    let inode: UInt64
}

struct SessionFileFacts: Equatable, Sendable {
    let identity: FileIdentity
    let size: UInt64
    let modifiedAt: Date

    static func read(from url: URL) -> SessionFileFacts? {
        var information = stat()
        let result = url.path.withCString {
            lstat($0, &information)
        }
        guard result == 0, (information.st_mode & S_IFMT) == S_IFREG else {
            return nil
        }

        let seconds = TimeInterval(information.st_mtimespec.tv_sec)
        let nanoseconds = TimeInterval(information.st_mtimespec.tv_nsec) / 1_000_000_000
        return SessionFileFacts(
            identity: FileIdentity(
                device: UInt64(information.st_dev),
                inode: UInt64(information.st_ino)
            ),
            size: UInt64(max(0, information.st_size)),
            modifiedAt: Date(timeIntervalSince1970: seconds + nanoseconds)
        )
    }
}

struct FileFingerprint: Codable, Equatable, Sendable {
    private static let byteLimit: UInt64 = 4_096
    private static let offsetBasis: UInt64 = 14_695_981_039_346_656_037
    private static let prime: UInt64 = 1_099_511_628_211

    let offset: UInt64
    let length: UInt64
    let hash: UInt64

    static func makePrefix(for url: URL, observedSize: UInt64) -> FileFingerprint? {
        make(
            for: url,
            offset: 0,
            length: min(byteLimit, observedSize)
        )
    }

    static func makeContinuity(for url: URL, observedSize: UInt64) -> FileFingerprint? {
        let length = min(byteLimit, observedSize)
        return make(
            for: url,
            offset: observedSize - length,
            length: length
        )
    }

    func matches(in url: URL) -> Bool {
        guard let current = Self.make(for: url, offset: offset, length: length) else {
            return false
        }
        return current == self
    }

    private static func make(
        for url: URL,
        offset: UInt64,
        length: UInt64
    ) -> FileFingerprint? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }

        do {
            try handle.seek(toOffset: offset)
            let data = try handle.read(upToCount: Int(length)) ?? Data()
            guard data.count == Int(length) else { return nil }
            var value = offsetBasis
            for byte in data {
                value ^= UInt64(byte)
                value &*= prime
            }
            return FileFingerprint(
                offset: offset,
                length: UInt64(data.count),
                hash: value
            )
        } catch {
            return nil
        }
    }
}
