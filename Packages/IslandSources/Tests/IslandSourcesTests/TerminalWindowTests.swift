import Foundation
import Testing

@testable import IslandSources

@Suite("Terminal window")
struct TerminalWindowTests {

    @Test("a title matches a name only as a whole component", arguments: [
        ("personal.yml — Personal (Workspace)", "Personal (Workspace)", true),
        ("README.md — isleta", "isleta", true),
        ("README.md — isleta-site", "isleta", false),
        ("isleta — claude — 80×24", "isleta", true),
        ("Untitled", "", false),
    ])
    func titleMatch(_ title: String, _ name: String, _ expected: Bool) {
        #expect(TerminalWindow.title(title, matches: [name]) == expected)
    }

    @Test("names: VS Code's window first, then the folder, then the session")
    func names() {
        let names = TerminalWindow.names(cwd: "/Users/someone/Sites/app", sessionName: "fix the build",
                                         bundleIdentifier: "com.apple.Terminal")
        #expect(names == ["app", "fix the build"])
    }
}

@Suite("VS Code windows")
struct VSCodeWindowsTests {

    private let storage = Data(#"""
    {"windowsState": {
      "lastActiveWindow": {"workspaceIdentifier": {"id": "a", "configURIPath": "file:///Users/someone/Code/Work.code-workspace"}},
      "openedWindows": [
        {"workspaceIdentifier": {"id": "a", "configURIPath": "file:///Users/someone/Code/Work.code-workspace"}},
        {"workspaceIdentifier": {"id": "b", "configURIPath": "file:///Users/someone/Code/Personal.code-workspace"}},
        {"folder": "file:///Users/someone/Sites/app/web"}
      ]}}
    """#.utf8)

    private func workspace(_ url: URL) -> Data? {
        switch url.lastPathComponent {
        case "Work.code-workspace":
            Data(#"""
            {
              // the day job
              "folders": [
                {"path": "../Sites/shop"},
                {"path": "../Sites/app", /* trailing */ },
              ],
              "settings": {"files.exclude": {"**/.git": true}},
            }
            """#.utf8)
        case "Personal.code-workspace":
            Data(#"{"folders": [{"uri": "file:///Users/someone/Sites/blog"}]}"#.utf8)
        default: nil
        }
    }

    @Test("the window whose folder holds the session, deepest first and once each")
    func containing() {
        #expect(VSCodeWindows.rootNames(containing: "/Users/someone/Sites/app/web/src", storage: storage,
                                        workspace: workspace) == ["web", "Work (Workspace)"])
        #expect(VSCodeWindows.rootNames(containing: "/Users/someone/Sites/blog", storage: storage,
                                        workspace: workspace) == ["Personal (Workspace)"])
        #expect(VSCodeWindows.rootNames(containing: "/Users/someone/Sites/shop-old", storage: storage,
                                        workspace: workspace).isEmpty)
    }

    @Test("comments and trailing commas go, strings with slashes stay")
    func comments() throws {
        let text = VSCodeWindows.strippingComments(Data(#"{"a": "file://x", /* c */ "b": [1, 2, // d"#.utf8 + Data("\n]}".utf8)))
        let object = try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        #expect(object["a"] as? String == "file://x")
        #expect(object["b"] as? [Int] == [1, 2])
    }

    @Test("an unreadable record is no windows, not a crash")
    func garbage() {
        #expect(VSCodeWindows.rootNames(containing: "/x", storage: Data("nope".utf8), workspace: { _ in nil }).isEmpty)
    }
}
