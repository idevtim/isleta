import Foundation
import IslandActivities
import Testing

@testable import IslandActivities

/// A fixed instant, so every "in five minutes" below means the same five minutes on every machine.
private let noon = Date(timeIntervalSinceReferenceDate: 800_000_000)

private func event(
    _ title: String = "Standup",
    at offset: TimeInterval,
    lasting: TimeInterval = 1800,
    allDay: Bool = false,
    meeting: MeetingLink? = nil,
    id: String? = nil
) -> GlanceEvent {
    GlanceEvent(
        id: id ?? "\(title)@\(offset)",
        title: title,
        start: noon.addingTimeInterval(offset),
        end: noon.addingTimeInterval(offset + lasting),
        isAllDay: allDay,
        meeting: meeting
    )
}

private let zoom = MeetingLink(
    provider: .zoom,
    url: URL(string: "https://us02web.zoom.us/j/1234567890")!
)

@Suite("Glance policy")
struct GlancePolicyTests {

    @Test("what is next is the soonest thing not yet over")
    func nextIsSoonest() {
        let events = [event("Later", at: 7200), event("Soon", at: 600), event("Over", at: -7200)]
        #expect(GlancePolicy.next(in: events, at: noon)?.title == "Soon")
    }

    @Test("an event underway is still what is next")
    func underwayCounts() {
        // It has started and has not ended, so it is the thing the user is in — naming the *next*
        // one instead would tell somebody in a meeting about the one after it.
        let events = [event("Now", at: -600, lasting: 1800), event("After", at: 3600)]
        #expect(GlancePolicy.next(in: events, at: noon)?.title == "Now")
    }

    @Test("an all-day event is never what the flank names")
    func allDayIsNeverNext() {
        // The trailing sliver is 40pt and what it draws there is a time. An all-day event has none,
        // so it would put the one thing the sliver cannot render in front of the user's actual next
        // meeting.
        let events = [event("Conference", at: -3600, lasting: 86_400, allDay: true), event("Standup", at: 1800)]
        #expect(GlancePolicy.next(in: events, at: noon)?.title == "Standup")
    }

    @Test("an all-day event is still listed in the open island")
    func allDayIsListed() {
        let events = [event("Conference", at: 0, lasting: 86_400, allDay: true), event("Standup", at: 1800)]
        let listed = GlancePolicy.upcoming(in: events, at: noon)
        #expect(listed.map(\.title) == ["Conference", "Standup"])
    }

    @Test("all-day sorts before timed events on the same day, not by its midnight start")
    func allDaySortsFirstWithinItsDay() {
        // Sorting purely on `start` puts an all-day event at midnight and therefore always first —
        // the same answer by accident, and the wrong one the moment two days are in the window.
        //
        // Built against an explicit UTC calendar rather than `.current`, and the day boundaries are
        // asked for rather than assumed: an offset chosen by eye lands in a different day depending
        // on the machine's time zone, which is a test that passes in London and fails in Tokyo.
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let today = utc.startOfDay(for: noon)
        let now = today.addingTimeInterval(10 * 3600)

        let allDayToday = GlanceEvent(
            id: "a", title: "Today all day", start: today,
            end: today.addingTimeInterval(86_400), isAllDay: true
        )
        let timedToday = GlanceEvent(
            id: "b", title: "This afternoon", start: today.addingTimeInterval(14 * 3600),
            end: today.addingTimeInterval(15 * 3600)
        )
        let allDayTomorrow = GlanceEvent(
            id: "c", title: "Tomorrow all day", start: today.addingTimeInterval(86_400),
            end: today.addingTimeInterval(2 * 86_400), isAllDay: true
        )

        let listed = GlancePolicy.upcoming(
            in: [allDayTomorrow, timedToday, allDayToday], at: now, limit: 5, calendar: utc
        )
        #expect(listed.map(\.title) == ["Today all day", "This afternoon", "Tomorrow all day"])
    }

    @Test("finished events are dropped")
    func finishedIsDropped() {
        #expect(GlancePolicy.upcoming(in: [event("Over", at: -7200, lasting: 1800)], at: noon).isEmpty)
    }

    @Test("the list is capped, because the island is not a window")
    func listIsCapped() {
        let many = (1...10).map { event("Event \($0)", at: TimeInterval($0) * 600) }
        #expect(GlancePolicy.upcoming(in: many, at: noon).count == GlancePolicy.maximumEvents)
    }

