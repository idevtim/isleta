import IslandActivities

/// One row of the Sources section, as the app shell describes it.
///
/// A **value handed in**, not something this module computes. IslandSettings does not depend on
/// IslandSources and must not: the settings pane has to build and preview with nothing granted and
/// no source constructed, and a settings module that reached for a live `ActivitySource` would drag
/// an AX observer and a child process into a SwiftUI preview. So the app shell — the one layer that
/// legitimately knows both — reads each source's `authorization` and phrases it here.
///
/// The shape is what §10 requires, made un-skippable: every row carries a `summary` saying what the
/// source does whether or not it can do it, and a `status` that distinguishes *not asked* from
/// *refused*. There is exactly one place a prompt can come from — `action` — and it is rendered as
/// a button, which is what "a moment the user initiated" means in practice.
public struct SourceSettingsRow: Identifiable {

    /// What the source can do right now, in the three states a user can act on differently.
    ///
    /// Three cases, not a `Bool` and not a free string, mirroring `SourceAuthorization`'s own reason
    /// for having four: "working", "you could turn this on" and "this machine cannot" call for a
    /// different sentence, a different icon and — critically — a different answer to whether there
    /// is anything to offer. Collapsing the last two is how an app ends up with a "Grant Access"
    /// button for a permission that does not exist on the user's hardware.
    public enum Status: Equatable, Sendable {

        /// Running, or able to. The string says what that means concretely.
        case working(String)

        /// The user has not been asked, or has refused. §10: an offer in the first case, an
        /// explanation and silence in the second — which is why `action` is separate from this.
        case needsPermission(String)

        /// Nothing the user can do: no route on this hardware, no entitlement Apple hands out.
        case unavailable(String)

        /// The sentence shown under the row.
        public var explanation: String {
            switch self {
            case .working(let text), .needsPermission(let text), .unavailable(let text): text
            }
        }

        /// The same state in three words, for somewhere that has already explained the feature.
        ///
        /// `explanation` is written for the Sources pane, where the row is one of four and nothing
        /// around it says what the source does or why it cannot — so it has to carry the whole
        /// argument. On the first-run flow's Accessibility page that argument is the page: printing
        /// `explanation` there restates the two paragraphs directly above it, in orange, and then
        /// truncates. Two phrasings of one state is normally the mistake this codebase avoids; here
        /// the two are answering different questions — *what is this and why* against *where do I
        /// stand* — and the second only reads as terse because the first has already been made.
        ///
        /// Derived from the case rather than stored, so a source cannot supply one and forget the
        /// other.
        ///
        /// **Only correct for a source that has a permission behind it**, which today is the
        /// notification source alone. `.working` reads "Granted", and that is a lie about Now
        /// Playing or the volume HUD — nobody granted those anything; they need nothing. `Status`
        /// cannot tell the two apart, because "running because you allowed it" and "running because
        /// it never had to ask" are the same case to it, and splitting the case to serve one label
        /// would be the tail wagging the dog. So the constraint lives here: render `brief` only for
        /// a row that asked for something. The long `explanation` is the one that is always true,
        /// which is why it is the default everywhere else.
        public var headline: String {
            switch self {
            case .working: settingsText("sources.status.granted", "Granted")
            case .needsPermission: settingsText("sources.status.notGranted", "Not granted yet")
            case .unavailable: settingsText("sources.status.unavailable", "Not available on this Mac")
            }
        }
    }

    /// One finer switch inside a row — a part of a source the user can turn off without turning the
    /// source off.
    ///
    /// **Not a row of its own, and that is a constraint rather than a layout choice.**
    /// `SourceSettingsRow` is keyed on `ActivityKind` so that two rows for one kind is not
    /// expressible (see `kind` below), and the case that needs this — volume, display brightness and
    /// keyboard backlight — is three levels of one `ActivityKind.systemHUD`. Minting kinds to buy
    /// rows would put a second spelling of `SystemHUD` into the vocabulary, which is the mistake
    /// `SourceToggles` opens by refusing.
    ///
    /// The app shell supplies these for the same reason it supplies everything else here: whether
    /// this Mac *has* a keyboard backlight is a live system read, and IslandSettings may not make
    /// one.
    public struct Option: Identifiable {

        /// Stable across a refresh, and the app shell's own vocabulary — a `SystemHUD.rawValue`
        /// today. Never shown.
        public let id: String

        /// The switch's label. It has to name what it governs on its own, because the row's title
        /// above it names the whole source.
        public let title: String

        /// The stored flag this switch writes. Not optional, unlike the row's: an option with
        /// nothing behind it is a switch that cannot move, and §10's rule for those is that they do
        /// not get drawn.
        public let toggle: WritableKeyPath<IsletaConfiguration, Bool>

        /// Why this Mac cannot do this one, or nil if it can.
        ///
        /// Present is what makes the switch draw disabled with a sentence under it. It is per option
        /// rather than folded into the row's `status` because that is the difference between "this
        /// MacBook Air has no keyboard backlight" and "this source does not work" — the row used to
        /// say the second when only the first was true.
        public let unavailable: String?

        public init(
            id: String,
            title: String,
            toggle: WritableKeyPath<IsletaConfiguration, Bool>,
            unavailable: String? = nil
        ) {
            self.id = id
            self.title = title
            self.toggle = toggle
            self.unavailable = unavailable
        }
    }

    /// A user-initiated offer. The **only** path in Isleta that may raise a permission prompt.
    public struct Action {
        public let title: String
        public let perform: @MainActor () -> Void

        public init(title: String, perform: @escaping @MainActor () -> Void) {
            self.title = title
            self.perform = perform
        }
    }

    /// The kind this source publishes. Doubles as the row's identity, so two rows for one kind is
    /// not expressible.
    public let kind: ActivityKind

    public var id: ActivityKind { kind }

    public let title: String

    /// What the source does, phrased so it still makes sense when the source cannot run. A row that
    /// only says "denied" tells the user what Isleta failed at; §10 asks for what they would gain.
    public let summary: String

    public let status: Status

    /// Present only when there is genuinely something to ask for. Nil for `.denied` — the system
    /// will not show the prompt a second time, so the honest offer there is the deep link the user
    /// asks for, not a button that appears to do nothing.
    public let action: Action?

    /// The parts of this source that can be switched separately. Empty for every source but the
    /// HUDs — see `Option`.
    public let options: [Option]

    /// The stored flag this row's switch writes, or nil for a source with no toggle.
    public var toggle: WritableKeyPath<IsletaConfiguration, Bool>? {
        SourceToggles.keyPath(for: kind)
    }

    public init(
        kind: ActivityKind,
        title: String,
        summary: String,
        status: Status,
        action: Action? = nil,
        options: [Option] = []
    ) {
        self.kind = kind
        self.title = title
        self.summary = summary
        self.status = status
        self.action = action
        self.options = options
    }
}
