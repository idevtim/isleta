import Foundation
import Testing

@testable import IslandSettings

/// The first-run flow's two pieces of logic: where the pages go, and whether the window opens at
/// all. Neither needs a window, which is the point of both being values.
@Suite("Onboarding steps")
struct OnboardingStepTests {

    @Test("the pages run welcome → five permissions → startup → ready")
    func orderIsTheDeclaredOne() {
        #expect(OnboardingStep.allCases == [
            .welcome, .accessibility, .music, .calendar, .weather, .devices, .startup, .ready
        ])
    }

    /// Accessibility is first of the five on purpose — see `OnboardingStep.accessibility`, which
    /// holds the argument this pins. Asserted separately from the whole order so that a page
    /// inserted in the middle fails one test with a clear name rather than only the list above.
    @Test("the HUD permission is the first one asked for")
    func accessibilityLeads() {
        #expect(OnboardingStep.permissions.first == .accessibility)
    }

    /// The list the flow is *for*, and the reason it is derived rather than written twice.
    ///
    /// A page added to the enum without a `permission` is a page that quietly asks for nothing —
    /// which is exactly what happened to Accessibility when notifications were withdrawn and it left
    /// the flow, while three doc comments went on saying it was still there.
    @Test("every permission has exactly one page, and every page names its permission once")
    func permissionsAreOnePerPage() {
        #expect(OnboardingStep.permissions == [.accessibility, .music, .calendar, .weather, .devices])
        let named = OnboardingStep.allCases.compactMap(\.permission)
        #expect(Set(named).count == named.count, "two pages claim one permission")
        #expect(Set(named) == Set(OnboardingPermission.allCases), "a permission has no page")
    }

    /// The three that are a tour rather than a question. Asserted rather than left implied, because
    /// "which pages ask for something" is what decides whether Continue advances or offers.
    @Test("the welcome, startup and ready pages ask for nothing")
    func toursAskForNothing() {
        for step in [OnboardingStep.welcome, .startup, .ready] {
            #expect(step.permission == nil)
        }
    }

    /// `--onboarding <page>` has to reach every page, or the one you cannot open is the one you
    /// cannot look at — the flow is otherwise a thing you get one look at per machine.
    @Test("every page can be opened by name, and nothing else can")
    func namesRoundTrip() {
        let names = ["welcome", "accessibility", "music", "calendar", "weather", "devices", "startup", "ready"]
        #expect(names.count == OnboardingStep.allCases.count)
        for (name, step) in zip(names, OnboardingStep.allCases) {
            #expect(OnboardingStep(name: name) == step)
        }
        #expect(OnboardingStep(name: "notifications") == nil)
    }

    /// The ends have to be nil rather than wrapping. A `next` that came back round to `.welcome`
    /// would turn the last page's button into one that restarts the flow — and it is the button the
    /// user presses to leave.
    @Test("the flow does not wrap at either end")
    func endsAreClosed() {
        #expect(OnboardingStep.welcome.previous == nil)
        #expect(OnboardingStep.ready.next == nil)
        #expect(OnboardingStep.welcome.isLast == false)
        #expect(OnboardingStep.ready.isLast)
        #expect(OnboardingStep.allCases.filter(\.isLast).count == 1)
    }

    @Test("every step but the last leads to the next one, and back again")
    func stepsAreReversible() {
        for step in OnboardingStep.allCases {
            guard let next = step.next else { continue }
            #expect(next.previous == step)
        }
    }

    /// The last page's button says something different, because pressing it does something
    /// different — it closes the flow rather than advancing it.
    @Test("only the last page offers to finish")
    func lastPageAdvanceTitle() {
        // Asserts against the source language: under `swift test` every lookup falls back to the
        // English `defaultValue`. `LocalizationCoverageTests` is what guards the other languages.
        #expect(OnboardingStep.ready.advanceTitle == "Get Started")
        for step in OnboardingStep.allCases where !step.isLast {
            #expect(step.advanceTitle == "Continue")
        }
    }
}

@Suite("Onboarding ledger")
struct OnboardingLedgerTests {

    /// Its own suite every time, never `.standard`. A test that marks onboarding complete in the
    /// real defaults passes on a clean machine and then permanently suppresses the flow on the
    /// machine it ran on — which is a bug you cannot reproduce, because you caused it.
    private func makeLedger() throws -> OnboardingLedger {
        let name = "com.tryisleta.tests.onboarding.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        return OnboardingLedger(defaults: defaults)
    }

    @Test("a Mac that has never been onboarded is offered the flow")
    func freshInstallPresents() throws {
        let ledger = try makeLedger()
        #expect(ledger.completedVersion == 0)
        #expect(ledger.shouldPresent)
    }

    @Test("finishing stops it coming back")
    func completionSuppresses() throws {
        let ledger = try makeLedger()
        ledger.markComplete()
        #expect(ledger.completedVersion == OnboardingLedger.currentVersion)
        #expect(!ledger.shouldPresent)
    }

