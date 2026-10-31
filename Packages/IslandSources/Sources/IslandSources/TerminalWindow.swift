import AppKit
import ApplicationServices
import Foundation
import IslandKit

/// Raising the one window a coding agent session is in, on whatever Space it is on.
///
/// # Why the Window menu
///
/// `NSRunningApplication.activate` brings an app forward but not a Space: with every one of an
/// app's windows on another desktop, the app became frontmost and the screen did not move. And
/// Accessibility's `AXWindows` lists only the windows on the current Space, so the window cannot be
/// raised directly either. An app's **Window menu** lists every window it has, on every Space, and
/// choosing one there is the app ordering that window front — which is what makes macOS switch to
/// its Space. Measured on macOS 27.2 with two VS Code windows on two desktops: activating the app
/// and then pressing the window's item switched Spaces in about 80 ms; pressing it without
/// activating first reported success and did nothing. See `docs/PLATFORM-CONSTRAINTS.md`.
///
/// The Window menu is found by its ⌘M item (Minimize) rather than by its title, which is
/// localized. This needs Accessibility, which the person grants Isleta for the media keys; without
/// it the app is activated and that is all.
///
/// # Which window
///
/// A window is known by its title, and a title is matched one `" — "`-separated component at a
/// time against the names the session might go by: its folder's name, its own name, and — for VS
/// Code — the name of the window whose folders hold it (`VSCodeWindows`). No match raises the app
/// alone, as before. Nothing here is logged: titles are file and folder names.
enum TerminalWindow {

    /// Whether a window title names the session. Each component is compared whole, so a session
    /// in `site` is not matched by a window on `site-old`.
    static func title(_ title: String, matches names: [String]) -> Bool {
        let components = title.components(separatedBy: " — ").map {
            $0.trimmingCharacters(in: .whitespaces)
        }
        return names.contains { name in !name.isEmpty && components.contains(name) }
    }

    /// The names a session's window might carry, best first.
    static func names(cwd: String?, sessionName: String?, bundleIdentifier: String?) -> [String] {
        var names: [String] = []
        if bundleIdentifier == VSCodeWindows.bundleIdentifier, let cwd {
            names += VSCodeWindows.rootNames(containing: cwd)
        }
        if let cwd { names.append((cwd as NSString).lastPathComponent) }
        if let sessionName { names.append(sessionName) }
        return names
    }

    /// Activate `application`, then press the first Window menu item whose title matches `names` —
    /// or, with none matching, the item the app has checked, which is its main window. Activating
    /// alone does not leave the current Space, so a click that matched nothing would otherwise
    /// bring the app forward with nothing of it on screen.
    ///
    /// Activation happens here, on the main thread, as it always did. The menu walk is cross-process
    /// Accessibility and goes to a background queue with a short timeout, so a terminal that is
    /// hung cannot hold the island's click.
    @MainActor
    static func raise(_ application: NSRunningApplication, names: [String]) {
        application.activate(options: [])
        guard AXIsProcessTrusted() else { return }
        let pid = application.processIdentifier
        DispatchQueue.global(qos: .userInitiated).async {
            let outcome = switch pressWindowItem(pid: pid, names: names) {
            case .session: "raised the session's window"
            case .main: "no window matched, raised the app's main window"
            case nil: "no Window menu, raised the app"
            }
            IslandLog.sources.info("coding agents: \(outcome)")
        }
    }

    private enum Pressed {
        case session
        case main
    }

    private static func pressWindowItem(pid: pid_t, names: [String]) -> Pressed? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.5)
        guard let bar = attribute(app, kAXMenuBarAttribute).map({ $0 as! AXUIElement }) else { return nil }
        for top in children(bar) {
            for menu in children(top) {
                let items = children(menu)
                guard items.contains(where: isMinimize) else { continue }
                let matching = items.first { item in
                    (attribute(item, kAXTitleAttribute) as? String).map { title($0, matches: names) } ?? false
                }
                if let matching, press(matching) { return .session }
                // The checked item is the main window — what a Dock click would bring back.
                let main = items.first { !((attribute($0, "AXMenuItemMarkChar") as? String) ?? "").isEmpty }
                if let main, press(main) { return .main }
                return nil
            }
        }
        return nil
    }

    private static func press(_ item: AXUIElement) -> Bool {
        AXUIElementPerformAction(item, kAXPressAction as CFString) == .success
    }

    /// ⌘M with no other modifier — `AXMenuItemCmdModifiers` 0 is ⌘ alone.
    private static func isMinimize(_ item: AXUIElement) -> Bool {
        (attribute(item, "AXMenuItemCmdChar") as? String) == "M"
            && (attribute(item, "AXMenuItemCmdModifiers") as? Int) == 0
    }

    private static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }

    private static func children(_ element: AXUIElement) -> [AXUIElement] {
        (attribute(element, kAXChildrenAttribute) as? [AXUIElement]) ?? []
    }
}

/// Which VS Code window holds a folder, from VS Code's own record of its open windows.
///
/// VS Code's integrated terminals all run under one shared helper process, so the process tree
/// cannot tell its windows apart. Its `storage.json` lists every open window as either a folder or
/// a `.code-workspace` file, and a workspace file lists its folders. The window's title carries the
/// folder's name, or the workspace's name followed by ` (Workspace)`. Read only on a click.
enum VSCodeWindows {

