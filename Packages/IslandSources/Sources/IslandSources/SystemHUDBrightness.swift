import Foundation

/// The explanations shown when a level HUD has no hardware to read, and the record of how both
/// brightness claims in this file turned out to be wrong.
///
/// **Everything this type used to assert has been withdrawn, in two steps on 2026-08-22.** It once
/// held the readings and the reasoning for display brightness *and* keyboard brightness, and
/// declared both unavailable on Apple Silicon. Both are available. What is left here is the pair of
/// sentences a user reads when their particular Mac cannot produce one of these HUDs — a desktop
/// with no backlit keyboard, or an OS that has moved the symbols — plus the two post-mortems,
/// because the ways these went wrong are more reusable than the answers.
///
/// # Display brightness: right measurement, wrong conclusion
///
/// The file said there was no route *and no change notification anywhere*. The API it tried,
/// `IODisplayGetFloatParameter`, genuinely does answer `kIOReturnUnsupported` — it needs an
/// `IODisplayConnect` service and Apple Silicon publishes none. That much was true and remains
/// true. The error was treating one API's refusal as the platform's answer.
/// `DisplayServicesGetBrightness` reads it, and the matching register-for-changes call pushes.
/// See `DisplayBrightnessMonitor`.
///
/// The measurement that produced the claim was also **invalid on its own terms**, which is the part
/// worth keeping: it drove the panel with synthesized brightness media keys, and those move the
/// value by exactly zero on Apple Silicon. The stimulus never fired, so every reading was of a
/// value nothing had asked to move.
///
/// # Keyboard brightness: a true measurement of the wrong subsystem
///
/// This one is subtler and the more instructive of the two. The claim was that the backlight is
/// "a privileged device that only Apple's own software may query", and the evidence was real: the
/// backlight's IORegistry node **is** marked `Privileged`, `IOHIDDeviceOpen` **does** succeed, and
/// `IOHIDDeviceGetReport(kIOHIDReportTypeFeature, …)` **does** return `kIOReturnUnsupported`
/// without an entitlement Apple keeps. Every one of those facts is still true today.
///
/// They were just not facts about the level. The keyboard backlight is reached through
/// `CoreBrightness`, which answers an ordinary unentitled process and pushes change notifications.
/// So a careful, correct, reproducible measurement of HID produced a confident conclusion about a
/// value that does not live in HID. **Establishing that one door is locked says nothing about how
/// many doors there are**, and the wording that leaked into the user-facing string ("only Apple's
/// own software may query") turned an observation about a subsystem into a claim about the platform.
///
/// The keyboard HUD itself was removed in the same change that cut the settings back — see
/// `SystemHUD` for why a route working is not the same as a feature being wanted. The paragraph
/// above stays because it is a lesson about measurement, not about the backlight.
public enum SystemHUDBrightness {

    /// A level, or the reason there isn't one. The reason is shown to the user, so it says what is
    /// missing rather than which function failed.
    public enum Reading: Equatable, Sendable {
        case level(Double)
        case unavailable(explanation: String)

        public var level: Double? {
            if case .level(let value) = self { return value }
            return nil
        }
    }

    /// Shown when `DisplayBrightnessMonitor` could not resolve or could not answer.
    ///
    /// Says nothing about Apple Silicon any more. The previous wording named the hardware as the
    /// reason, which was both wrong and unfalsifiable to the person reading it.
    public static let displayUnavailableExplanation = sourceText("hud.unavailable.brightness", """
        Display brightness can't be read on this Mac, so Isleta leaves the brightness HUD to the \
        system.
        """)

}
