import Foundation
import Testing
@testable import ClaudeBarCore

@Suite("Usage response decoding")
struct UsageDecodingTests {
    @Test func decodesCapturedSample() throws {
        let r = try UsageResponse.decode(Fixture.data("usage_response.json"))
        #expect(r.fiveHour?.utilization == 9)
        #expect(r.sevenDay?.utilization == 50)
        #expect(r.sevenDayOpus == nil)
        #expect(r.sevenDaySonnet == nil)
        // Microsecond timestamps parse.
        let reset = try #require(r.fiveHour?.resetsAt)
        #expect(abs(reset.timeIntervalSince1970 - (date("2026-11-17T19:10:00Z").timeIntervalSince1970 + 0.059793)) < 0.001)
        #expect(r.limits.count == 3)
        #expect(r.breakdown.first?.displayName == "Claude Code")
    }

    @Test func modelLimitsComeFromScopedLimits() throws {
        let r = try UsageResponse.decode(Fixture.data("usage_response.json"))
        let models = r.modelLimits
        #expect(models.count == 1)
        #expect(models.first?.title == "Fable weekly")
        #expect(models.first?.utilization == 22)
    }

    @Test func extraUsageUsesMinorUnits() throws {
        let r = try UsageResponse.decode(Fixture.data("usage_response.json"))
        let extra = try #require(r.extraUsage)
        #expect(extra.isEnabled == false)
        #expect(extra.limitAmount == 37.5)
        #expect(extra.usedAmount == 0)
        #expect(extra.currency == "GBP")
    }

    @Test func toleratesMissingAndMalformedBlocks() throws {
        let json = """
        {"five_hour": {"utilization": "oops"}, "seven_day": {"utilization": 12, "resets_at": null},
         "seven_day_opus": {"utilization": 40, "resets_at": "2026-11-19T17:00:00Z"},
         "limits": [42, {"kind": "weekly_scoped", "percent": 5, "scope": {"model": {"display_name": "Opus"}}}],
         "extra_usage": "nope", "brand_new_field": {"x": 1}}
        """
        let r = try UsageResponse.decode(Data(json.utf8))
        #expect(r.fiveHour == nil)
        #expect(r.sevenDay?.utilization == 12)
        #expect(r.sevenDay?.resetsAt == nil)
        #expect(r.extraUsage == nil)
        #expect(r.limits.count == 1)
        // Scoped "Opus" wins over legacy seven_day_opus; no duplicate.
        #expect(r.modelLimits.map(\.title) == ["Opus weekly"])
        #expect(r.session == nil)
    }

    @Test func legacyModelBlocksStillShow() throws {
        let json = #"{"seven_day_sonnet": {"utilization": 33, "resets_at": "2026-11-19T17:00:00+00:00"}}"#
        let r = try UsageResponse.decode(Data(json.utf8))
        #expect(r.modelLimits.map(\.title) == ["Sonnet weekly"])
    }

    @Test func emptyObjectDecodes() throws {
        let r = try UsageResponse.decode(Data("{}".utf8))
        #expect(r.session == nil && r.weekly == nil && r.modelLimits.isEmpty)
    }

    @Test func sessionFallsBackToLimitsArray() throws {
        let json = #"{"limits": [{"kind": "session", "percent": 61, "resets_at": "2026-11-17T19:10:00Z"}, {"kind": "weekly_all", "percent": 50}]}"#
        let r = try UsageResponse.decode(Data(json.utf8))
        #expect(r.session?.utilization == 61)
        #expect(r.weekly?.utilization == 50)
    }
}

@Suite("ISO date parsing")
struct ISODateTests {
    @Test(arguments: [
        ("2026-11-16T10:11:56.385Z", 1794823916.385),
        ("2026-11-17T19:10:00.059793+00:00", 1794942600.059793),
        ("2026-11-17T20:10:00+01:00", 1794942600.0),
        ("2026-11-17T19:10:00Z", 1794942600.0),
        ("2024-02-29T00:00:00Z", 1709164800.0),
    ])
    func parses(input: String, expected: Double) throws {
        let d = try #require(ISODate.parse(input))
        #expect(abs(d.timeIntervalSince1970 - expected) < 0.0005)
    }

    @Test(arguments: ["", "garbage", "2026-13-01T00:00:00Z", "2026-11-17T19:10:00Q", "2026-11-17"])
    func rejects(input: String) {
        #expect(ISODate.parse(input) == nil)
    }

    @Test func matchesFoundation() {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let s = "2025-03-09T07:59:59.123Z"
        #expect(abs(ISODate.parse(s)!.timeIntervalSince1970 - f.date(from: s)!.timeIntervalSince1970) < 0.0005)
    }
}

