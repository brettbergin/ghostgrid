import Foundation
#if canImport(CoreGraphics)
    import CoreGraphics // CGRect's Codable conformance on macOS
#endif
import Testing
@testable import GhostGridCore

struct SessionTests {
    let session = Session(windows: [
        .init(frame: CGRect(x: 100, y: 200, width: 1280, height: 800),
              panes: [.init(shell: "zsh", workingDirectory: "/Users/me/code"),
                      .init(shell: "nushell", workingDirectory: nil)],
              focused: 1, zoomed: nil),
    ])

    @Test func roundTripsThroughJSON() throws {
        #expect(Session.decode(try session.encoded()) == session)
    }

    @Test func rejectsGarbageAndUnknownVersions() throws {
        #expect(Session.decode(Data("not json".utf8)) == nil)
        var future = session
        future.version = 99
        #expect(Session.decode(try future.encoded()) == nil)
    }

    @Test func restorableDropsEmptyWindowsAndBadIndices() {
        let messy = Session(windows: [
            .init(frame: .zero, panes: []),
            .init(frame: .zero, panes: [.init(shell: "bash", workingDirectory: "/tmp")], focused: 5, zoomed: 0),
        ])
        let restorable = messy.restorable
        #expect(restorable.count == 1)
        #expect(restorable[0].focused == nil)
        #expect(restorable[0].zoomed == 0)
    }
}

struct SessionPolicyTests {
    @Test func followsWindowSaveState() {
        #expect(SessionPolicy.shouldRestore(windowSaveState: "always", systemKeepsWindows: false))
        #expect(!SessionPolicy.shouldRestore(windowSaveState: "never", systemKeepsWindows: true))
        #expect(SessionPolicy.shouldRestore(windowSaveState: "default", systemKeepsWindows: true))
        #expect(!SessionPolicy.shouldRestore(windowSaveState: nil, systemKeepsWindows: false))
    }

    let screen = CGRect(x: 0, y: 0, width: 1728, height: 1117)

    @Test func keepsFramesThatAreOnScreen() {
        let frame = CGRect(x: 100, y: 100, width: 1280, height: 800)
        #expect(SessionPolicy.fit(frame, screens: [screen]) == frame)
    }

    @Test func movesFramesFromAMissingDisplayOntoTheMainScreen() {
        let offScreen = CGRect(x: 3000, y: 0, width: 1280, height: 800)
        let fitted = SessionPolicy.fit(offScreen, screens: [screen])!
        #expect(screen.contains(fitted))
        #expect(fitted.size == offScreen.size)
    }

    @Test func shrinksFramesBiggerThanTheScreen() {
        let huge = CGRect(x: 5000, y: 5000, width: 4000, height: 3000)
        let fitted = SessionPolicy.fit(huge, screens: [screen])!
        #expect(fitted.size == screen.size)
    }

    @Test func noScreensMeansNoFrame() {
        #expect(SessionPolicy.fit(.zero, screens: []) == nil)
    }
}

struct SessionLayoutTests {
    @Test func layoutRoundTripsAndOldSessionsStillDecode() throws {
        let session = Session(windows: [.init(frame: .zero, panes: [.init(shell: "zsh", workingDirectory: nil)], layout: .mainStack)])
        #expect(Session.decode(try session.encoded())?.windows.first?.layout == .mainStack)
        let old = #"{"version":1,"windows":[{"frame":[[0,0],[10,10]],"panes":[{"shell":"zsh"}]}]}"#
        #expect(Session.decode(Data(old.utf8))?.windows.first?.layout == nil)
    }
}
