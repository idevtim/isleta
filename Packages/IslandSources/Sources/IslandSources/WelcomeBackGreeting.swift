import Foundation
import IslandActivities

/// Which greeting the hour of the day calls for.
///
/// The bands are the same ones the system's own assistant uses, and they are computed in the user's
/// `Calendar` — which carries their time zone — rather than from a `TimeInterval`. That is the whole
/// of the locale correctness here: "morning" is a fact about where the user is sitting, and reading
/// the hour out of a UTC timestamp greets somebody in Auckland with "Good evening" over breakfast.
public enum TimeOfDay: String, CaseIterable, Sendable {
    case morning
    case afternoon
    case evening
    case night

    /// 05:00–11:59 morning, 12:00–16:59 afternoon, 17:00–21:59 evening, 22:00–04:59 night.
    public init(hour: Int) {
        switch hour {
        case 5..<12: self = .morning
        case 12..<17: self = .afternoon
        case 17..<22: self = .evening
        default: self = .night
        }
    }

    /// The band `date` falls in, in `calendar`'s time zone.
    public init(_ date: Date, calendar: Calendar) {
        self.init(hour: calendar.component(.hour, from: date))
    }

    /// What the island says.
    ///
    /// `sourceText` with a symbolic key and the English beside it, which is the convention the whole
    /// app now uses: the key survives an edit to the English, and a language Isleta does not yet
    /// speak falls back to the second argument. It is here rather than at the point of use so the
    /// four strings the product actually says live in one switch — the failure this avoids is the
    /// ordinary one where a second source needs a greeting, writes its own, and the app now says
    /// "Good evening" in one place and "Evening!" in another.
    ///
    /// Nothing here is interpolated. A greeting built by concatenating a translated fragment with a
    /// name or a time reads as machine output in any language whose word order is not English's, and
    /// the fix is not to be cleverer about the concatenation but not to concatenate.
    ///
    /// The keys carry the hour band, which is what a translator has to know and what the `comment:`
    /// argument used to say: none of these four survives a word-for-word translation. German has no
    /// "good afternoon" anybody says, and the night line is a return rather than a farewell in every
    /// language it is written in.
    public var greeting: String {
        switch self {
        case .morning:
            sourceText("welcomeBack.greeting.morning", "Good morning")
        case .afternoon:
            sourceText("welcomeBack.greeting.afternoon", "Good afternoon")
        case .evening:
            sourceText("welcomeBack.greeting.evening", "Good evening")
        case .night:
            sourceText("welcomeBack.greeting.night", "Welcome back")
        }
    }

    /// The line underneath, one of which is picked at random each time the island greets.
    ///
    /// ## Why these are banded and not one pool
    ///
    /// A greeting that has already committed to an hour cannot then say something that belongs to a
    /// different one. "Make it a good one" is warm at seven in the morning and faintly absurd at
    /// half past eleven at night, and a single pool would say it there roughly a quarter of the
    /// time. Banding costs four short arrays and removes the whole class of mistake — every line
    /// below is only ever read by somebody for whom it is true.
    ///
    /// The night band is the one to be careful with, for the same reason its greeting is: a person
    /// at their desk at two in the morning is not being congratulated, and nothing here should read
    /// as a farewell or as advice they did not ask for.
    ///
    /// ## Why they are `sourceText` and not a resource
    ///
    /// Same convention as `greeting` — a symbolic key with the English beside it, so the app says
    /// these in English wherever a language has no table and a translation lands without an edit at
    /// a call site. The **key** is what a translator gets instead of the island, so each one carries
    /// the band it is read in: these lines are where Isleta has a voice, and a line that is warm in
    /// English at seven in the morning has to be re-written rather than translated in a language
    /// whose idiom for that hour is a different sentence.
    public var messages: [String] {
        switch self {
        case .morning:
            [
                sourceText("welcomeBack.message.morning.1", "Today is yours."),
                sourceText("welcomeBack.message.morning.2", "Make it a good one."),
                sourceText("welcomeBack.message.morning.3", "One thing at a time."),
                sourceText("welcomeBack.message.morning.4", "A fresh start, right on time."),
                sourceText("welcomeBack.message.morning.5", "You've got this."),
            ]
        case .afternoon:
            [
                sourceText("welcomeBack.message.afternoon.1", "Still plenty of day left."),
                sourceText("welcomeBack.message.afternoon.2", "Back at it. Nice."),
                sourceText("welcomeBack.message.afternoon.3", "You're further along than it feels."),
                sourceText("welcomeBack.message.afternoon.4", "Keep going."),
                sourceText("welcomeBack.message.afternoon.5", "Ready when you are."),
            ]
        case .evening:
            [
                sourceText("welcomeBack.message.evening.1", "You did enough today."),
                sourceText("welcomeBack.message.evening.2", "Good work today."),
                sourceText("welcomeBack.message.evening.3", "The rest can wait."),
                sourceText("welcomeBack.message.evening.4", "Finish gently."),
                sourceText("welcomeBack.message.evening.5", "Nice to see you again."),
            ]
        case .night:
            [
                sourceText("welcomeBack.message.night.1", "Still here. That counts for something."),
                sourceText("welcomeBack.message.night.2", "Be kind to yourself tonight."),
                sourceText("welcomeBack.message.night.3", "Whatever it is, it can probably wait."),
                sourceText("welcomeBack.message.night.4", "Quiet hours suit you."),
                sourceText("welcomeBack.message.night.5", "Take your time."),
            ]
        }
    }
}

