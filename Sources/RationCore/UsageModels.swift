import Foundation

// Models for the undocumented `GET /api/oauth/usage` response.
//
// Captured shape (Nov 2026, Max 5x):
//   five_hour / seven_day:        { utilization, resets_at, ... }
//   seven_day_opus / _sonnet:     null (model limits moved to `limits[]`)
//   limits[]:                     { kind: session|weekly_all|weekly_scoped, percent, resets_at,
//                                   severity, scope: { model: { id, display_name } } }
//   extra_usage:                  { is_enabled, monthly_limit, used_credits, currency, decimal_places, ... }
//   seven_day_breakdown.rows[]:   { key, display_name, percent }
//   ...plus ~25 codename keys that are null and ignored.
//
// Everything decodes tolerantly: unknown keys are ignored, a malformed block
// becomes nil, and a malformed array element is skipped.

/// A single utilisation window (5-hour, weekly, per-model weekly).
public struct UsageWindow: Decodable, Sendable, Equatable {
    /// Percent used, 0–100.
    public var utilization: Double
    public var resetsAt: Date?

    public init(utilization: Double, resetsAt: Date?) {
        self.utilization = utilization
        self.resetsAt = resetsAt
    }

    enum CodingKeys: String, CodingKey { case utilization, resets_at }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard let u = c.lossy(Double.self, .utilization) else {
            throw DecodingError.dataCorruptedError(forKey: .utilization, in: c, debugDescription: "missing utilization")
        }
        utilization = u
        resetsAt = c.lossyDate(.resets_at)
    }
}

/// One entry from the `limits[]` array.
public struct LimitEntry: Decodable, Sendable, Equatable {
    public var kind: String?
    public var group: String?
    public var percent: Double?
    public var severity: String?
    public var resetsAt: Date?
    public var modelID: String?
    public var modelDisplayName: String?
    public var isActive: Bool?

    enum CodingKeys: String, CodingKey { case kind, group, percent, severity, resets_at, scope, is_active }
    enum ScopeKeys: String, CodingKey { case model }
    enum ModelKeys: String, CodingKey { case id, display_name }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = c.lossy(String.self, .kind)
        group = c.lossy(String.self, .group)
        percent = c.lossy(Double.self, .percent)
        severity = c.lossy(String.self, .severity)
        resetsAt = c.lossyDate(.resets_at)
        isActive = c.lossy(Bool.self, .is_active)
        if let scope = try? c.nestedContainer(keyedBy: ScopeKeys.self, forKey: .scope),
           let model = try? scope.nestedContainer(keyedBy: ModelKeys.self, forKey: .model) {
            modelID = model.lossy(String.self, .id)
            modelDisplayName = model.lossy(String.self, .display_name)
        }
    }
}

/// Pay-as-you-go "extra usage" credits. Amounts are in minor units
/// (e.g. 3750 with `decimalPlaces` 2 = 37.50).
public struct ExtraUsage: Decodable, Sendable, Equatable {
    public var isEnabled: Bool?
    public var monthlyLimit: Double?
    public var usedCredits: Double?
    public var utilization: Double?
    public var currency: String?
    public var decimalPlaces: Int?
    public var disabledReason: String?

    enum CodingKeys: String, CodingKey {
        case is_enabled, monthly_limit, used_credits, utilization, currency, decimal_places, disabled_reason
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        isEnabled = c.lossy(Bool.self, .is_enabled)
        monthlyLimit = c.lossy(Double.self, .monthly_limit)
        usedCredits = c.lossy(Double.self, .used_credits)
        utilization = c.lossy(Double.self, .utilization)
        currency = c.lossy(String.self, .currency)
        decimalPlaces = c.lossy(Int.self, .decimal_places)
        disabledReason = c.lossy(String.self, .disabled_reason)
    }

    private var divisor: Double { pow(10, Double(decimalPlaces ?? 2)) }
    public var usedAmount: Double? { usedCredits.map { $0 / divisor } }
    public var limitAmount: Double? { monthlyLimit.map { $0 / divisor } }

    public func format(_ amount: Double) -> String {
        let f = NumberFormatter()
        f.numberStyle = .currency
        f.currencyCode = currency ?? "USD"
        f.maximumFractionDigits = decimalPlaces ?? 2
        return f.string(from: NSNumber(value: amount)) ?? String(format: "%.2f", amount)
    }
}

public struct BreakdownRow: Decodable, Sendable, Equatable {
    public var key: String
    public var displayName: String
    public var percent: Double

    enum CodingKeys: String, CodingKey { case key, display_name, percent }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        key = c.lossy(String.self, .key) ?? "?"
        displayName = c.lossy(String.self, .display_name) ?? key
        percent = c.lossy(Double.self, .percent) ?? 0
    }
}

public struct UsageResponse: Decodable, Sendable, Equatable {
    public var fiveHour: UsageWindow?
    public var sevenDay: UsageWindow?
    public var sevenDayOpus: UsageWindow?
    public var sevenDaySonnet: UsageWindow?
    public var extraUsage: ExtraUsage?
    public var limits: [LimitEntry]
    public var breakdown: [BreakdownRow]