    // MARK: - Alerts

    @Test("an event inside the lead alerts, one outside it does not")
    func alertWindow() {
        let inside = event("Soon", at: GlancePolicy.alertLead - 60)
        let outside = event("Later", at: GlancePolicy.alertLead + 60)
        let alerting = GlancePolicy.alerting(in: [inside, outside], at: noon)
        #expect(alerting.map(\.title) == ["Soon"])
    }

    @Test("an event already underway does not alert")
    func startedDoesNotAlert() {
        // It is not news, it is a fact the user is living in — and without this it would re-alert on
        // every boundary for the length of the meeting.
        #expect(GlancePolicy.alerting(in: [event("Now", at: -60)], at: noon).isEmpty)
    }

    @Test("all-day events never alert")
    func allDayDoesNotAlert() {
        #expect(
            GlancePolicy.alerting(in: [event("Conf", at: 120, allDay: true)], at: noon).isEmpty
        )
    }

    // MARK: - Meetings

    @Test("a joinable link inside the tight lead is offered")
    func joinableWindow() {
        let soon = event("Standup", at: GlancePolicy.meetingLead - 10, meeting: zoom)
        #expect(GlancePolicy.joinable(in: [soon], at: noon).count == 1)
    }

    @Test("a joinable link five minutes out is not offered yet")
    func joinableIsTighterThanTheAlert() {
        // An alert is information and can afford to be early; a Join button is an instruction, and
        // one offered five minutes out is an instruction to arrive early to an empty room.
        let early = event("Standup", at: GlancePolicy.alertLead - 30, meeting: zoom)
        #expect(GlancePolicy.joinable(in: [early], at: noon).isEmpty)
        #expect(GlancePolicy.alerting(in: [early], at: noon).count == 1)
    }

    @Test("the offer survives a couple of minutes of lateness and then stops")
    func joinableGrace() {
        let late = event("Standup", at: -GlancePolicy.meetingGrace + 10, meeting: zoom)
        let tooLate = event("Standup", at: -GlancePolicy.meetingGrace - 10, meeting: zoom)
        #expect(GlancePolicy.joinable(in: [late], at: noon).count == 1)
        #expect(GlancePolicy.joinable(in: [tooLate], at: noon).isEmpty)
    }

    @Test("an event with no link is never joinable, however close it is")
    func noLinkIsNotJoinable() {
        #expect(GlancePolicy.joinable(in: [event("Lunch", at: 10)], at: noon).isEmpty)
    }

    // MARK: - The one timer

    @Test("the next boundary is the soonest instant any answer could change")
    func nextBoundary() {
        // Five minutes out, so the alert boundary (start − 300) has already passed and the next
        // thing that can change is the start itself.
        let soon = event("Standup", at: 240)
        #expect(GlancePolicy.nextBoundary(in: [soon], at: noon) == soon.start)
    }

    @Test("a far-off event wakes the source at its alert boundary, not at its start")
    func boundaryIsTheAlert() {
        let later = event("Review", at: 7200)
        #expect(
            GlancePolicy.nextBoundary(in: [later], at: noon)
                == later.start.addingTimeInterval(-GlancePolicy.alertLead)
        )
    }

    @Test("an empty calendar has no boundary, and therefore no timer at all")
    func noEventsNoTimer() {
        // This is the §9 claim in one line: nothing in the diary means `CalendarSource` arms
        // nothing, rather than arming a minute timer that finds nothing sixty times an hour.
        #expect(GlancePolicy.nextBoundary(in: [], at: noon) == nil)
    }

    @Test("events entirely in the past produce no boundary")
    func pastEventsNoBoundary() {
        #expect(GlancePolicy.nextBoundary(in: [event("Over", at: -7200, lasting: 600)], at: noon) == nil)
    }
}

@Suite("Calendar access states")
struct CalendarAccessTests {

    @Test("a denied calendar and an empty one get different words")
    func deniedIsNotEmpty() {
        // Measured: a denied store answers zero sources, zero calendars, a valid predicate and `[]`
        // in 1–4 ms **without throwing**. `authorizationStatus` is the only discriminator there is,
        // which is why the empty-state copy is chosen from it and never from `events.isEmpty`.
        #expect(CalendarAccess.denied.emptyStateMessage != CalendarAccess.granted.emptyStateMessage)
        #expect(CalendarAccess.notDetermined.emptyStateMessage != CalendarAccess.denied.emptyStateMessage)
    }

