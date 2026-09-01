import Foundation

/// Which service a join link belongs to.
///
/// A closed vocabulary rather than a `String`, for the same reason `ActivityKind` is closed: the
/// island draws a glyph and a verb for each of these, and an open string would let the parser invent
/// a provider nothing downstream has a picture for. Adding one is meant to be an edit here, next to
/// the pattern it is recognized by.
public enum MeetingProvider: String, CaseIterable, Sendable {
    case zoom
    case teams
    case googleMeet
    case faceTime
    case webex
    case whereby
    case jitsi
    case chime
    case goTo
    case blueJeans
    case discord

    /// What the button says after "Join". The user's own words for the service, not the host name.
    public var displayName: String {
        switch self {
        case .zoom: "Zoom"
        case .teams: "Teams"
        case .googleMeet: "Google Meet"
        case .faceTime: "FaceTime"
        case .webex: "Webex"
        case .whereby: "Whereby"
        case .jitsi: "Jitsi"
        case .chime: "Chime"
        case .goTo: "GoTo"
        case .blueJeans: "BlueJeans"
        case .discord: "Discord"
        }
    }

    /// SF Symbols only (§6.5). Every one of these is a video call, so the glyph says *call* rather
    /// than trying to say *which* — a per-service mark would be a logo, and this project bundles no
    /// assets. FaceTime is the one exception because the system already has a mark for it.
    public var symbol: String {
        switch self {
        case .faceTime: "video.badge.waveform.fill"
        default: "video.fill"
        }
    }
}

/// A joinable meeting link found on a calendar event.
///
/// The URL is kept **whole**, query and fragment included. Zoom carries the passcode in `?pwd=`,
/// FaceTime carries the entire invitation after `#`, and a parser that rebuilt a "clean" URL from
/// the host and path would hand the user a link that opens a page asking for a password they were
/// never shown.
public struct MeetingLink: Equatable, Sendable {

    public let provider: MeetingProvider

    public let url: URL

    public init(provider: MeetingProvider, url: URL) {
        self.provider = provider
        self.url = url
    }

    /// "Join Zoom". What the island's one button says.
    ///
    /// The provider's name is an argument rather than part of the sentence: "Zoom" and "Google Meet"
    /// are the user's own words for the service in every language, and the verb around them is not.
    public var joinTitle: String {
        activityText("meeting.join", "Join \(provider.displayName)")
    }
}

/// Finds the join link on a calendar event.
///
/// ## The field named for it is empty, and the one that works is `notes`
///
/// Measured over 33 real events in a 14-day window (schema and counts only, no content read):
/// `url` **7/33**, `notes` **30/33**, `location` **8/33** — and **every** http(s) link that looked
/// like a join URL was in `notes`. `location` contained no http(s) host at all; it held room names
/// and street addresses. So the parse order is **`notes` → `url` → `location`**, and an
/// implementation that reads `event.url` first — the field literally named for it, and the one
/// every example reaches for — finds a link in under a quarter of events.
///
/// `EKEvent.conferenceURL` was also measured. It exists on the private ObjC surface alongside
/// `virtualConference` and `virtualConferenceTextRepresentation`, it is exactly what you would
/// reach for, and it answered **nil on all 33**. It is not used here and must not be added: a
/// private path in this codebase has to earn itself with a measurement, and this one measured zero.
///
/// ## The dial-in exclusion is part of the pattern set, not a refinement of it
///
/// `dialin.teams.microsoft.com` is a Teams host, it matches any naive "is this a Teams link" rule,
/// and in a real Teams invitation it sits **above** the join link in the note. So the first match
/// wins — and without this exclusion the first match is a page of telephone numbers. It is written
/// as a rejection inside the classifier rather than as a filter afterwards, because the scan has to
/// *keep going* past it to reach the real link two lines below.
///
/// ## Everything here is pure, and that is deliberate
///
/// Not one line of this file imports EventKit. The parse is the half of the calendar feature with
/// decisions in it, and it should be checkable without a calendar, without a permission and without
/// a running app — the same argument `NotchResolver` makes about screen geometry. `CalendarSource`
/// hands it three strings.
///
/// - Note: **nothing in this file may ever be logged.** A meeting URL identifies a specific call on
///   a specific account, and the log is bundled into the file "Export Logs…" hands to strangers.
///   `MeetingProvider` is a category with eleven values and is safe; the URL is not.
public enum MeetingLinkParser {

    /// The first join link on an event, searched in the order the fields actually carry one.
    ///
    /// - Parameters:
    ///   - notes: `EKEvent.notes`. Searched first because that is where the links are.
    ///   - url: `EKEvent.url`. Searched second — it is right when it is set, and it usually is not.
    ///   - location: `EKEvent.location`. Searched last and almost always in vain; it is here
    ///     because a person who pastes a link into the "where" field means it as the where.
    public static func firstLink(
        notes: String? = nil,
        url: URL? = nil,
        location: String? = nil
    ) -> MeetingLink? {
        if let notes, let link = firstLink(in: notes) { return link }
        if let url, let provider = provider(for: url) { return MeetingLink(provider: provider, url: url) }
        if let location, let link = firstLink(in: location) { return link }
        return nil
    }

    /// The first recognized link in a run of free text, reading order.
    ///
    /// Tokenised on whitespace rather than run through `NSDataDetector`, and that is not laziness.
    /// The detector finds *addresses, dates and phone numbers* too, it does not see custom schemes
    /// (`msteams:`, `zoommtg:`, `facetime:`) at all, and it would happily hand back the dial-in
    /// number sitting above the join link. What is wanted here is narrow: something shaped like a
    /// URL that one of eleven known services owns.
    public static func firstLink(in text: String) -> MeetingLink? {
        for token in tokens(in: text) {
            guard let url = URL(string: token), let provider = provider(for: url) else { continue }
            return MeetingLink(provider: provider, url: url)
        }
        return nil
    }

