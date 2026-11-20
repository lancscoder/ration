import CryptoKit
import Foundation

// Self-update from GitHub Releases.
//
// Each release carries `Ration-<version>.zip` and `Ration-<version>.zip.sig`, an
// Ed25519 signature of the zip made with the maintainer's private key (kept off
// the repo; see `scripts/update-signing.swift`). The app only installs a zip whose
// signature checks out against the public key below, so a swapped release asset
// can't push code to users even though the app itself isn't Apple-signed.

public enum UpdateConfig {
    public static let repository = "lancscoder/ration"
    public static let latestReleaseAPI = URL(string: "https://api.github.com/repos/\(repository)/releases/latest")!
    public static let releasesPage = URL(string: "https://github.com/\(repository)/releases")!
    /// Base64 raw Ed25519 public key matching the maintainer's signing key.
    public static let publicKey = "2Ij39MoSLaGZnkTaPWM6qdFD2HJcH2GF+8Ubs/sOPlU="
    /// How often the automatic check runs.
    public static let checkInterval: TimeInterval = 24 * 3600
}

/// `major.minor.patch`, compared numerically. Accepts a leading "v".
public struct AppVersion: Comparable, Sendable, CustomStringConvertible {
    public let parts: [Int]

    public init?(_ string: String) {
        var s = string.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("v") || s.hasPrefix("V") { s.removeFirst() }
        let parts = s.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
        guard !parts.isEmpty, parts.count <= 4, parts.allSatisfy({ $0 != nil && $0! >= 0 }) else { return nil }
        self.parts = parts.map { $0! }
    }

    public var description: String { parts.map(String.init).joined(separator: ".") }

    public static func < (a: AppVersion, b: AppVersion) -> Bool {
        let n = max(a.parts.count, b.parts.count)
        for i in 0..<n {
            let x = i < a.parts.count ? a.parts[i] : 0
            let y = i < b.parts.count ? b.parts[i] : 0
            if x != y { return x < y }
        }
        return false
    }

    public static func == (a: AppVersion, b: AppVersion) -> Bool { !(a < b) && !(b < a) }
}

/// The parts of a GitHub release the updater needs.
public struct ReleaseInfo: Sendable, Equatable {
    public var version: String
    public var notes: String
    public var page: URL
    public var zip: URL
    public var signature: URL

    public init(version: String, notes: String, page: URL, zip: URL, signature: URL) {
        self.version = version
        self.notes = notes
        self.page = page
        self.zip = zip
        self.signature = signature
    }

    public static func zipName(for version: String) -> String { "Ration-\(version).zip" }
}

public enum ReleaseFeed {
    public enum FeedError: LocalizedError, Equatable {
        case unreadable
        case missingAssets(String)
        public var errorDescription: String? {
            switch self {
            case .unreadable: return "The release information couldn't be read."
            case .missingAssets(let v): return "Release \(v) has no signed download yet."
            }
        }
    }

    private struct APIRelease: Decodable {
        struct Asset: Decodable {
            let name: String
            let browser_download_url: URL
        }
        let tag_name: String
        let html_url: URL
        let body: String?
        let draft: Bool?
        let prerelease: Bool?
        let assets: [Asset]
    }

    /// Parses GitHub's "latest release" response. Returns nil for drafts, pre-releases
    /// and tags that aren't a version.
    public static func parse(_ data: Data) throws -> ReleaseInfo? {
        guard let release = try? JSONDecoder().decode(APIRelease.self, from: data) else { throw FeedError.unreadable }
        guard release.draft != true, release.prerelease != true,
              let version = AppVersion(release.tag_name) else { return nil }
        let name = ReleaseInfo.zipName(for: version.description)
        guard let zip = release.assets.first(where: { $0.name == name }),
              let sig = release.assets.first(where: { $0.name == name + ".sig" }) else {
            throw FeedError.missingAssets(version.description)
        }
        return ReleaseInfo(version: version.description, notes: release.body ?? "", page: release.html_url,
                           zip: zip.browser_download_url, signature: sig.browser_download_url)
    }

    /// The release, if it is newer than `current`.
    public static func newer(_ release: ReleaseInfo?, than current: String) -> ReleaseInfo? {
        guard let release, let new = AppVersion(release.version), let cur = AppVersion(current), cur < new else { return nil }
        return release
    }
}

public enum UpdateSignature {
    /// Verifies a base64 Ed25519 signature (the `.sig` file's contents) over `data`.
    public static func verify(_ data: Data, signature: String, publicKey: String = UpdateConfig.publicKey) -> Bool {
        guard let keyData = Data(base64Encoded: publicKey.trimmingCharacters(in: .whitespacesAndNewlines)),
              let sigData = Data(base64Encoded: signature.trimmingCharacters(in: .whitespacesAndNewlines)),
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: keyData) else { return false }
        return key.isValidSignature(sigData, for: data)
    }

    /// Signs `data` with a base64 raw private key. Used by the release script and tests.
    public static func sign(_ data: Data, privateKey: String) throws -> String {
        guard let raw = Data(base64Encoded: privateKey.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw ReleaseFeed.FeedError.unreadable
        }
        let key = try Curve25519.Signing.PrivateKey(rawRepresentation: raw)
        return try key.signature(for: data).base64EncodedString()
    }
}