    @Test("only full access reads")
    func onlyGrantedReads() {
        #expect(CalendarAccess.granted.isReadable)
        // Write-only authorises *saving* and returns no calendars — the opposite of what a
        // "what's next" surface needs, and why Isleta ships the FullAccess usage key.
        #expect(!CalendarAccess.writeOnly.isReadable)
        #expect(!CalendarAccess.denied.isReadable)
        #expect(!CalendarAccess.notDetermined.isReadable)
        #expect(!CalendarAccess.restricted.isReadable)
    }

    @Test("every state has something to say")
    func everyStateHasCopy() {
        for access in [CalendarAccess.granted, .notDetermined, .denied, .restricted, .writeOnly] {
            #expect(!access.emptyStateMessage.isEmpty)
        }
    }
}

@Suite("Glance formatting")
struct GlanceFormatTests {

    @Test("a clock time follows the user's own 12- or 24-hour setting")
    func clockRespectsLocale() {
        // A hardcoded HH:mm shows 14:30 to somebody whose Mac says 2:30 PM — the sort of wrongness
        // nobody reports and everybody notices.
        let afternoon = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let uk = GlanceFormat.clock(afternoon, locale: Locale(identifier: "en_GB"))
        let us = GlanceFormat.clock(afternoon, locale: Locale(identifier: "en_US"))
        #expect(!uk.isEmpty)
        #expect(us.contains("AM") || us.contains("PM"))
    }

    @Test("how long until it starts")
    func startsIn() {
        #expect(GlanceFormat.startsIn(noon.addingTimeInterval(10), from: noon) == "Starting now")
        #expect(GlanceFormat.startsIn(noon.addingTimeInterval(240), from: noon) == "In 4 min")
        #expect(GlanceFormat.startsIn(noon.addingTimeInterval(7200), from: noon) == "In 2 hr")
    }

    @Test("the day header says Today and Tomorrow before it says a weekday")
    func dayHeader() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        #expect(GlanceFormat.day(noon, relativeTo: noon, calendar: calendar) == "Today")
        #expect(
            GlanceFormat.day(noon.addingTimeInterval(86_400), relativeTo: noon, calendar: calendar) == "Tomorrow"
        )
    }

    @Test("an all-day row says so instead of showing a midnight")
    func allDayRowTime() {
        #expect(GlanceFormat.rowTime(event("Conf", at: 0, allDay: true)) == "All day")
    }
}

/// The link a click on an event follows into Calendar.
///
/// `ical://ekevent` is undocumented and cannot be checked at runtime — `NSWorkspace.open` answers
/// for the scheme having a handler and not for Calendar making anything of the path — so what is
/// pinned here is everything about the URL that *is* answerable without a calendar: that an event
/// with nothing to open says so rather than building a link to nowhere, and that an identifier from
/// a server that does not deal in UUIDs survives being put in a path.
@Suite("The link into Calendar")
struct GlanceEventLinkTests {

    private func event(id: String, externalID: String) -> GlanceEvent {
        GlanceEvent(
            id: id,
            title: "Standup",
            start: Date(timeIntervalSinceReferenceDate: 0),
            end: Date(timeIntervalSinceReferenceDate: 3600),
            externalID: externalID
        )
    }

    /// **No identifier is not a reason to build a link.** EventKit can hand back an event with no
    /// `eventIdentifier`, and a URL built from the empty string opens Calendar at nothing while
    /// looking exactly like a link that worked.
    @Test("an event with no identifier has no link rather than a broken one")
    func noIdentifierNoLink() {
        #expect(GlanceEventLink.urlString(for: event(id: "a@0", externalID: "")) == nil)
        #expect(GlanceEventLink.urlString(for: event(id: "a@0", externalID: "ABC")) != nil)
    }

    /// The identifier is the whole of the path, and it is the *unqualified* one — `GlanceEvent.id`
    /// carries the occurrence's start welded on, which Calendar would make nothing of.
    @Test("the link names the event's own identifier and asks Calendar to show it")
    func linkNamesTheEvent() {
        let link = GlanceEventLink.urlString(for: event(id: "ABC@12345.6", externalID: "ABC"))
        #expect(link == "ical://ekevent/ABC?method=show&options=more")
    }

