import AppKit

/// Trackpad haptics (§7).
///
/// The rule from §7 is "subtle or absent", and every haptic Isleta performs is a single tap the
/// moment the pointer *arrives* somewhere — feedback for something the user did, never unprompted.
/// If Isleta ever taps when the user didn't cause it, that's a bug.
///
/// There are two arrivals and they are the same tap: the pointer landing on the island (`peek()`)
/// and the pointer landing on a control *inside* it that acts on a single click (`arrival()`). The
/// second is not a second kind of feedback — it is the same "you have arrived on something"
/// alignment tap, said about something smaller. It is deliberately **not** offered for controls that
/// merely look pressable: a tap that fires over every glyph in the transport row would be a
/// vibrating island, and §7's word is subtle.
///
/// Two behaviors are inherited from AppKit rather than worked around, both correct:
///
/// - **The system suppresses feedback when the user isn't touching the trackpad.** Someone driving
///   a mouse gets the animation and no tap, which is what should happen — there is no Taptic Engine
///   under their hand. No detection needed on our side.
/// - **`defaultPerformer` can change during the app's lifetime** as input devices come and go, so
///   it's requested fresh every time rather than cached.
public enum Haptics {

    /// Whether Isleta may perform haptics at all. The user-facing switch lands with IslandSettings;
    /// until then this is the single place to turn them off.
    @MainActor public static var isEnabled = true

    /// A single crisp tap as the pointer lands on the island.
    ///
    /// `.alignment` is the pattern for "you have arrived on something" — the same tap the system
    /// uses for snapping to a guide. `.levelChange` is for stepping through discrete pressure
    /// zones and would read as the wrong gesture entirely.
    ///
    /// `.drawCompleted` rather than `.now`: the tap has to land on the same frame the peek becomes
    /// visible. Firing immediately puts the tap a frame or two ahead of the animation, and the two
    /// stop feeling like one event.
    @MainActor
    public static func peek() {
        guard isEnabled else { return }
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .drawCompleted)
    }

    /// The same tap, as the pointer lands on a control the island reveals under it.
    ///
    /// `.drawCompleted` for `peek()`'s reason and with more force here: the control this announces
    /// is one that *appears* on hover, so the tap and the glyph fading in have to be the same event.
    /// A tap ahead of the reveal reads as the island twitching at a pointer that has not arrived.
    @MainActor
    public static func arrival() {
        guard isEnabled else { return }
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .drawCompleted)
    }

}
