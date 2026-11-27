import Foundation
#if canImport(FoundationXML)
    import FoundationXML
#endif
import Testing

/// Contract for in-app updates (Sparkle): the app reads its feed from the
/// latest GitHub release's appcast.xml and trusts only updates signed with
/// the release key; each release writes an appcast whose one item points at
/// that release's DMG, with the build number Sparkle compares against
/// CFBundleVersion and the DMG's EdDSA signature and length.
struct UpdateFeedTests {
    private static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    private var infoPlist: [String: Any] {
        get throws {
            let data = try Data(contentsOf: Self.root.appendingPathComponent("Resources/Info.plist"))
            return try #require(try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        }
    }

    @Test func theAppReadsTheLatestReleasesFeed() throws {
        let plist = try infoPlist
        #expect(plist["SUFeedURL"] as? String
            == "https://github.com/brettbergin/ghostgrid/releases/latest/download/appcast.xml")
        #expect(plist["SUEnableAutomaticChecks"] as? Bool == true, "checks daily without asking first")
    }

    @Test func theAppTrustsOnlyTheReleaseKey() throws {
        let key = try #require(try infoPlist["SUPublicEDKey"] as? String)
        let raw = try #require(Data(base64Encoded: key), "base64")
        #expect(raw.count == 32, "an Ed25519 public key")
    }

    /// One element's attributes and text, as parsed.
    private final class Collector: NSObject, XMLParserDelegate {
        var elements: [String: (attributes: [String: String], text: String)] = [:]
        private var current: String?
        func parser(_: XMLParser, didStartElement name: String, namespaceURI _: String?, qualifiedName: String?,
                    attributes: [String: String]) {
            let key = qualifiedName ?? name
            elements[key] = (attributes, "")
            current = key
        }
        func parser(_: XMLParser, foundCharacters string: String) {
            guard let current else { return }
            elements[current]?.text += string
        }
        func parser(_: XMLParser, didEndElement _: String, namespaceURI _: String?, qualifiedName _: String?) {
            current = nil
        }
    }

    private func appcast(version: String, build: String, signature: String) throws -> (Collector, Bool) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [Self.root.appendingPathComponent("Scripts/appcast.sh").path, version, build, signature]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        let parser = XMLParser(data: pipe.fileHandleForReading.readDataToEndOfFile())
        let collector = Collector()
        parser.delegate = collector
        let parsed = parser.parse()
        return (collector, parsed && process.terminationStatus == 0)
    }

    @Test func eachReleaseFeedPointsAtItsSignedDMG() throws {
        let (feed, ok) = try appcast(version: "0.2.0", build: "31",
                                     signature: #"sparkle:edSignature="c2lnbmF0dXJl+/=" length="9012345""#)
        #expect(ok, "valid XML")
        #expect(feed.elements["sparkle:version"]?.text == "31", "the build number Sparkle compares")
        #expect(feed.elements["sparkle:shortVersionString"]?.text == "0.2.0")
        #expect(feed.elements["sparkle:minimumSystemVersion"]?.text == "14.0")
        let enclosure = try #require(feed.elements["enclosure"]?.attributes)
        #expect(enclosure["url"] == "https://github.com/brettbergin/ghostgrid/releases/download/v0.2.0/ghostgrid-0.2.0.dmg")
        #expect(enclosure["sparkle:edSignature"] == "c2lnbmF0dXJl+/=")
        #expect(enclosure["length"] == "9012345")
        #expect(enclosure["type"] == "application/octet-stream")
        #expect(feed.elements["pubDate"]?.text.isEmpty == false)
    }

    @Test func aFeedWithoutASignatureIsRefused() throws {
        let (_, ok) = try appcast(version: "0.2.0", build: "31", signature: "")
        #expect(!ok)
        let (_, malformed) = try appcast(version: "0.2.0", build: "31", signature: "length=\"1\"")
        #expect(!malformed)
    }
}
