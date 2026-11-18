import Foundation
import os

public struct LogSnapshot: Sendable {
    /// Deduplicated, sorted by time.
    public var records: [UsageRecord]
    /// sessionId → working directory (from the log lines).
    public var sessionCwds: [String: String]
    /// sessionId → top-level `<sessionId>.jsonl` transcript.
    public var sessionFiles: [String: URL]
    public var fileCount: Int
    public var scannedAt: Date

    public static let empty = LogSnapshot(records: [], sessionCwds: [:], sessionFiles: [:], fileCount: 0, scannedAt: .distantPast)
}

/// Incrementally scans `<root>/projects/**/*.jsonl`. Each file's byte offset,
/// size, mtime, inode and parsed records are cached in
/// `~/Library/Caches/<bundle-id>/tokens.json`, so a refresh only reads lines
/// appended since the last one.
public actor LogStore {
    private static let log = Logger(subsystem: Log.subsystem, category: "logs")
    static let cacheVersion = 1

    struct FileState: Codable {
        var offset: UInt64
        var size: UInt64
        var mtime: Double
        var inode: UInt64
        var records: [UsageRecord]
        var cwd: String?
        var sessionId: String?
    }

    private struct CacheFile: Codable {
        var version: Int
        var files: [String: FileState]
    }

    private let roots: [URL]
    private let cacheURL: URL?
    private var files: [String: FileState] = [:]
    private var loaded = false
    private var changedSinceSave = false
    private var lastSave = Date.distantPast
    private var snapshot: LogSnapshot?
    private let saveInterval: TimeInterval

    /// - Parameters:
    ///   - projectRoots: directories containing `<encoded-project>/<session>.jsonl`.
    ///   - cacheURL: where to persist parse state; nil disables persistence (tests).
    public init(projectRoots: [URL] = LogStore.defaultProjectRoots(),
                cacheURL: URL? = AppPaths.cacheDirectory.appendingPathComponent("tokens.json"),
                saveInterval: TimeInterval = 300) {
        self.roots = projectRoots
        self.cacheURL = cacheURL
        self.saveInterval = saveInterval
    }

    public static func defaultProjectRoots() -> [URL] {
        AppPaths.claudeRoots().map { $0.appendingPathComponent("projects", isDirectory: true) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    public var watchedPaths: [String] { roots.map(\.path) }

    /// Scans for new/changed files and returns the merged snapshot.
    public func refresh(now: Date = Date()) -> LogSnapshot {
        loadCacheIfNeeded()
        var seen = Set<String>()
        var changed = false
        let start = Date()

        for root in roots {
            for path in Self.jsonlFiles(under: root) {
                seen.insert(path)
                if update(path: path) { changed = true }
            }
        }
        let removed = Set(files.keys).subtracting(seen)
        if !removed.isEmpty {
            for p in removed { files.removeValue(forKey: p) }
            changed = true
        }

        if changed || snapshot == nil {
            changedSinceSave = changedSinceSave || changed
            snapshot = buildSnapshot(now: now)
            Self.log.debug("log refresh: \(self.files.count) files, \(self.snapshot?.records.count ?? 0) records in \(Int(Date().timeIntervalSince(start) * 1000)) ms")
        }
        if changedSinceSave, now.timeIntervalSince(lastSave) >= saveInterval {
            save(now: now)
        }
        return snapshot!
    }

    /// Persists the parse cache if anything changed (call at quit).
    public func flush() {
        if changedSinceSave { save(now: Date()) }
    }

    // MARK: - Internals

    /// Returns true if the file's records changed.
    private func update(path: String) -> Bool {
        var st = stat()
        guard stat(path, &st) == 0 else { return false }
        let size = UInt64(st.st_size)
        let mtime = Double(st.st_mtimespec.tv_sec) + Double(st.st_mtimespec.tv_nsec) / 1e9
        let inode = UInt64(st.st_ino)

        if var state = files[path], state.inode == inode, size >= state.offset {
            if size == state.size && mtime == state.mtime { return false }
            var appended = false
            if size > state.offset {
                appended = read(path: path, into: &state)
            }
            state.size = size
            state.mtime = mtime
            files[path] = state
            return appended
        }

        // New, replaced or truncated file: full scan.
        var state = FileState(offset: 0, size: size, mtime: mtime, inode: inode, records: [], cwd: nil, sessionId: nil)
        _ = read(path: path, into: &state)
        files[path] = state
        return true
    }

    private func read(path: String, into state: inout FileState) -> Bool {
        guard let handle = FileHandle(forReadingAtPath: path) else { return false }
        defer { try? handle.close() }
        do {
            try handle.seek(toOffset: state.offset)
            guard let data = try handle.readToEnd(), !data.isEmpty else { return false }
            let (lines, consumed) = data.withUnsafeBytes { LogParser.parseChunk($0) }
            state.offset += UInt64(consumed)
            for line in lines {
                state.records.append(line.record)
                if state.cwd == nil, let cwd = line.cwd, !cwd.isEmpty { state.cwd = cwd }
                if state.sessionId == nil, !line.record.sessionId.isEmpty { state.sessionId = line.record.sessionId }
            }
            return !lines.isEmpty
        } catch {
            Self.log.error("read failed for \(path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    private func buildSnapshot(now: Date) -> LogSnapshot {
        let records = UsageDeduplicator.merge(files.values.lazy.map(\.records))
        var cwds: [String: String] = [:]
        var subagentCwds: [String: String] = [:]
        var sessionFiles: [String: URL] = [:]
        for (path, state) in files {
            let url = URL(fileURLWithPath: path)
            // Top-level transcripts are named after their session; subagent logs live deeper
            // and share the parent's sessionId, but may run in a worktree with a different cwd.
            let isTopLevel = url.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent == "projects"
            if isTopLevel {
                sessionFiles[url.deletingPathExtension().lastPathComponent] = url
            }
            guard let sid = state.sessionId, let cwd = state.cwd else { continue }
            if isTopLevel {
                cwds[sid] = cwd
            } else if subagentCwds[sid] == nil {
                subagentCwds[sid] = cwd
            }
        }
        // A subagent's cwd is only a fallback when the main transcript is missing.
        cwds.merge(subagentCwds) { main, _ in main }
        return LogSnapshot(records: records, sessionCwds: cwds, sessionFiles: sessionFiles, fileCount: files.count, scannedAt: now)
    }

    private static func jsonlFiles(under root: URL) -> [String] {
        guard let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey],
                                                     options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
        var out: [String] = []
        for case let url as URL in e where url.pathExtension == "jsonl" {
            out.append(url.path)
        }
        return out
    }

    private func loadCacheIfNeeded() {
        guard !loaded else { return }
        loaded = true
        guard let cacheURL, let data = try? Data(contentsOf: cacheURL) else { return }
        guard let cache = try? JSONDecoder().decode(CacheFile.self, from: data), cache.version == Self.cacheVersion else {
            Self.log.notice("token cache unreadable or outdated; rescanning")
            return
        }
        files = cache.files
        lastSave = Date()
    }

    private func save(now: Date) {
        guard let cacheURL else { return }
        do {
            try FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(CacheFile(version: Self.cacheVersion, files: files))
            try data.write(to: cacheURL, options: .atomic)
            lastSave = now
            changedSinceSave = false
        } catch {
            Self.log.error("token cache save failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