    enum CodingKeys: String, CodingKey {
        case five_hour, seven_day, seven_day_opus, seven_day_sonnet, extra_usage, limits, seven_day_breakdown
    }
    enum BreakdownKeys: String, CodingKey { case rows }

    public init(fiveHour: UsageWindow? = nil, sevenDay: UsageWindow? = nil, limits: [LimitEntry] = []) {
        self.fiveHour = fiveHour
        self.sevenDay = sevenDay
        self.limits = limits
        self.breakdown = []
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        fiveHour = c.lossy(UsageWindow.self, .five_hour)
        sevenDay = c.lossy(UsageWindow.self, .seven_day)
        sevenDayOpus = c.lossy(UsageWindow.self, .seven_day_opus)
        sevenDaySonnet = c.lossy(UsageWindow.self, .seven_day_sonnet)
        extraUsage = c.lossy(ExtraUsage.self, .extra_usage)
        limits = c.lossy(LossyArray<LimitEntry>.self, .limits)?.elements ?? []
        if let b = try? c.nestedContainer(keyedBy: BreakdownKeys.self, forKey: .seven_day_breakdown) {
            breakdown = b.lossy(LossyArray<BreakdownRow>.self, .rows)?.elements ?? []
        } else {
            breakdown = []
        }
    }

    public static func decode(_ data: Data) throws -> UsageResponse {
        try JSONDecoder().decode(UsageResponse.self, from: data)
    }
}

// MARK: - Display-oriented view of the limits

public struct LimitDisplay: Identifiable, Sendable, Equatable {
    public enum Kind: String, Sendable { case session, weekly, model }
    public var id: String
    public var kind: Kind
    public var title: String
    public var utilization: Double
    public var resetsAt: Date?
}

extension UsageResponse {
    /// 5-hour session window; falls back to `limits[kind=session]`.
    public var session: LimitDisplay? {
        if let w = fiveHour {
            return LimitDisplay(id: "five_hour", kind: .session, title: "Session (5h)", utilization: w.utilization, resetsAt: w.resetsAt)
        }
        if let l = limits.first(where: { $0.kind == "session" }), let p = l.percent {
            return LimitDisplay(id: "five_hour", kind: .session, title: "Session (5h)", utilization: p, resetsAt: l.resetsAt)
        }
        return nil
    }

    /// Weekly all-models window; falls back to `limits[kind=weekly_all]`.
    public var weekly: LimitDisplay? {
        if let w = sevenDay {
            return LimitDisplay(id: "seven_day", kind: .weekly, title: "Weekly", utilization: w.utilization, resetsAt: w.resetsAt)
        }
        if let l = limits.first(where: { $0.kind == "weekly_all" }), let p = l.percent {
            return LimitDisplay(id: "seven_day", kind: .weekly, title: "Weekly", utilization: p, resetsAt: l.resetsAt)
        }
        return nil
    }

    /// Model-specific limits. Missing ones are simply absent, never an error.
    public var modelLimits: [LimitDisplay] {
        var out: [LimitDisplay] = []
        for l in limits where l.kind?.contains("scoped") == true || l.modelDisplayName != nil {
            guard let p = l.percent, let name = l.modelDisplayName ?? l.modelID, !name.isEmpty else { continue }
            let window = (l.group == "session" || l.kind?.contains("session") == true) ? "5h" : "weekly"
            out.append(LimitDisplay(id: "model:\(name):\(window)", kind: .model, title: "\(name) \(window)", utilization: p, resetsAt: l.resetsAt))
        }
        // Legacy blocks, only when the newer array did not already cover them.
        let legacy: [(String, UsageWindow?)] = [("Opus", sevenDayOpus), ("Sonnet", sevenDaySonnet)]
        for (name, window) in legacy {
            guard let w = window, !out.contains(where: { $0.title.hasPrefix(name) }) else { continue }
            out.append(LimitDisplay(id: "model:\(name):weekly", kind: .model, title: "\(name) weekly", utilization: w.utilization, resetsAt: w.resetsAt))
        }
        return out
    }
}

// MARK: - Tolerant decoding helpers

struct LossyArray<Element: Decodable>: Decodable {
    var elements: [Element]

    private struct Skip: Decodable { init(from decoder: Decoder) throws {} }

    init(from decoder: Decoder) throws {
        var c = try decoder.unkeyedContainer()
        var out: [Element] = []
        while !c.isAtEnd {
            if let v = try? c.decode(Element.self) {
                out.append(v)
            } else if (try? c.decode(Skip.self)) == nil {
                break
            }
        }
        elements = out
    }
}

extension KeyedDecodingContainer {
    func lossy<T: Decodable>(_ type: T.Type, _ key: Key) -> T? {
        (try? decodeIfPresent(type, forKey: key)) ?? nil
    }

    func lossyDate(_ key: Key) -> Date? {
        if let s = lossy(String.self, key) { return ISODate.parse(s) }
        if let t = lossy(Double.self, key) { return Date(timeIntervalSince1970: t > 1e12 ? t / 1000 : t) }
        return nil
    }
}