    /// Candidate URL strings, in the order they appear.
    ///
    /// The trimming is the whole of it. Real invitations wrap links in markdown (`<https://…>`),
    /// in HTML entities, in brackets, and end sentences with them — so a token taken verbatim off a
    /// whitespace split is `https://zoom.us/j/123>` about a third of the time, which parses into a
    /// `URL` whose host is right and whose path has a stray glyph on the end. Trimmed from **both**
    /// ends, because the opening bracket breaks the scheme and the closing one breaks the path.
    static func tokens(in text: String) -> [String] {
        text
            .split(whereSeparator: { $0.isWhitespace || $0.isNewline })
            .map { $0.trimmingCharacters(in: Self.wrapping) }
            .filter { !$0.isEmpty }
    }

    /// Punctuation that wraps a link in prose and is never part of one.
    ///
    /// A trailing `.` is in here and a trailing `/` deliberately is not: a sentence ending in a URL
    /// is common and a path ending in a slash is meaningful.
    private static let wrapping = CharacterSet(charactersIn: "<>()[]{}\"'“”‘’,;:.!?")

    // MARK: - Classification

    /// Which service owns this URL, or nil.
    ///
    /// Returns nil rather than throwing or defaulting, because "not a meeting link" is the answer
    /// for almost every URL in almost every calendar note — a document, an agenda, a ticket. A
    /// default of "probably a meeting" would put a Join button on an event whose note links to a
    /// spreadsheet.
    public static func provider(for url: URL) -> MeetingProvider? {
        // Custom schemes first, because they carry no host to reason about. Seen inside real notes
        // beside the https link they duplicate: an app that is installed opens these directly.
        switch url.scheme?.lowercased() {
        case "zoommtg", "zoomus": return .zoom
        case "msteams": return .teams
        case "facetime", "facetime-audio": return .faceTime
        case "http", "https": break
        default: return nil
        }

        guard var host = url.host?.lowercased() else { return nil }
        if host.hasPrefix("www.") { host.removeFirst(4) }
        let path = url.path.lowercased()

        // **The exclusion, first and by itself.** `dialin.teams.microsoft.com` ends in
        // `teams.microsoft.com`, so any rule that asks "is this a Teams host" says yes — and in a
        // real invitation this host appears *above* the join link. Rejecting it here rather than
        // filtering afterwards is what lets the scan carry on to the link two lines below.
        if host == "dialin.teams.microsoft.com" { return nil }

        if host == "zoom.us" || host.hasSuffix(".zoom.us") {
            // `/j/<digits>` is a scheduled meeting and `/my/<name>` a personal room; `/w/` and
            // `/s/` are the webinar and signed variants of the first. Anything else on a Zoom host
            // is their marketing site, their support pages, or a recording — none of which is a
            // meeting to join.
            guard path.hasPrefix("/j/") || path.hasPrefix("/my/")
                    || path.hasPrefix("/w/") || path.hasPrefix("/s/")
            else { return nil }
            return .zoom
        }

        if host == "teams.microsoft.com" || host == "teams.live.com"
            || host.hasSuffix(".teams.microsoft.com") {
            guard path.contains("/l/meetup-join/") else { return nil }
            return .teams
        }

        if host == "meet.google.com" {
            // `abc-defg-hij`. Checked rather than assumed because `meet.google.com` also serves
            // landing pages, and a Join button that opens Google's marketing site is worse than no
            // button at all.
            guard isGoogleMeetCode(String(path.dropFirst())) else { return nil }
            return .googleMeet
        }

        if host == "facetime.apple.com" {
            // The invitation is entirely in the fragment, which is why `url` is kept whole.
            guard path.hasPrefix("/join") else { return nil }
            return .faceTime
        }

        if host.hasSuffix("webex.com") {
            guard path.contains("/meet/") || path.contains("/j.php") || path.contains("/join/") else {
                return nil
            }
            return .webex
        }

        // Five services whose whole domain is meetings, so the host alone settles it. There is no
        // marketing site on `meet.jit.si` to be sent to by mistake.
        if host == "whereby.com" || host.hasSuffix(".whereby.com") { return .whereby }
        if host == "meet.jit.si" { return .jitsi }
        if host.hasSuffix("chime.aws") { return .chime }
        if host == "goto.com" || host.hasSuffix(".goto.com") { return .goTo }
        if host == "bluejeans.com" || host.hasSuffix(".bluejeans.com") { return .blueJeans }
        if host == "discord.gg" { return .discord }

        return nil
    }

    /// Whether a path component is a Google Meet code: three letters, four letters, three letters.
    ///
    /// Spelled out rather than done with a regular expression, for the reason this file is pure at
    /// all — the shape is three fixed-length lowercase runs and nothing else, and a regex here would
    /// be a second dialect to read. A trailing query (`?authuser=0`) never reaches this, because
    /// `URL.path` has already dropped it.
    static func isGoogleMeetCode(_ code: String) -> Bool {
        let parts = code.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return false }
        let lengths = [3, 4, 3]
        for (part, length) in zip(parts, lengths) {
            guard part.count == length, part.allSatisfy({ $0.isLowercase && $0.isLetter }) else {
                return false
            }
        }
        return true
    }
}
