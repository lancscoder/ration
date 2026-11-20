import AppKit
import Foundation
import Observation
import os
import RationCore

/// Checks GitHub Releases for a newer version and installs it in place.
///
/// Install: download the zip and its `.sig`, verify the Ed25519 signature, unzip
/// next to the running app, check the bundle ID and version, swap the bundles
/// atomically and relaunch. Downloads made here aren't quarantined, so the new
/// version opens without another Gatekeeper prompt.
@MainActor
@Observable
final class Updater {
    nonisolated private static let log = Logger(subsystem: Log.subsystem, category: "updates")

    enum Phase: Equatable {
        case idle
        case checking
        case upToDate(Date)
        case available(ReleaseInfo)
        case installing(ReleaseInfo)
        case failed(String)
    }

    private(set) var phase: Phase = .idle
    var automatic: Bool {
        didSet {
            defaults.set(automatic, forKey: "checkForUpdates")
            scheduleTimer()
        }
    }

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var timer: Timer?
    private static let lastCheckKey = "lastUpdateCheck"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: ["checkForUpdates": true])
        automatic = defaults.bool(forKey: "checkForUpdates")
    }

    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    /// Only builds made by `make release` replace themselves; a local `make app`
    /// build points at the release page instead.
    static var canInstallInPlace: Bool {
        guard Bundle.main.object(forInfoDictionaryKey: "RationReleaseBuild") as? Bool == true || feedOverride != nil else { return false }
        let app = Bundle.main.bundleURL
        return app.pathExtension == "app"
            && FileManager.default.isWritableFile(atPath: app.deletingLastPathComponent().path)
            && FileManager.default.isWritableFile(atPath: app.path)
    }

    /// Debug: `RATION_UPDATE_FEED=<url>` reads release info from elsewhere (e.g. a local file).
    private static var feedOverride: URL? {
        ProcessInfo.processInfo.environment["RATION_UPDATE_FEED"].flatMap(URL.init(string:))
    }

    var available: ReleaseInfo? {
        if case .available(let r) = phase { return r }
        return nil
    }

    func start() {
        scheduleTimer()
        // Debug: with a feed override, `--install-update-now` checks and installs at once.
        if Self.feedOverride != nil, CommandLine.arguments.contains("--install-update-now") {
            Task {
                await check()
                if let release = available { await install(release) }
            }
        }
    }

    private func scheduleTimer() {
        timer?.invalidate()
        timer = nil
        guard automatic else { return }
        // Hourly tick; checks only when a day has passed (survives sleep and relaunches).
        timer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkIfDue() }
        }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(20))
            checkIfDue()
        }
    }

    private func checkIfDue() {
        guard automatic else { return }
        let last = defaults.object(forKey: Self.lastCheckKey) as? Date ?? .distantPast
        if Date().timeIntervalSince(last) >= UpdateConfig.checkInterval { Task { await check() } }
    }

    func check() async {
        switch phase {
        case .checking, .installing: return
        default: break
        }
        phase = .checking
        do {
            var request = URLRequest(url: Self.feedOverride ?? UpdateConfig.latestReleaseAPI)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            request.setValue("Ration/\(Self.currentVersion)", forHTTPHeaderField: "User-Agent")
            request.timeoutInterval = 20
            let (data, response) = try await URLSession.shared.data(for: request)
            defaults.set(Date(), forKey: Self.lastCheckKey)
            if let http = response as? HTTPURLResponse, http.statusCode == 404 {
                phase = .upToDate(Date()) // no releases published yet
                return
            }
            if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                throw UpdateError.http(http.statusCode)
            }
            if let release = ReleaseFeed.newer(try ReleaseFeed.parse(data), than: Self.currentVersion) {
                Self.log.info("Update available: \(release.version, privacy: .public)")
                phase = .available(release)
            } else {
                phase = .upToDate(Date())
            }
        } catch {
            Self.log.error("Update check failed: \(error.localizedDescription, privacy: .public)")
            phase = .failed("Couldn't check for updates: \(error.localizedDescription)")
        }
    }

    func install(_ release: ReleaseInfo) async {
        guard Self.canInstallInPlace else {
            NSWorkspace.shared.open(release.page)
            return
        }
        phase = .installing(release)
        do {
            let newApp = try await Self.downloadAndVerify(release)
            try Self.swap(in: newApp)
            Self.log.info("Installed \(release.version, privacy: .public); relaunching")
            Relauncher.relaunch()
        } catch {
            Self.log.error("Update failed: \(error.localizedDescription, privacy: .public)")
            phase = .failed(error.localizedDescription)
        }
    }

    enum UpdateError: LocalizedError {
        case http(Int)
        case insecureURL
        case badSignature
        case notAnUpdate(String)
        case unzip
        var errorDescription: String? {
            switch self {
            case .http(let code): return "GitHub answered with HTTP \(code)."
            case .insecureURL: return "The download link isn't HTTPS, so it wasn't used."
            case .badSignature: return "The download's signature didn't match. Nothing was installed."
            case .notAnUpdate(let why): return "The download isn't a valid Ration update (\(why)). Nothing was installed."
            case .unzip: return "The download couldn't be unpacked. Nothing was installed."
            }
        }
    }

    /// Returns the verified new app bundle, unpacked on the same volume as the running app.
    nonisolated private static func downloadAndVerify(_ release: ReleaseInfo) async throws -> URL {
        let allowFile = ProcessInfo.processInfo.environment["RATION_UPDATE_FEED"] != nil
        for url in [release.zip, release.signature] where url.scheme != "https" && !(allowFile && url.isFileURL) {
            throw UpdateError.insecureURL
        }
        let zip = try await fetch(release.zip)
        let signature = String(decoding: try await fetch(release.signature), as: UTF8.self)
        guard UpdateSignature.verify(zip, signature: signature) else { throw UpdateError.badSignature }

        let fm = FileManager.default
        let current = Bundle.main.bundleURL
        let staging = try fm.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: current, create: true)
        let zipFile = staging.appendingPathComponent(ReleaseInfo.zipName(for: release.version))
        try zip.write(to: zipFile)
        try run("/usr/bin/ditto", ["-x", "-k", zipFile.path, staging.appendingPathComponent("unpacked").path])
        let newApp = staging.appendingPathComponent("unpacked/Ration.app")

        guard let info = NSDictionary(contentsOf: newApp.appendingPathComponent("Contents/Info.plist")) else {
            throw UpdateError.notAnUpdate("no app inside")
        }
        guard info["CFBundleIdentifier"] as? String == Bundle.main.bundleIdentifier else { throw UpdateError.notAnUpdate("different app") }
        guard info["CFBundleShortVersionString"] as? String == release.version else { throw UpdateError.notAnUpdate("version mismatch") }
        // Catches a damaged bundle (the signature is ad hoc, so this checks integrity, not identity).
        try run("/usr/bin/codesign", ["--verify", "--deep", "--strict", newApp.path])
        return newApp
    }

    nonisolated private static func fetch(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.timeoutInterval = 120
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 { throw UpdateError.http(http.statusCode) }
        return data
    }

    /// Atomically exchanges the running bundle with the new one; the old one ends up in the staging folder.
    nonisolated private static func swap(in newApp: URL) throws {
        _ = try FileManager.default.replaceItemAt(Bundle.main.bundleURL, withItemAt: newApp,
                                                  backupItemName: nil, options: [])
    }

    nonisolated private static func run(_ tool: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw tool.hasSuffix("ditto") ? UpdateError.unzip : UpdateError.notAnUpdate("bundle check failed")
        }
    }
}