@Suite("Backoff and Retry-After")
struct BackoffTests {
    @Test func clampsPollInterval() {
        #expect(BackoffPolicy(baseInterval: 30).baseInterval == 300)
        #expect(BackoffPolicy(baseInterval: 600).baseInterval == 600)
    }

    @Test func exponentialWithCap() {
        var b = BackoffPolicy(baseInterval: 300, maxInterval: 3600)
        #expect(b.recordFailure() == 600)
        #expect(b.recordFailure() == 1200)
        #expect(b.recordFailure() == 2400)
        #expect(b.recordFailure() == 3600)
        #expect(b.recordFailure() == 3600)
        b.recordSuccess()
        #expect(b.failures == 0)
        #expect(b.recordFailure() == 600)
    }

    @Test func honoursLongerRetryAfter() {
        var b = BackoffPolicy(baseInterval: 300)
        #expect(b.recordFailure(retryAfter: 990) == 990)
        #expect(b.recordFailure(retryAfter: 10) == 1200)
        #expect(b.recordFailure(retryAfter: 7200) == 7200)
    }

    @Test func parsesRetryAfter() {
        #expect(UsageAPIClient.parseRetryAfter("990") == 990)
        #expect(UsageAPIClient.parseRetryAfter(nil) == nil)
        #expect(UsageAPIClient.parseRetryAfter("soon") == nil)
        let now = date("2026-11-17T15:00:00Z")
        #expect(UsageAPIClient.parseRetryAfter("Tue, 17 Nov 2026 15:10:00 GMT", now: now) == 600)
    }

    @Test func staleness() {
        let now = date("2026-11-17T15:00:00Z")
        var s = UsageSnapshot(response: UsageResponse(), fetchedAt: now.addingTimeInterval(-60), status: .ok)
        #expect(!s.isStale(now: now))
        s.fetchedAt = now.addingTimeInterval(-16 * 60)
        #expect(s.isStale(now: now))
        s.fetchedAt = now
        s.status = .rateLimited(until: now.addingTimeInterval(600))
        #expect(s.isStale(now: now))
    }
}

@Suite("Credentials")
struct CredentialTests {
    let sample = #"{"claudeAiOauth":{"accessToken":"sk-ant-oat01-SECRET","refreshToken":"r","expiresAt":1794945459000,"subscriptionType":"max","rateLimitTier":"default_claude_max_5x","scopes":["user:inference"]},"mcpOAuth":{}}"#

    @Test func parsesKeychainBlob() throws {
        let c = try OAuthCredentials.parse(Data(sample.utf8))
        #expect(c.accessToken == "sk-ant-oat01-SECRET")
        #expect(c.planLabel == "Max 5x")
        #expect(c.expiresAt == Date(timeIntervalSince1970: 1794945459))
        #expect(c.isExpired(at: Date(timeIntervalSince1970: 1794945459 + 1)))
        #expect(!c.isExpired(at: Date(timeIntervalSince1970: 1794945459 - 3600)))
    }

    @Test func neverPrintsToken() throws {
        let c = try OAuthCredentials.parse(Data(sample.utf8))
        #expect(!"\(c)".contains("SECRET"))
        #expect(!String(reflecting: c).contains("SECRET"))
    }

    @Test func rejectsStub() {
        #expect(throws: CredentialError.malformed) { try OAuthCredentials.parse(Data("{}".utf8)) }
        #expect(throws: CredentialError.malformed) { try OAuthCredentials.parse(Data(#"{"claudeAiOauth":{"accessToken":""}}"#.utf8)) }
    }

    @Test func scopedServiceName() {
        #expect(CredentialStore.serviceName(forConfigDir: nil) == "Claude Code-credentials")
        // sha256("/Users/me/.claude-work") = 4d5b2a3c...; first 8 hex chars
        let name = CredentialStore.serviceName(forConfigDir: "/Users/me/.claude-work")
        #expect(name.hasPrefix("Claude Code-credentials-"))
        #expect(name.count == "Claude Code-credentials-".count + 8)
        let store = CredentialStore(configDir: "/Users/me/.claude-work")
        #expect(store.keychainServices == [name, "Claude Code-credentials"])
        #expect(CredentialStore(configDir: "  ").keychainServices == ["Claude Code-credentials"])
    }

    @Test func hexDecoding() {
        #expect(Data(hexString: "7b7d") == Data("{}".utf8))
        #expect(Data(hexString: "zz") == nil)
    }
}
