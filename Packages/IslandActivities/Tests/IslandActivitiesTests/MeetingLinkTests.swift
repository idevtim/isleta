import Foundation
import Testing

@testable import IslandActivities

/// The join-link parser, exercised with no EventKit, no calendar and no permission.
///
/// That is the whole reason `MeetingLinkParser` is pure: the decisions in this feature are all in
/// here — which field is read first, which host counts, and which one host that looks exactly right
/// must be skipped — and none of them should need a calendar to check.
@Suite("Meeting links")
struct MeetingLinkTests {

    // MARK: - The field order

    @Test("notes is read before url, because that is where the links actually are")
    func notesWinsOverURL() {
        // Measured over 33 real events: `url` 7/33, `notes` 30/33, and every http(s) link that
        // looked like a join URL was in `notes`. An implementation that reads `event.url` first —
        // the field named for it — finds a link in under a quarter of events.
        let link = MeetingLinkParser.firstLink(
            notes: "Join Zoom Meeting\nhttps://us02web.zoom.us/j/1234567890?pwd=abc",
            url: URL(string: "https://meet.google.com/abc-defg-hij")
        )
        #expect(link?.provider == .zoom)
    }

    @Test("url is read when the notes carry nothing joinable")
    func urlIsSecond() {
        let link = MeetingLinkParser.firstLink(
            notes: "Agenda: https://example.com/doc",
            url: URL(string: "https://meet.google.com/abc-defg-hij")
        )
        #expect(link?.provider == .googleMeet)
    }

