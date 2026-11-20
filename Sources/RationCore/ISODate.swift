import Foundation

/// Fast, allocation-light ISO-8601 parser.
///
/// Handles the two shapes seen in practice:
/// - JSONL logs: `2026-11-16T10:11:56.385Z`
/// - usage endpoint: `2026-11-17T19:10:00.059793+00:00` (microseconds, which
///   `ISO8601DateFormatter` does not reliably accept)
///
/// Thousands of log timestamps are parsed per refresh, so this avoids
/// `DateFormatter` entirely.
public enum ISODate {
    public static func parse(_ string: String) -> Date? {
        var s = string
        return s.withUTF8 { parse(bytes: $0) }
    }

    static func parse(bytes b: UnsafeBufferPointer<UInt8>) -> Date? {
        let n = b.count
        guard n >= 19 else { return nil }
        @inline(__always) func digit(_ i: Int) -> Int? {
            let c = b[i]
            return (c >= 48 && c <= 57) ? Int(c - 48) : nil
        }
        @inline(__always) func num(_ start: Int, _ len: Int) -> Int? {
            var v = 0
            for i in start..<(start + len) {
                guard let d = digit(i) else { return nil }
                v = v * 10 + d
            }
            return v
        }
        guard b[4] == UInt8(ascii: "-"), b[7] == UInt8(ascii: "-"),
              b[10] == UInt8(ascii: "T") || b[10] == UInt8(ascii: " "),
              b[13] == UInt8(ascii: ":"), b[16] == UInt8(ascii: ":"),
              let year = num(0, 4), let month = num(5, 2), let day = num(8, 2),
              let hour = num(11, 2), let minute = num(14, 2), let second = num(17, 2),
              (1...12).contains(month), (1...31).contains(day), hour < 24, minute < 60, second < 61
        else { return nil }

        var i = 19
        var fraction = 0.0
        if i < n, b[i] == UInt8(ascii: ".") || b[i] == UInt8(ascii: ",") {
            i += 1
            var scale = 0.1
            while i < n, let d = digit(i) {
                fraction += Double(d) * scale
                scale /= 10
                i += 1
            }
        }

        var offset = 0
        if i < n {
            let c = b[i]
            if c == UInt8(ascii: "Z") || c == UInt8(ascii: "z") {
                i += 1
            } else if c == UInt8(ascii: "+") || c == UInt8(ascii: "-") {
                let sign = c == UInt8(ascii: "+") ? 1 : -1
                i += 1
                guard i + 2 <= n, let hh = num(i, 2) else { return nil }
                i += 2
                if i < n, b[i] == UInt8(ascii: ":") { i += 1 }
                var mm = 0
                if i + 2 <= n, let m = num(i, 2) { mm = m; i += 2 }
                offset = sign * (hh * 3600 + mm * 60)
            } else {
                return nil
            }
        }
        guard i == n else { return nil }

        let days = daysFromCivil(year: year, month: month, day: day)
        let seconds = days * 86_400 + hour * 3600 + minute * 60 + second - offset
        return Date(timeIntervalSince1970: Double(seconds) + fraction)
    }

    /// Days since 1970-01-01 for a proleptic Gregorian date (Howard Hinnant).
    static func daysFromCivil(year: Int, month: Int, day: Int) -> Int {
        let y = month <= 2 ? year - 1 : year
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400
        let mp = month > 2 ? month - 3 : month + 9
        let doy = (153 * mp + 2) / 5 + day - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return era * 146_097 + doe - 719_468
    }
}
