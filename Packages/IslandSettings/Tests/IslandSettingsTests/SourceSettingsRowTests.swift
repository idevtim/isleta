import AppKit
import IslandActivities
import Testing

@testable import IslandSettings

/// The Sources section is data handed in by the app shell, so what is testable here is the contract
/// that data has to satisfy — and that the window actually renders it rather than throwing it away.
@Suite("Source settings rows")
@MainActor
struct SourceSettingsRowTests {

    private func rows() -> [SourceSettingsRow] {
        [
            SourceSettingsRow(
                kind: .nowPlaying,
                title: "Now Playing",
                summary: "Shows the track playing.",
                status: .working("Working.")
            ),
            SourceSettingsRow(
                kind: .glance,
                title: "Glance",
                summary: "Shows your day.",
                status: .needsPermission("Isleta needs your calendar."),
                action: SourceSettingsRow.Action(title: "Allow…") {}
            ),
            SourceSettingsRow(
                kind: .welcomeBack,
                title: "Welcome Back",
                summary: "Greets you when you come back.",
                status: .unavailable("Nothing to configure.")
            ),
        ]
    }

    /// The row's switch and the app shell's `SourceToggles[kind]` have to reach the same flag, or
    /// Settings writes one thing and the hub starts another.
    @Test("a row's toggle writes the flag its kind is stored under")
    func toggleMatchesTheKind() throws {
        for row in rows() {
            let keyPath = try #require(row.toggle)
            var configuration = IsletaConfiguration()
            configuration[keyPath: keyPath] = false
            #expect(configuration.sources[row.kind] == false)
        }
    }

    /// §10 in its testable form: a row that cannot run still says what it would do. A status string
    /// alone would leave a denied source described only by its failure.
    @Test("every row explains itself whether or not it can run")
    func everyRowCarriesAnExplanation() {
        for row in rows() {
            #expect(!row.summary.isEmpty)
            #expect(!row.status.explanation.isEmpty)
        }
    }

    /// The window has to *use* the rows, and it has to render the ones with a permission offer —
    /// a closure captured and never called is the silent failure here: the pane comes up, the
    /// Sources section is simply absent, and nothing anywhere reports it. Showing the window
    /// evaluates the SwiftUI body, and a body that reads the rows calls the closure.
    @Test("the settings window asks for the rows when it builds its content")
    func windowEvaluatesTheRowsProvider() {
        _ = NSApplication.shared
        var callCount = 0
        let supplied = rows()
        let controller = SettingsWindowController(
            store: SettingsStore(storage: InMemorySettingsStorage()),
            updater: UnavailableUpdater(),
            sourceRows: {
                callCount += 1
                return supplied
            }
        )
        controller.show()
        controller.close()
        #expect(callCount > 0)
    }

    // MARK: - Options

    /// Every source but the HUDs has none, and that is the default rather than something each row
    /// has to remember to say.
    @Test("a row has no finer switches unless it was given some")
    func rowsHaveNoOptionsByDefault() {
        for row in rows() {
            #expect(row.options.isEmpty)
        }
    }

    /// An option's switch writes a real flag, and one that is not the row's own. A sub-switch bound
    /// to the master would read as three switches doing one thing.
    @Test("an option writes a flag of its own")
    func optionsWriteTheirOwnFlag() throws {
        let row = SourceSettingsRow(
            kind: .systemHUD,
            title: "Volume, mute and brightness",
            summary: "Shows level changes.",
            status: .working("Working."),
            options: SystemHUD.allCases.map {
                SourceSettingsRow.Option(
                    id: $0.rawValue,
                    title: $0.rawValue,
                    toggle: SourceToggles.keyPath(for: $0)
                )
            }
        )

        let master = try #require(row.toggle)
        for option in row.options {
            #expect(option.toggle != master)
            var configuration = IsletaConfiguration()
            configuration[keyPath: option.toggle] = false
            // The master is untouched, so the source still runs and reports what is left.
            #expect(configuration.sources[row.kind])
            #expect(configuration.sources.enabledHUDs != Set(SystemHUD.allCases))
        }
    }

    /// The window renders them. An option list built and never drawn is the same silent failure
    /// `windowEvaluatesTheRowsProvider` guards the rows themselves against — the pane comes up, the
    /// three switches are simply absent, and nothing reports it.
    @Test("the settings window builds a row that carries options")
    func windowRendersOptions() {
        _ = NSApplication.shared
        let controller = SettingsWindowController(
            store: SettingsStore(storage: InMemorySettingsStorage()),
            updater: UnavailableUpdater(),
            sourceRows: {
                [
                    SourceSettingsRow(
                        kind: .systemHUD,
                        title: "Volume, mute and brightness",
                        summary: "Shows level changes.",
                        status: .working("Working."),
                        options: [
                            SourceSettingsRow.Option(
                                id: SystemHUD.volume.rawValue,
                                title: "Volume and mute",
                                toggle: SourceToggles.keyPath(for: .volume)
                            ),
                            SourceSettingsRow.Option(
                                id: SystemHUD.brightness.rawValue,
                                title: "Display brightness",
                                toggle: SourceToggles.keyPath(for: .brightness),
                                unavailable: "This Mac doesn't report a brightness level."
                            ),
                        ]
                    )
                ]
            }
        )
        controller.show()
        controller.close()
    }
}
