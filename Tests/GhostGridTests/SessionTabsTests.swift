import Foundation
#if canImport(CoreGraphics)
    import CoreGraphics // CGRect's Codable conformance on macOS
#endif
import Testing
@testable import GhostGridCore

/// Contract for saving tabs (session version 2): each window saves its tabs
/// in order and which one is selected; each tab its name, color, panes,
/// focus, zoom and layout. A version 1 session (0.2.1 and earlier) loads as
/// one tab per window with everything it had, kept shells included, so an
/// update keeps your windows. An unknown tab color is dropped, not the
/// session. Restoring skips empty tabs and windows and keeps the selected
/// tab when it is still there.
struct SessionTabsTests {
    let tabbed = Session(windows: [
        .init(frame: CGRect(x: 10, y: 20, width: 1280, height: 800), tabs: [
            .init(panes: [.init(shell: "zsh", workingDirectory: "/code", sessionID: "a")], layout: .grid),
            .init(name: "logs", color: .teal,
                  panes: [.init(shell: "bash", workingDirectory: nil, sessionID: "b"),
                          .init(shell: "zsh", workingDirectory: "/tmp")],
                  focused: 1, zoomed: 0, layout: .mainStack,
                  weights: LayoutWeights(tracks: [1.2, 0.8], cells: [[1], [1]]), rows: [2], rotated: true),
        ], selectedTab: 1),
    ])

    @Test func tabsRoundTripWithTheirNameColorAndLayout() throws {
        let decoded = try #require(Session.decode(try tabbed.encoded()))
        #expect(decoded == tabbed)
        #expect(decoded.version == 2)
        #expect(decoded.windows[0].selectedTab == 1)
        #expect(decoded.windows[0].tabs.map(\.name) == [nil, "logs"])
        #expect(decoded.windows[0].tabs.map(\.color) == [nil, .teal])
        #expect(decoded.windows[0].tabs[1].rotated == true)
    }

    /// session.json as ghostgrid 0.2.1 writes it: version 1, no tabs.
    let version1 = #"""
    {
      "version" : 1,
      "windows" : [
        {
          "focused" : 1,
          "frame" : [[100, 200], [1280, 800]],
          "layout" : "mainStack",
          "panes" : [
            {"sessionID" : "s1", "shell" : "zsh", "workingDirectory" : "/Users/me/code"},
            {"shell" : "nushell"}
          ],
          "rotated" : true,
          "rows" : [1, 1],
          "weights" : {"cells" : [[1.35], [0.6, 0.8]], "tracks" : [0.7, 1.3]},
          "zoomed" : 0
        },
        {"frame" : [[0, 0], [800, 600]], "panes" : [{"shell" : "bash", "sessionID" : "s2"}]}
      ]
    }
    """#

    @Test func aVersion1SessionLoadsAsOneTabPerWindow() throws {
        let session = try #require(Session.decode(Data(version1.utf8)))
        #expect(session.version == Session.currentVersion)
        #expect(session.windows.count == 2)
        let window = session.windows[0]
        #expect(window.frame == CGRect(x: 100, y: 200, width: 1280, height: 800))
        #expect(window.selectedTab == 0)
        #expect(window.tabs.count == 1)
        let tab = window.tabs[0]
        #expect(tab.name == nil)
        #expect(tab.color == nil)
        #expect(tab.panes == [.init(shell: "zsh", workingDirectory: "/Users/me/code", sessionID: "s1"),
                              .init(shell: "nushell", workingDirectory: nil)])
        #expect(tab.focused == 1)
        #expect(tab.zoomed == 0)
        #expect(tab.layout == .mainStack)
        #expect(tab.rows == [1, 1])
        #expect(tab.rotated == true)
        #expect(tab.weights == LayoutWeights(tracks: [0.7, 1.3], cells: [[1.35], [0.6, 0.8]]))
        let plain = session.windows[1].tabs[0]
        #expect(plain.layout == nil && plain.weights == nil && plain.rows == nil && plain.rotated == nil)
        #expect(session.liveSessionIDs == ["s1", "s2"], "kept shells survive the update")
    }

    @Test func unknownVersionsAreRefused() {
        for version in [0, 3, 99] {
            let json = #"{"version":\#(version),"windows":[]}"#
            #expect(Session.decode(Data(json.utf8)) == nil, "version \(version)")
        }
    }

    @Test func anUnknownTabColorIsDroppedNotTheSession() throws {
        let json = #"""
        {"version":2,"windows":[{"frame":[[0,0],[10,10]],"selectedTab":0,
         "tabs":[{"name":"api","color":"chartreuse","panes":[{"shell":"zsh"}]}]}]}
        """#
        let session = try #require(Session.decode(Data(json.utf8)))
        #expect(session.windows[0].tabs[0].name == "api")
        #expect(session.windows[0].tabs[0].color == nil)
    }

    @Test func restoringSkipsEmptyTabsAndWindowsAndKeepsTheSelectedTab() {
        let zsh = Session.Pane(shell: "zsh", workingDirectory: nil)
        let messy = Session(windows: [
            .init(frame: .zero, tabs: [.init(panes: [])]),
            .init(frame: .zero, tabs: [
                .init(panes: []),
                .init(name: "b", panes: [zsh], focused: 5, zoomed: 0),
                .init(name: "c", panes: [zsh]),
            ], selectedTab: 2),
            .init(frame: .zero, tabs: [.init(name: "d", panes: [zsh]), .init(panes: [])], selectedTab: 1),
            .init(frame: .zero, tabs: [.init(name: "e", panes: [zsh])], selectedTab: 7),
            .init(frame: .zero, tabs: [.init(name: "f", panes: [zsh])]),
            .init(frame: .zero, tabs: []),
        ])
        let restorable = messy.restorable
        #expect(restorable.map { $0.tabs.compactMap(\.name) } == [["b", "c"], ["d"], ["e"], ["f"]])
        #expect(restorable[0].selectedTab == 1, "still tab c")
        #expect(restorable[0].tabs[0].focused == nil)
        #expect(restorable[0].tabs[0].zoomed == 0)
        #expect(restorable[1].selectedTab == 0, "the selected tab was empty: its neighbour")
        #expect(restorable[2].selectedTab == 0)
        #expect(restorable[3].selectedTab == 0)
    }

    @Test func everyKeptShellIsFoundAcrossWindowsAndTabs() {
        let session = Session(windows: [
            .init(frame: .zero, tabs: [
                .init(panes: [.init(shell: "zsh", workingDirectory: nil, sessionID: "a"),
                              .init(shell: "zsh", workingDirectory: nil)]),
                .init(panes: [.init(shell: "bash", workingDirectory: nil, sessionID: "b")]),
            ]),
            .init(frame: .zero, tabs: [.init(panes: [.init(shell: "zsh", workingDirectory: nil, sessionID: "c")])]),
        ])
        #expect(session.liveSessionIDs == ["a", "b", "c"])
    }
}
