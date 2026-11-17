import CryptoKit
import Foundation
import os

/// Claude Code's OAuth login, as read from the Keychain (or the legacy file).
/// `description` is redacted so the token can never end up in a log.
public struct OAuthCredentials: Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible {
    public let accessToken: String
    public let expiresAt: Date?
    public let subscriptionType: String?
    public let rateLimitTier: String?

    public init(accessToken: String, expiresAt: Date?, subscriptionType: String?, rateLimitTier: String?) {
        self.accessToken = accessToken
        self.expiresAt = expiresAt
        self.subscriptionType = subscriptionType
        self.rateLimitTier = rateLimitTier
    }

    public func isExpired(at now: Date = Date(), skew: TimeInterval = 30) -> Bool {
        guard let expiresAt else { return false }
        return expiresAt <= now.addingTimeInterval(skew)
    }

    /// e.g. "Max 5x", "Pro".
    public var planLabel: String? {
        let base = subscriptionType.map { $0.prefix(1).uppercased() + $0.dropFirst() }
        if let tier = rateLimitTier,
           let range = tier.range(of: #"max_(\d+x)"#, options: [.regularExpression, .caseInsensitive]) {
            let mult = tier[range].dropFirst(4)
            return "\(base ?? "Max") \(mult)"
        }
        return base
    }

    public var description: String {
        "OAuthCredentials(token: <redacted>, expiresAt: \(expiresAt.map { "\($0)" } ?? "nil"), plan: \(planLabel ?? "?"))"
    }
    public var debugDescription: String { description }

    /// Parses `{"claudeAiOauth": {...}}`.
    public static func parse(_ data: Data) throws -> OAuthCredentials {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = root["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String, !token.isEmpty
        else { throw CredentialError.malformed }
        var expires: Date?
        if let ms = (oauth["expiresAt"] as? NSNumber)?.doubleValue, ms > 0 {
            expires = Date(timeIntervalSince1970: ms > 1e12 ? ms / 1000 : ms)
        }
        return OAuthCredentials(
            accessToken: token,
            expiresAt: expires,
            subscriptionType: oauth["subscriptionType"] as? String,
            rateLimitTier: oauth["rateLimitTier"] as? String
        )
    }
}

public enum CredentialError: Error, Equatable, Sendable {
    case notFound
    case accessDenied(String)
    case malformed
}

/// Reads Claude Code's credentials. **Read-only**: it never refreshes the
/// token or writes to the Keychain, so it cannot race Claude Code's own
/// refresh and log the user out.
///
/// Lookup order (mirrors `ai-usagebar`):
/// 1. Keychain service `Claude Code-credentials-<sha256(configDir)[0..8]>` when `CLAUDE_CONFIG_DIR` is set
/// 2. Keychain service `Claude Code-credentials`
/// 3. `<configDir or ~/.claude>/.credentials.json` (often a stale stub on macOS)
///
/// A Keychain that refuses access is reported as such rather than silently
/// falling back to a stale file.
public struct CredentialStore: Sendable {
    public static let baseService = "Claude Code-credentials"
    private static let log = Logger(subsystem: Log.subsystem, category: "credentials")

    public var configDir: String?

    public init(configDir: String? = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"]) {
        let trimmed = configDir?.trimmingCharacters(in: .whitespaces)
        self.configDir = (trimmed?.isEmpty ?? true) ? nil : (trimmed! as NSString).expandingTildeInPath
    }

    public static func serviceName(forConfigDir dir: String?) -> String {
        guard let dir, !dir.isEmpty else { return baseService }
        let digest = SHA256.hash(data: Data(dir.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return "\(baseService)-\(hex.prefix(8))"
    }

    var keychainServices: [String] {
        var s: [String] = []
        if let configDir { s.append(Self.serviceName(forConfigDir: configDir)) }
        s.append(Self.baseService)
        return s
    }

    var credentialFiles: [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        var dirs: [URL] = []
        if let configDir { dirs.append(URL(fileURLWithPath: configDir)) }
        dirs.append(home.appendingPathComponent(".claude"))
        return dirs.map { $0.appendingPathComponent(".credentials.json") }
    }

    /// Blocking: spawns `/usr/bin/security`. Call off the main thread.
    public func load() throws -> OAuthCredentials {
        for service in keychainServices {
            do {
                let data = try Self.readKeychain(service: service)
                if let creds = try? OAuthCredentials.parse(data) {
                    Self.log.debug("credentials loaded from keychain service \(service, privacy: .public)")
                    return creds
                }
            } catch CredentialError.notFound {
                continue
            }
        }
        for file in credentialFiles {
            if let data = try? Data(contentsOf: file), let creds = try? OAuthCredentials.parse(data) {
                Self.log.debug("credentials loaded from \(file.path, privacy: .public)")
                return creds
            }
        }
        throw CredentialError.notFound
    }

    static func readKeychain(service: String) throws -> Data {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        p.arguments = ["find-generic-password", "-s", service, "-w"]
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        do { try p.run() } catch { throw CredentialError.accessDenied("could not run security: \(error.localizedDescription)") }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        _ = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        switch p.terminationStatus {
        case 0: break
        case 44: throw CredentialError.notFound // errSecItemNotFound
        default: throw CredentialError.accessDenied("security exited \(p.terminationStatus)")
        }
        var trimmed = data
        while let last = trimmed.last, last == 0x0A || last == 0x0D { trimmed.removeLast() }
        // `security -w` prints hex when the secret contains non-printable bytes.
        if trimmed.first != UInt8(ascii: "{"), let decoded = Data(hexString: String(decoding: trimmed, as: UTF8.self)) {
            return decoded
        }
        return trimmed
    }
}

extension Data {
    init?(hexString: String) {
        let chars = Array(hexString.utf8)
        guard chars.count % 2 == 0, !chars.isEmpty else { return nil }
        var bytes = [UInt8]()
        bytes.reserveCapacity(chars.count / 2)
        func val(_ c: UInt8) -> UInt8? {
            switch c {
            case 48...57: return c - 48
            case 97...102: return c - 87
            case 65...70: return c - 55
            default: return nil
            }
        }
        var i = 0
        while i < chars.count {
            guard let hi = val(chars[i]), let lo = val(chars[i + 1]) else { return nil }
            bytes.append(hi << 4 | lo)
            i += 2
        }
        self.init(bytes)
    }
}
