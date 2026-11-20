import Foundation
import os

/// One observation of the quota, used for burn-rate maths.
public struct QuotaSample: Codable, Sendable, Equatable {
    public var t: Date
    public var fiveHour: Double?
    public var fiveHourResetsAt: Date?
    public var weekly: Double?
    public var weeklyResetsAt: Date?

    public init(t: Date, fiveHour: Double?, fiveHourResetsAt: Date?, weekly: Double? = nil, weeklyResetsAt: Date? = nil) {
        self.t = t
        self.fiveHour = fiveHour
        self.fiveHourResetsAt = fiveHourResetsAt
        self.weekly = weekly
        self.weeklyResetsAt = weeklyResetsAt
    }

    public init(response: UsageResponse, at t: Date) {
        self.init(
            t: t,
            fiveHour: response.session?.utilization,
            fiveHourResetsAt: response.session?.resetsAt,
            weekly: response.weekly?.utilization,
            weeklyResetsAt: response.weekly?.resetsAt
        )
    }
}

/// Disk cache for the last good usage response and the rolling quota samples.
/// Lives in `~/Library/Caches/<bundle-id>/`.
public actor UsageCache {
    private static let log = Logger(subsystem: Log.subsystem, category: "cache")
    public static let sampleRetention: TimeInterval = 48 * 3600

    private let directory: URL
    private var usageURL: URL { directory.appendingPathComponent("usage.json") }
    private var samplesURL: URL { directory.appendingPathComponent("quota-samples.json") }
    private var samples: [QuotaSample]?

    public init(directory: URL = AppPaths.cacheDirectory) {
        self.directory = directory
    }

    public struct Cached: Sendable {
        public var response: UsageResponse
        public var fetchedAt: Date
    }

    public func loadUsage() -> Cached? {
        guard let data = try? Data(contentsOf: usageURL),
              let response = try? UsageResponse.decode(data) else { return nil }
        let attrs = try? FileManager.default.attributesOfItem(atPath: usageURL.path)
        let fetchedAt = (attrs?[.modificationDate] as? Date) ?? .distantPast
        return Cached(response: response, fetchedAt: fetchedAt)
    }

    public func saveUsage(_ raw: Data, fetchedAt: Date) {
        do {
            try ensureDirectory()
            try raw.write(to: usageURL, options: .atomic)
            try FileManager.default.setAttributes([.modificationDate: fetchedAt, .posixPermissions: 0o600], ofItemAtPath: usageURL.path)
        } catch {
            Self.log.error("failed to write usage cache: \(error.localizedDescription, privacy: .public)")
        }
    }

    public func loadSamples() -> [QuotaSample] {
        if let samples { return samples }
        let loaded = (try? Data(contentsOf: samplesURL)).flatMap { try? JSONDecoder().decode([QuotaSample].self, from: $0) } ?? []
        samples = loaded
        return loaded
    }

    @discardableResult
    public func appendSample(_ sample: QuotaSample) -> [QuotaSample] {
        var all = loadSamples()
        let cutoff = sample.t.addingTimeInterval(-Self.sampleRetention)
        all.removeAll { $0.t < cutoff }
        all.append(sample)
        all.sort { $0.t < $1.t }
        if all.count > 2000 { all.removeFirst(all.count - 2000) }
        samples = all
        do {
            try ensureDirectory()
            try JSONEncoder().encode(all).write(to: samplesURL, options: .atomic)
        } catch {
            Self.log.error("failed to write samples: \(error.localizedDescription, privacy: .public)")
        }
        return all
    }

    private func ensureDirectory() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }
}
