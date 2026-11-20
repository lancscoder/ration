import CryptoKit
import Foundation
import Testing
@testable import RationCore

@Suite("Updates")
struct UpdatesTests {
    @Test func comparesVersionsNumerically() throws {
        #expect(try #require(AppVersion("1.10.0")) > #require(AppVersion("1.9.3")))
        #expect(try #require(AppVersion("v2.0")) == #require(AppVersion("2.0.0")))
        #expect(try #require(AppVersion("1.0.0")) < #require(AppVersion("1.0.1")))
        #expect(AppVersion("1.0.0-beta") == nil)
        #expect(AppVersion("") == nil)
        #expect(AppVersion("v1.2.3")?.description == "1.2.3")
    }

    func releaseJSON(tag: String = "v1.2.0", draft: Bool = false, prerelease: Bool = false, assets: [String]? = nil) -> Data {
        let names = assets ?? ["Ration-1.2.0.zip", "Ration-1.2.0.zip.sig"]
        let list = names.map { #"{"name":"\#($0)","browser_download_url":"https://github.com/lancscoder/ration/releases/download/\#(tag)/\#($0)"}"# }
        return Data("""
        {"tag_name":"\(tag)","html_url":"https://github.com/lancscoder/ration/releases/tag/\(tag)",
         "body":"Fixes","draft":\(draft),"prerelease":\(prerelease),"assets":[\(list.joined(separator: ","))]}
        """.utf8)
    }

    @Test func parsesTheLatestRelease() throws {
        let release = try #require(try ReleaseFeed.parse(releaseJSON()))
        #expect(release.version == "1.2.0")
        #expect(release.zip.lastPathComponent == "Ration-1.2.0.zip")
        #expect(release.signature.lastPathComponent == "Ration-1.2.0.zip.sig")
        #expect(release.notes == "Fixes")
    }

    @Test func ignoresDraftsPrereleasesAndOddTags() throws {
        #expect(try ReleaseFeed.parse(releaseJSON(draft: true)) == nil)
        #expect(try ReleaseFeed.parse(releaseJSON(prerelease: true)) == nil)
        #expect(try ReleaseFeed.parse(releaseJSON(tag: "nightly")) == nil)
        #expect(throws: ReleaseFeed.FeedError.missingAssets("1.2.0")) {
            try ReleaseFeed.parse(releaseJSON(assets: ["Ration-1.2.0.zip"])) // unsigned
        }
        #expect(throws: ReleaseFeed.FeedError.unreadable) { try ReleaseFeed.parse(Data("<html>".utf8)) }
    }

    @Test func offersOnlyNewerVersions() throws {
        let release = try ReleaseFeed.parse(releaseJSON())
        #expect(ReleaseFeed.newer(release, than: "1.1.9") != nil)
        #expect(ReleaseFeed.newer(release, than: "1.2.0") == nil)
        #expect(ReleaseFeed.newer(release, than: "2.0.0") == nil)
    }

    @Test func verifiesSignatures() throws {
        let key = Curve25519.Signing.PrivateKey()
        let publicKey = key.publicKey.rawRepresentation.base64EncodedString()
        let zip = Data("pretend zip".utf8)
        let sig = try UpdateSignature.sign(zip, privateKey: key.rawRepresentation.base64EncodedString())
        #expect(UpdateSignature.verify(zip, signature: sig + "\n", publicKey: publicKey))
        #expect(!UpdateSignature.verify(Data("tampered".utf8), signature: sig, publicKey: publicKey))
        let other = Curve25519.Signing.PrivateKey().publicKey.rawRepresentation.base64EncodedString()
        #expect(!UpdateSignature.verify(zip, signature: sig, publicKey: other))
        #expect(!UpdateSignature.verify(zip, signature: "not base64!", publicKey: publicKey))
    }

    @Test func shippedPublicKeyIsValid() {
        #expect(Data(base64Encoded: UpdateConfig.publicKey).flatMap { try? Curve25519.Signing.PublicKey(rawRepresentation: $0) } != nil)
    }
}
