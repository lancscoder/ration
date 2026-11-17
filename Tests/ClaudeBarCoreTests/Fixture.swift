import Foundation

enum Fixture {
    static func url(_ name: String) -> URL {
        let parts = name.split(separator: ".", maxSplits: 1).map(String.init)
        guard let url = Bundle.module.url(forResource: parts[0], withExtension: parts.count > 1 ? parts[1] : nil, subdirectory: "Fixtures") else {
            fatalError("missing fixture \(name)")
        }
        return url
    }

    static func data(_ name: String) -> Data {
        try! Data(contentsOf: url(name))
    }
}

func date(_ iso: String) -> Date {
    guard let d = ISO8601DateFormatter().date(from: iso) else { fatalError("bad date \(iso)") }
    return d
}
