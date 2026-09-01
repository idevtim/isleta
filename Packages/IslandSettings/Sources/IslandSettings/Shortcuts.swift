import Carbon.HIToolbox

/// The things a user can bind a global keyboard shortcut to.
///
/// Closed, and closed for `ActivityKind`'s reason rather than by habit: an open string would let
/// each 2.0 stage invent its own action name, its own default and its own idea of what happens when
/// two of them want ⌥Space — and there would be no single place to read what Isleta has taken from
/// the rest of the machine. That last part is the whole argument. `RegisterEventHotKey` is
/// system-wide and **exclusive** (CLAUDE.md), so every binding here is a key no other app on the
/// user's Mac can use for as long as Isleta runs. A vocabulary that can only grow by an edit next
/// to the defaults it has to justify itself against is the honest shape for that.
///
/// **Two cases, and the bar for a third is that the pointer cannot do it as well.** Through 2.0
/// there were eight, five of which bound a key to something already one click away on an island the
/// user had just opened — and two of those five (`startTimer`, `dismissAll`) had no handler in the
/// app shell at all, so the row recorded a keystroke and nothing listened for it. The app switcher
/// took the eighth with it when the feature was withdrawn. What is left is the island toggle, which
/// is the only door into an app with no Dock icon, and the glance, which is the one surface people
/// open without an event having put it there.
public enum ShortcutAction: String, CaseIterable, Sendable, Codable {

    /// Open or close the island. The one action that shipped before this vocabulary existed.
    case toggleIsland

    /// Open the island on the glance — `IslandPage.home`, the day beside what is playing.
    case openGlance

    /// What Settings calls this row.
    public var title: String {
        switch self {
        case .toggleIsland: settingsText("shortcuts.action.toggleIsland", "Open the island")
        case .openGlance: settingsText("shortcuts.action.openGlance", "Show glance")
        }
    }

    /// The binding this action ships with, or nil for one that starts unassigned.
    ///
    /// **Only `toggleIsland` ships bound, and that is a rule rather than a shortage of good
    /// ideas.** Every default here is a key taken from every other app on the machine, so the bar
    /// for shipping one bound is that the feature is unreachable without it. The island toggle
    /// clears it — Isleta has no Dock icon and its menu bar item can be hidden, so a user who has
    /// hidden the icon and forgotten the shortcut has no way back in. Nothing else does: the glance
    /// is one two-finger swipe from wherever the island opens, and the shelf is a drag away.
    public var defaultBinding: HotKeyBinding? {
        switch self {
        case .toggleIsland: .toggleIsland
        case .openGlance: nil
        }
    }
}

/// Every global shortcut the user has assigned.
///
/// A dictionary rather than the named stored properties `SourceToggles` argues for, and the
/// difference between the two records is the meaning of an absent key. In `SourceToggles`, absence
/// is ambiguous — it could mean "off" or "written by a build that did not have this flag" — and
/// those are opposite answers, which is what named `Bool`s exist to disambiguate. Here absence is
/// unambiguous and is itself a value the user can choose: **unassigned**. A new action added by a
/// later build is absent, and absent is exactly what a new action should be, because the
/// alternative is a build that claims another system-wide key on upgrade without being asked.
///
/// The consequence is that `defaultBinding` is applied **once**, on first write, and never again —
/// see `applyingDefaults(to:)`. A user who clears the island toggle gets an empty assignment stored
/// for it, not an absent one, or the default would come back on the next launch and the clearing
/// would read as a bug.
public struct Shortcuts: Equatable, Sendable, Codable {

    /// Assigned bindings, keyed by `ShortcutAction.rawValue`. A key present with a nil value is a
    /// shortcut the user deliberately cleared; a key that is absent has never been touched.
    private var assignments: [String: HotKeyBinding?]

    public init(assignments: [ShortcutAction: HotKeyBinding?] = [:]) {
        self.assignments = Dictionary(
            uniqueKeysWithValues: assignments.map { ($0.key.rawValue, $0.value) }
        )
    }

    /// What is bound to `action` right now — the user's choice if they have made one, the shipped
    /// default if they have not, and nil for an action with neither.
    public subscript(action: ShortcutAction) -> HotKeyBinding? {
        get {
            guard let stored = assignments[action.rawValue] else { return action.defaultBinding }
            return stored
        }
        set {
            // Stored even when nil, and that is the load-bearing line: writing the key with an
            // empty value is what distinguishes "the user cleared this" from "the user has never
            // touched this", and only the second may fall back to the default.
            assignments[action.rawValue] = .some(newValue)
        }
    }

    /// Whether the user has ever expressed an opinion about this action.
    public func isCustomised(_ action: ShortcutAction) -> Bool {
        assignments[action.rawValue] != nil
    }

    /// Puts an action back to what it shipped with.
    public mutating func reset(_ action: ShortcutAction) {
        assignments[action.rawValue] = nil
    }

    /// The action already using `binding`, if any, ignoring `excluding`.
    ///
    /// Two actions sharing one shortcut is not a thing to resolve at registration time, because
    /// `RegisterEventHotKey` will happily take the same combination twice and then deliver to
    /// whichever handler it feels like — a bug that presents as "the shortcut works, but does the
    /// wrong thing about half the time". The recorder asks this before it stores, so the collision
    /// is something the user is *told about* rather than something they discover.
    public func conflict(with binding: HotKeyBinding, excluding: ShortcutAction) -> ShortcutAction? {
        ShortcutAction.allCases.first { action in
            action != excluding && self[action] == binding
        }
    }

    /// Every action that is actually bound, and to what — the list the app shell registers.
    public var active: [(action: ShortcutAction, binding: HotKeyBinding)] {
        ShortcutAction.allCases.compactMap { action in
            // An invalid binding is dropped here rather than at registration, for the reason
            // `HotKeyBinding.isValid` exists: a shortcut with no ⌘/⌃/⌥ takes a bare key away from
            // every text field on the machine, and the user would have to type that key to undo it.
            guard let binding = self[action], binding.isValid else { return nil }
            return (action, binding)
        }
    }
}