    /// The reason this is a version and not a `Bool`. A release that adds a permission has to reach
    /// people who were onboarded before it existed, and "onboarded" alone cannot say which questions
    /// they were asked.
    @Test("a Mac onboarded on an older flow is offered the newer one")
    func olderFlowIsRepresented() throws {
        let ledger = try makeLedger()
        ledger.completedVersion = OnboardingLedger.currentVersion - 1
        #expect(ledger.shouldPresent)
    }

    /// `<` rather than `!=`. Somebody who briefly ran a newer Isleta and went back has already
    /// answered a superset of what this build would ask, and making them sit through the older flow
    /// would be the downgrade's most visible symptom.
    @Test("a Mac onboarded on a newer flow is not sent back through an older one")
    func newerFlowIsNotRepeated() throws {
        let ledger = try makeLedger()
        ledger.completedVersion = OnboardingLedger.currentVersion + 5
        #expect(!ledger.shouldPresent)
    }

    /// What `--onboarding-reset` is for: the flow is otherwise a thing you get one look at per
    /// machine, which makes the real first-launch path the hardest one to check.
    @Test("resetting puts the Mac back to never-onboarded")
    func resetRestoresFirstRun() throws {
        let ledger = try makeLedger()
        ledger.markComplete()
        ledger.reset()
        #expect(ledger.completedVersion == 0)
        #expect(ledger.shouldPresent)
    }
}

/// What a permission page *says*, which is the half that behaviour tests do not reach.
///
/// Every assertion here exists because the first version got one of them wrong on screen: the music
/// page on a Mac where the mediaremote adapter is live told the user to "Choose OK when macOS asks
/// whether Isleta can control your music app", under a Continue that would never raise a dialog.
/// The button was right — Continue advanced, because there was nothing to ask — and the sentence
/// was a lie. A state that produces correct behaviour and incorrect copy is still a missing state.
///
/// Asserts against the source language: under `swift test` every lookup falls back to the English
/// `defaultValue`. `LocalizationCoverageTests` is what guards the other three.
@Suite("Onboarding permission copy")
struct OnboardingPermissionCopyTests {

    /// The bug, pinned. `.notNeeded` must never produce the sentence that tells somebody which
    /// button to press in a dialog that is not coming.
    @Test("a permission with nothing to ask never prints the instruction")
    func notNeededDoesNotInstruct() {
        for permission in OnboardingPermission.allCases {
            #expect(permission.notNeeded() != permission.instruction)
            #expect(!permission.notNeeded().contains("when macOS asks"))
        }
    }

    /// The other half of the same bug, and the one that was nearly missed: the *headline* also
    /// claims a permission is needed. Fixing the caption alone would have left "Isleta needs your
    /// permission to show the music you're already playing" over "Nothing to allow".
    @Test("the two permissions that can have nothing to ask drop the needs-permission headline")
    func notNeededDropsTheAsk() {
        for permission in [OnboardingPermission.automation, .bluetooth] {
            #expect(permission.headline(for: .notNeeded) != permission.headline)
            #expect(!permission.headline(for: .notNeeded).contains("needs your permission"))
        }
    }

    /// **`.notNeeded` is unreachable for these three**, so they deliberately have no copy of their
    /// own and fall back — EventKit, CoreLocation and the Accessibility API each require a grant on
    /// every Mac that has the feature at all. Asserted rather than left as a comment, so that the
    /// day one of them gains a permission-free route the fallback is a failing test rather than a
    /// page quietly saying "Allowed" about something nobody allowed.
    @Test("the three that always require a grant fall back rather than inventing copy")
    func alwaysRequiredFallBack() {
        for permission in [OnboardingPermission.calendar, .location, .accessibility] {
            #expect(permission.headline(for: .notNeeded) == permission.headline)
            #expect(permission.notNeeded() == permission.granted)
        }
    }

    /// Every state says something different, because each is a different situation the user is in.
    /// Two states sharing a sentence is how the instruction ended up under `.notNeeded` — the copy
    /// was picked by a `switch` with one case too few, and nothing said so.
    @Test("every state has its own sentence")
    func statesDoNotShareCopy() {
        for permission in OnboardingPermission.allCases {
            let sentences = [
                permission.instruction,
                permission.granted,
                permission.denied,
                permission.notNeeded()
            ]
            // `.notNeeded` is the deliberate exception for the three above, where it *is* `granted`.
            let expected = [OnboardingPermission.automation, .bluetooth].contains(permission) ? 4 : 3
            #expect(Set(sentences).count == expected, "\(permission.rawValue) reuses a sentence")
        }
    }

    /// A headline names what the user gets, never the framework or the pane. §10's rule, and the
    /// difference between a sentence about a checkbox and a sentence about their Mac.
    @Test("no page names the API it is about")
    func headlinesNameThePayoff() {
        let jargon = ["EventKit", "CoreLocation", "TCC", "AppleScript", "Apple Events", "entitlement"]
        for permission in OnboardingPermission.allCases {
            for word in jargon {
                #expect(!permission.headline.contains(word))
                #expect(!permission.instruction.contains(word))
            }
        }
    }
}