/// The copy for one wake/unlock moment: what the island says and what it says underneath.
///
/// A value rather than a function so the two halves are produced together and tested together, and
/// so `SystemEventsSource` has nothing to decide. This is a wake/unlock moment and never a lock
/// screen feature: `loginwindow` is a separate secure context, Isleta draws nothing there, and the
/// island the user sees here is the ordinary one on their own desktop after they are already in.
///
/// ## What the second line used to be
///
/// The date, formatted field-by-field so ICU could order and punctuate it per locale. It was
/// correct, and it was the wrong thing to say: somebody who has been away for ninety seconds knows
/// what day it is, and the island had spent its one short line telling them. The line now carries
/// something they might actually want to read, banded by the hour so it is never at odds with the
/// greeting above it.
///
/// The locale work that formatted the date is gone with it, and so is the `locale` parameter that
/// existed only to feed it. That is the loss worth naming: it was the careful half of this type.
/// What replaces it is careful about a different thing — `TimeOfDay.messages` is four pools rather
/// than one precisely so a translated line still lands in the right hour.
public struct WelcomeBackGreeting: Equatable, Sendable {

    /// The greeting itself. Shown in the compact and expanded presentations.
    public let title: String

    /// The line underneath. Only the expanded presentation has room for it.
    ///
    /// Optional because `ActivityContent.subtitle` is, not because this is ever nil in practice —
    /// every band's pool is non-empty and a test asserts it stays that way.
    public let subtitle: String?

    /// Build the copy for a return happening at `date`.
    ///
    /// `calendar` is a parameter with the user's own as the default, so a test can pin it and
    /// assert what somebody in Tokyo or Auckland is greeted with. Reading `Calendar.current` inside
    /// the body instead would make the interesting half of this type untestable, and the
    /// interesting half is precisely the half that is wrong for everyone who does not live in the
    /// author's time zone.
    ///
    /// `generator` is injected for the same reason and no other: a random subtitle that could only
    /// be produced by `SystemRandomNumberGenerator` is a subtitle no test can name, and "the island
    /// never says a morning line at midnight" is exactly the kind of claim that has to be checked
    /// rather than hoped for. Production calls the convenience below and never sees this.
    public init<G: RandomNumberGenerator>(
        at date: Date,
        calendar: Calendar = .current,
        using generator: inout G
    ) {
        let band = TimeOfDay(date, calendar: calendar)

        self.title = band.greeting

        // Uniform, and deliberately with no memory of the last one. The alternative — tracking what
        // was said and excluding it — needs this type to hold state across greetings, and a type
        // that holds state across greetings is a type that can be wrong about which greeting it is
        // in. An occasional repeat between two wakes hours apart is the cheaper of the two costs.
        self.subtitle = band.messages.randomElement(using: &generator)
    }

    /// The one production callers use.
    public init(at date: Date, calendar: Calendar = .current) {
        var generator = SystemRandomNumberGenerator()
        self.init(at: date, calendar: calendar, using: &generator)
    }

    /// The activity to hand to the coordinator.
    ///
    /// `BuiltInActivity.welcomeBack` carries `ActivityKind.welcomeBack`'s own priority and its four
    /// second expiry, so nothing here schedules a dismissal — §9's no-polling rule is kept by not
    /// having a clock in this package at all beyond the one that measures the absence.
    public var activity: BuiltInActivity {
        .welcomeBack(greeting: title, subtitle: subtitle)
    }
}
