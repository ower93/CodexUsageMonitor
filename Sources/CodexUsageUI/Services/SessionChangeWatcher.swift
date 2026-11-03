import CoreServices
import Darwin
import Foundation

/// One recursive, coalesced stream; never one file descriptor per session log.
final class SessionChangeWatcher {
    private var stream: FSEventStreamRef?
    var isActive: Bool { stream != nil }

    init(home: URL = CodexEnvironment.home(), changed: @escaping @Sendable () -> Void) {
        guard FileManager.default.fileExists(atPath: home.path) else { return }
        // Foundation may shorten /private/var back to /var. FSEvents emits the
        // POSIX real path, so normalize with realpath on registration instead.
        let watchedPath = home.withUnsafeFileSystemRepresentation { pointer -> String in
            guard let pointer, let resolved = Darwin.realpath(pointer, nil) else { return home.path }
            defer { free(resolved) }
            return String(cString: resolved)
        }
        let callback = Callback(home: watchedPath, changed: changed)
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(callback).toOpaque(),
            retain: { pointer in
                guard let pointer else { return nil }
                _ = Unmanaged<Callback>.fromOpaque(pointer).retain()
                return pointer
            }, release: { pointer in
                if let pointer { Unmanaged<Callback>.fromOpaque(pointer).release() }
            }, copyDescription: nil)
        stream = FSEventStreamCreate(nil, { _, info, count, paths, _, _ in
            guard let info else { return }
            let callback = Unmanaged<Callback>.fromOpaque(info).takeUnretainedValue()
            let values = paths.assumingMemoryBound(to: UnsafePointer<CChar>.self)
            for index in 0..<count {
                let path = String(cString: values[index])
                if callback.includes(path) { callback.changed(); break }
            }
        }, &context, [watchedPath] as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
        3, FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagWatchRoot))
        guard let stream else { return }
        FSEventStreamSetDispatchQueue(stream, DispatchQueue(label: "com.kevinchen.CodexUsageMonitor.files", qos: .utility))
        if !FSEventStreamStart(stream) { stop() }
    }

    deinit { stop() }

    func stop() {
        guard let stream else { return }
        self.stream = nil
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
    }

    private final class Callback {
        let home: String
        let changed: @Sendable () -> Void
        init(home: String, changed: @escaping @Sendable () -> Void) { self.home = home; self.changed = changed }
        func includes(_ path: String) -> Bool {
            path == home || path == home + "/session_index.jsonl"
                || path == home + "/sessions" || path.hasPrefix(home + "/sessions/")
                || path == home + "/archived_sessions" || path.hasPrefix(home + "/archived_sessions/")
        }
    }
}