    /// **A CalDAV identifier is not a UUID.** An unescaped slash would turn one path component into
    /// two and hand Calendar an identifier that ends where the slash was — a failure that looks
    /// identical to every other way this can fail, because it opens the app at nothing.
    @Test("an identifier that is not URL-safe survives being put in a path")
    func identifiersAreEscaped() {
        #expect(GlanceEventLink.escaped("A/B") == "A%2FB")
        #expect(GlanceEventLink.escaped("A?B") == "A%3FB")
        #expect(GlanceEventLink.escaped("A#B") == "A%23B")
        // The tidy local form is left exactly as it is: a colon is legal in a path component, and
        // escaping one would change an identifier that was already correct.
        #expect(GlanceEventLink.escaped("3F2B:3F2B") == "3F2B:3F2B")

        let link = GlanceEventLink.urlString(for: event(id: "x", externalID: "A/B"))
        #expect(link == "ical://ekevent/A%2FB?method=show&options=more")
        #expect(URL(string: link ?? "") != nil)
    }

    /// The form that was tried on hardware and did not open the event. Kept and pinned so that
    /// "we already tried this" is a fact in the repository rather than a memory.
    @Test("the occurrence-qualified form is still spelled correctly, and still not the one used")
    func theDatedFormIsKeptButUnused() {
        let start = Date(timeIntervalSinceReferenceDate: 0)  // 2001-01-01 00:00:00 UTC
        #expect(GlanceEventLink.utcStamp(start) == "20010101T000000Z")
        #expect(GlanceEventLink.dated(identifier: "ABC", start: start)
                == "ical://ekevent/20010101T000000Z/ABC?method=show&options=more")
        #expect(GlanceEventLink.urlString(for: event(id: "x", externalID: "ABC"))
                != GlanceEventLink.dated(identifier: "ABC", start: start))
    }
}

/// The format MediaRemote publishes on the playing queue entry — the one route that answers.
///
/// Everything here is the parse. What was measured on hardware, macOS 27.0 2026-08-28, on an Apple
/// Music lossless stream, is the dictionary it parses:
/// `sampleRate 44100, bitDepth 0, bitrate 0, codec 1902928227, tier 2, spatialized false,
/// multiChannel false`.
@Suite("The format on the playing queue entry")
struct AudioFormatFieldsTests {

    /// The measured case, exactly as it arrives.
    @Test("the lossless stream that was measured reads as Lossless")
    func measuredLossless() {
        let fields: [String: Any] = [
            "sampleRate": 44100, "bitDepth": 0, "bitrate": 0,
            "codec": 1_902_928_227, "tier": 2, "spatialized": false, "multiChannel": false,
        ]
        #expect(AudioFormat(mediaRemoteFields: fields)?.name == "Lossless")
    }

    /// **A bitrate is what makes something lossy**, which is the discriminator rather than the
    /// codec: the codec came back as `'qlac'`, Apple's own streaming variant, which appears in no
    /// published FourCC table — an allow-list would have to be discovered one value at a time and
    /// would answer nothing for every value not yet seen.
    @Test("a fixed bitrate is lossy and no bitrate is not")
    func bitrateDiscriminates() {
        #expect(AudioFormat(mediaRemoteFields: ["sampleRate": 44100, "bitrate": 256_000])?.name == "AAC")
        #expect(AudioFormat(mediaRemoteFields: ["sampleRate": 44100, "bitrate": 0])?.name == "Lossless")
    }

    /// Apple's own line: Lossless tops out at 48 kHz and everything above it is Hi-Res.
    @Test("above 48 kHz, lossless becomes Hi-Res Lossless")
    func hiRes() {
        #expect(AudioFormat(mediaRemoteFields: ["sampleRate": 48000, "bitrate": 0])?.name == "Lossless")
        #expect(AudioFormat(mediaRemoteFields: ["sampleRate": 96000, "bitrate": 0])?.name == "Hi-Res Lossless")
        #expect(AudioFormat(mediaRemoteFields: ["sampleRate": 192_000, "bitrate": 0])?.name == "Hi-Res Lossless")
    }