    @Test("location is read last, and usually holds a room")
    func locationIsLast() {
        // `location` held zero http(s) hosts across all 33 events — room names and addresses. It is
        // searched because somebody who pastes a link into the "where" field means it as the where.
        #expect(MeetingLinkParser.firstLink(location: "Meeting Room 4, 2nd floor") == nil)
        #expect(
            MeetingLinkParser.firstLink(location: "https://whereby.com/standup")?.provider == .whereby
        )
    }

    @Test("nothing anywhere is nil, not a guess")
    func nothingIsNil() {
        #expect(MeetingLinkParser.firstLink() == nil)
        #expect(MeetingLinkParser.firstLink(notes: "Bring the deck.", location: "Kitchen") == nil)
    }

    // MARK: - The dial-in exclusion

    @Test("dialin.teams.microsoft.com is skipped, and the real link below it is found")
    func teamsDialInIsExcluded() {
        // This is the shape of a real Teams invitation: the dial-in host sits **above** the join
        // link. It ends in `teams.microsoft.com`, so any "is this a Teams host" rule says yes — and
        // first match wins, so without the exclusion the button opens a page of phone numbers.
        let notes = """
            ________________________________________
            Microsoft Teams meeting
            Or call in (audio only)
            https://dialin.teams.microsoft.com/1234abcd?id=987654321
            Join on your computer or mobile app
            https://teams.microsoft.com/l/meetup-join/19%3ameeting_ABC%40thread.v2/0
            """
        let link = MeetingLinkParser.firstLink(notes: notes)
        #expect(link?.provider == .teams)
        #expect(link?.url.absoluteString.contains("meetup-join") == true)
        #expect(link?.url.host == "teams.microsoft.com")
    }

    @Test("a dial-in link on its own yields nothing rather than a Teams button")
    func dialInAloneIsNotAMeeting() {
        #expect(
            MeetingLinkParser.firstLink(notes: "https://dialin.teams.microsoft.com/1234abcd?id=1") == nil
        )
    }

    // MARK: - Per-service patterns

    @Test("Zoom, and the passcode survives")
    func zoom() {
        // `?pwd=` is the passcode. A parser that rebuilt a "clean" URL from host and path would
        // hand the user a link that opens a page asking for something they were never shown.
        let link = MeetingLinkParser.firstLink(notes: "https://us02web.zoom.us/j/1234567890?pwd=SGVsbG8")
        #expect(link?.provider == .zoom)
        #expect(link?.url.query == "pwd=SGVsbG8")
    }

    @Test("Zoom personal rooms and webinars")
    func zoomVariants() {
        #expect(MeetingLinkParser.firstLink(notes: "https://zoom.us/my/tim")?.provider == .zoom)
        #expect(MeetingLinkParser.firstLink(notes: "https://zoom.us/w/98765")?.provider == .zoom)
    }

    @Test("a Zoom host that is not a meeting is not a meeting")
    func zoomMarketingIsNotAMeeting() {
        // A Join button that opens Zoom's pricing page is worse than no button.
        #expect(MeetingLinkParser.firstLink(notes: "https://zoom.us/pricing") == nil)
        #expect(MeetingLinkParser.firstLink(notes: "https://us02web.zoom.us/rec/share/xyz") == nil)
    }

    @Test("Google Meet, and only with a real code")
    func googleMeet() {
        #expect(
            MeetingLinkParser.firstLink(notes: "https://meet.google.com/abc-defg-hij")?.provider == .googleMeet
        )
        // The landing page and the support pages live on the same host.
        #expect(MeetingLinkParser.firstLink(notes: "https://meet.google.com/") == nil)
        #expect(MeetingLinkParser.firstLink(notes: "https://meet.google.com/landing") == nil)
        // Right shape, wrong lengths.
        #expect(MeetingLinkParser.firstLink(notes: "https://meet.google.com/ab-cdef-ghi") == nil)
        // Digits are not letters.
        #expect(MeetingLinkParser.firstLink(notes: "https://meet.google.com/abc-de1g-hij") == nil)
    }

    @Test("FaceTime keeps its fragment, which is the whole invitation")
    func faceTime() {
        let raw = "https://facetime.apple.com/join#v=1&p=abcdef&k=ghijkl"
        let link = MeetingLinkParser.firstLink(notes: raw)
        #expect(link?.provider == .faceTime)
        #expect(link?.url.absoluteString == raw)
    }

    @Test("Webex, on both of its shapes")
    func webex() {
        #expect(
            MeetingLinkParser.firstLink(notes: "https://acme.webex.com/meet/tim")?.provider == .webex
        )
        #expect(
            MeetingLinkParser.firstLink(notes: "https://acme.webex.com/acme/j.php?MTID=m123")?.provider == .webex
        )
        #expect(MeetingLinkParser.firstLink(notes: "https://www.webex.com/pricing.html") == nil)
    }

    @Test("the five services whose whole domain is meetings")
    func hostOnlyServices() {
        let cases: [(String, MeetingProvider)] = [
            ("https://whereby.com/isleta", .whereby),
            ("https://meet.jit.si/StandUp", .jitsi),
            ("https://chime.aws/1234567890", .chime),
            ("https://acme.goto.com/join/123456789", .goTo),
            ("https://bluejeans.com/123456789", .blueJeans),
            ("https://discord.gg/abcdef", .discord),
        ]
        for (raw, provider) in cases {
            #expect(MeetingLinkParser.firstLink(notes: raw)?.provider == provider, "\(raw)")
        }
    }

    @Test("custom schemes seen inside real notes")
    func customSchemes() {
        // `msteams:` and `zoommtg:` appear beside the https link they duplicate, and an app that is
        // installed opens them directly.
        #expect(MeetingLinkParser.firstLink(notes: "msteams:/l/meetup-join/19%3ameeting")?.provider == .teams)
        #expect(MeetingLinkParser.firstLink(notes: "zoommtg://zoom.us/join?confno=123")?.provider == .zoom)
        #expect(MeetingLinkParser.firstLink(notes: "facetime://tim@example.com")?.provider == .faceTime)
        #expect(MeetingLinkParser.firstLink(notes: "facetime-audio://+15551234")?.provider == .faceTime)
    }

    @Test("a scheme nobody recognizes is not a meeting")
    func unknownSchemes() {
        #expect(MeetingLinkParser.firstLink(notes: "mailto:tim@example.com") == nil)
        #expect(MeetingLinkParser.firstLink(notes: "tel:+15551234") == nil)
        #expect(MeetingLinkParser.firstLink(notes: "ftp://files.example.com/deck.key") == nil)
    }

    // MARK: - Real notes are messy

    @Test("links wrapped in prose, brackets and markdown")
    func trimming() {
        // A whitespace split alone gives `https://zoom.us/j/1>` about a third of the time, which
        // parses into a URL with a stray glyph on the end of its path.
        let wrapped = [
            "<https://us02web.zoom.us/j/1234567890>",
            "(https://us02web.zoom.us/j/1234567890)",
            "\"https://us02web.zoom.us/j/1234567890\"",
            "Dial in at https://us02web.zoom.us/j/1234567890.",
            "[https://us02web.zoom.us/j/1234567890],",
        ]
        for raw in wrapped {
            let link = MeetingLinkParser.firstLink(notes: raw)
            #expect(link?.provider == .zoom, "\(raw)")
            #expect(link?.url.path == "/j/1234567890", "\(raw)")
        }
    }

    @Test("a trailing slash is part of a path and is not trimmed off")
    func trailingSlashSurvives() {
        // Asserted on `absoluteString` rather than on `path`, because `URL.path` normalizes the
        // trailing slash away on its own — which is Foundation's business and not the parser's. What
        // is being pinned here is that `/` is absent from the wrapping character set: a link handed
        // to `NSWorkspace` has to be the link that was in the note, byte for byte.
        #expect(
            MeetingLinkParser.firstLink(notes: "https://whereby.com/isleta/")?.url.absoluteString
                == "https://whereby.com/isleta/"
        )
    }

    @Test("the first recognized link in reading order wins")
    func firstMatchWins() {
        let notes = """
            https://example.com/agenda
            https://us02web.zoom.us/j/111
            https://meet.google.com/abc-defg-hij
            """
        #expect(MeetingLinkParser.firstLink(notes: notes)?.provider == .zoom)
    }

    @Test("www. is stripped before the host is judged")
    func wwwPrefix() {
        #expect(MeetingLinkParser.firstLink(notes: "https://www.zoom.us/j/123")?.provider == .zoom)
    }

    @Test("case in the host does not matter")
    func hostCase() {
        #expect(MeetingLinkParser.firstLink(notes: "HTTPS://US02WEB.ZOOM.US/j/123")?.provider == .zoom)
    }

    // MARK: - What the button says

    @Test("the join title names the service in the user's words")
    func joinTitle() {
        let link = MeetingLink(provider: .googleMeet, url: URL(string: "https://meet.google.com/abc-defg-hij")!)
        #expect(link.joinTitle == "Join Google Meet")
    }

    @Test("every provider has a glyph and a name")
    func everyProviderIsDrawable() {
        for provider in MeetingProvider.allCases {
            #expect(!provider.displayName.isEmpty)
            #expect(!provider.symbol.isEmpty)
        }
    }
}