    static let bundleIdentifier = "com.microsoft.VSCode"

    static var storageURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Code/User/globalStorage/storage.json")
    }

    static func rootNames(containing cwd: String) -> [String] {
        guard let storage = try? Data(contentsOf: storageURL) else { return [] }
        return rootNames(containing: cwd, storage: storage) { try? Data(contentsOf: $0) }
    }

    /// The title names of the open windows whose folders contain `cwd`, deepest folder first.
    static func rootNames(containing cwd: String, storage: Data, workspace: (URL) -> Data?) -> [String] {
        guard let root = try? JSONSerialization.jsonObject(with: storage) as? [String: Any],
              let state = root["windowsState"] as? [String: Any]
        else { return [] }
        let windows = ((state["openedWindows"] as? [[String: Any]]) ?? [])
            + [state["lastActiveWindow"] as? [String: Any]].compactMap { $0 }

        var found: [(name: String, depth: Int)] = []
        for window in windows {
            if let folder = (window["folder"] as? String).flatMap(URL.init(string:)), folder.isFileURL {
                if let depth = depth(of: folder, containing: cwd) {
                    found.append((folder.lastPathComponent, depth))
                }
            } else if let identifier = window["workspaceIdentifier"] as? [String: Any],
                      let file = (identifier["configURIPath"] as? String).flatMap(URL.init(string:)),
                      file.isFileURL, let data = workspace(file) {
                let folders = workspaceFolders(data, relativeTo: file.deletingLastPathComponent())
                if let depth = folders.compactMap({ depth(of: $0, containing: cwd) }).max() {
                    let name = file.deletingPathExtension().lastPathComponent
                    found.append(("\(name) (Workspace)", depth))
                }
            }
        }
        var seen = Set<String>()
        return found.sorted { $0.depth > $1.depth }.map(\.name).filter { seen.insert($0).inserted }
    }

    /// How many path components `folder` has, if it is `cwd` or one of its parents.
    private static func depth(of folder: URL, containing cwd: String) -> Int? {
        let path = folder.standardizedFileURL.path
        guard cwd == path || cwd.hasPrefix(path.hasSuffix("/") ? path : path + "/") else { return nil }
        return folder.standardizedFileURL.pathComponents.count
    }

    /// The folders a `.code-workspace` file lists — `path` relative to the file or absolute, or a
    /// `file:` `uri`. The file is JSON with comments and trailing commas.
    static func workspaceFolders(_ data: Data, relativeTo directory: URL) -> [URL] {
        guard let root = try? JSONSerialization.jsonObject(with: Data(strippingComments(data).utf8)) as? [String: Any],
              let folders = root["folders"] as? [[String: Any]]
        else { return [] }
        return folders.compactMap { folder in
            if let path = folder["path"] as? String {
                let expanded = (path as NSString).expandingTildeInPath
                return expanded.hasPrefix("/")
                    ? URL(fileURLWithPath: expanded)
                    : directory.appendingPathComponent(path).standardizedFileURL
            }
            if let uri = (folder["uri"] as? String).flatMap(URL.init(string:)), uri.isFileURL { return uri }
            return nil
        }
    }

    /// JSON with comments, to JSON: `//` and `/* */` comments, then trailing commas, removed —
    /// with strings left alone, so a `file://` inside one survives.
    static func strippingComments(_ data: Data) -> String {
        let withoutComments = scan(Array(String(decoding: data, as: UTF8.self).unicodeScalars)) { text, index in
            guard text[index] == "/", index + 1 < text.count else { return nil }
            if text[index + 1] == "/" {
                var end = index
                while end < text.count, text[end] != "\n" { end += 1 }
                return end
            }
            if text[index + 1] == "*" {
                var end = index + 2
                while end + 1 < text.count, !(text[end] == "*" && text[end + 1] == "/") { end += 1 }
                return min(end + 2, text.count)
            }
            return nil
        }
        return scan(Array(withoutComments.unicodeScalars)) { text, index in
            guard text[index] == "," else { return nil }
            var look = index + 1
            while look < text.count, text[look].properties.isWhitespace { look += 1 }
            return look < text.count && (text[look] == "]" || text[look] == "}") ? index + 1 : nil
        }
    }

    /// Copy `text`, skipping wherever `skip` answers an end index — outside strings only.
    private static func scan(
        _ text: [Unicode.Scalar], skip: ([Unicode.Scalar], Int) -> Int?
    ) -> String {
        var out = String.UnicodeScalarView()
        var index = 0
        var inString = false
        while index < text.count {
            let scalar = text[index]
            if inString {
                out.append(scalar)
                if scalar == "\\", index + 1 < text.count {
                    out.append(text[index + 1])
                    index += 1
                } else if scalar == "\"" {
                    inString = false
                }
            } else if let end = skip(text, index) {
                index = end
                continue
            } else {
                inString = scalar == "\""
                out.append(scalar)
            }
            index += 1
        }
        return String(out)
    }
}