    /// The second measured case, and the one that caught an ordering bug: **a Dolby Atmos stream
    /// reports a bitrate.** `sampleRate 48000, bitrate 768, tier 4, spatialized true,
    /// multiChannel true` — so any rule that reached the lossy branch first would have put "AAC"
    /// under an Atmos track.
    @Test("the Atmos stream that was measured reads as Dolby Atmos, bitrate and all")
    func measuredAtmos() {
        let fields: [String: Any] = [
            "sampleRate": 48000, "bitDepth": 0, "bitrate": 768, "codec": 1_902_324_531,
            "tier": 4, "spatialized": true, "multiChannel": true, "renderingMode": 5,
        ]
        #expect(AudioFormat(mediaRemoteFields: fields)?.name == "Dolby Atmos")
    }

    /// What a track is *delivered as* outranks how hard it was compressed: the layout is a fact the
    /// player states and the bitrate reading is an inference from the shape of it. So the layout
    /// tests come first, and a multichannel track with a bitrate is not called AAC.
    @Test("channel layout is read before the bitrate, not after it")
    func layoutBeatsBitrate() {
        #expect(AudioFormat(mediaRemoteFields: [
            "sampleRate": 192_000, "bitrate": 256_000, "spatialized": true,
        ])?.name == "Dolby Atmos")
        #expect(AudioFormat(mediaRemoteFields: [
            "sampleRate": 48000, "bitrate": 256_000, "multiChannel": true,
        ])?.name == "Multichannel")
        #expect(AudioFormat(mediaRemoteFields: [
            "sampleRate": 48000, "bitrate": 0, "multiChannel": true,
        ])?.name == "Multichannel")
    }

    /// **A dictionary that says nothing is not a format.** Every key here is one Apple can rename,
    /// and the honest answer to a dictionary this no longer understands is no badge rather than a
    /// default one — the island draws one line fewer.
    @Test("an empty or unrecognisable dictionary is not a format")
    func nothingIsNotAFormat() {
        #expect(AudioFormat(mediaRemoteFields: [:]) == nil)
        #expect(AudioFormat(mediaRemoteFields: ["renderingMode": 1, "tier": 2]) == nil)
        #expect(AudioFormat(mediaRemoteFields: ["sampleRate": 0, "bitrate": 0]) == nil)
    }
}

/// The mark beside the words.
@Suite("The audio format's mark")
struct AudioFormatSymbolTests {

    private func format(_ fields: [String: Any]) -> AudioFormat? {
        AudioFormat(mediaRemoteFields: fields)
    }

    /// **Not the logo Apple draws.** Apple puts the Dolby Atmos logotype beside an Atmos track under
    /// licence from Dolby; Isleta has no such licence, so it uses an SF Symbol that claims nothing
    /// about who endorsed what. This test exists to make that a decision on the record rather than
    /// an omission somebody later "fixes".
    @Test("each kind carries its own SF Symbol, and none of them is a trademark")
    func symbolsPerKind() {
        #expect(format(["spatialized": true, "sampleRate": 48000])?.symbol == "cube")
        #expect(format(["multiChannel": true, "sampleRate": 48000])?.symbol == "speaker.wave.3")
        #expect(format(["sampleRate": 96000, "bitrate": 0])?.symbol == "waveform.badge.plus")
        #expect(format(["sampleRate": 44100, "bitrate": 0])?.symbol == "waveform")
        // Lossless and lossy share the plain waveform: a track being AAC is not a thing to
        // decorate, and a mark of its own would read as a demerit badge.
        #expect(format(["sampleRate": 44100, "bitrate": 256_000])?.symbol
                == format(["sampleRate": 44100, "bitrate": 0])?.symbol)
    }

    /// The words and the mark are two readings of one value, so they cannot be set to disagree —
    /// which is the whole reason `name` is derived from `kind` rather than stored beside it.
    @Test("the words follow the kind the mark comes from")
    func nameFollowsKind() {
        for (fields, kind, label) in [
            (["spatialized": true, "sampleRate": 48000] as [String: Any], AudioFormat.Kind.dolbyAtmos, "Dolby Atmos"),
            (["multiChannel": true, "sampleRate": 48000], .multichannel, "Multichannel"),
            (["sampleRate": 96000, "bitrate": 0], .hiResLossless, "Hi-Res Lossless"),
            (["sampleRate": 44100, "bitrate": 0], .lossless, "Lossless"),
            (["sampleRate": 44100, "bitrate": 256_000], .lossy, "AAC"),
        ] {
            let resolved = format(fields)
            #expect(resolved?.kind == kind)
            #expect(resolved?.name == label)
        }
    }
}
