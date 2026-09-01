import SwiftUI

/// The surfaces the settings window is assembled from.
///
/// Three shapes and nothing else — a card, a row, and a slider row — so that "a setting" has one
/// appearance in this window rather than as many as there are places somebody added one. That is the
/// same argument `Motion`'s four tokens make about animation, applied to surfaces.
///
/// ## These were glass until 2026-08-28
///
/// Each card was a `glassEffect(.regular, in:)` pane floating on `SettingsBackdrop`, and the change
/// away from it is worth the paragraph because the reasoning is not "flat is in fashion".
///
/// Liquid Glass is a lens, and a lens is at its best over something moving or something the user
/// put there — a photo, a map, a video. What sat behind these cards was a low-contrast gradient
/// that exists to be ignored, so the glass had almost nothing to refract and spent its budget
/// making the *text on top of it* harder to place: every label sat on a slightly different tone
/// depending on which ripple it had landed over. Eight cards down a pane, that reads as unevenness
/// rather than as depth.
///
/// The flat surfaces are opaque mixes of the icon's own two colors (`SettingsPalette.card`), so a
/// card is the same tone wherever it lands and the window keeps its identity in the *backdrop*,
/// where there is no text to compete with. Rows are separated by hairlines that run the full width
/// of the card rather than by gaps, which is how a Mac settings pane has grouped rows since long
/// before there was a material to do it with.
///
/// ## What is *not* re-drawn here, and never should be
///
/// The **controls inside a card** are stock AppKit-backed SwiftUI controls. macOS 26's `Toggle`,
/// `Slider` and `Button` already carry the system's own treatment, drawn by the same code every
/// other app on the machine uses. Re-skinning them would produce switches that are *nearly* the
/// system's — which is precisely the "close enough" this project's brief rules out. The window's
/// job is to give them a surface worth sitting on; their job is to be the controls the user
/// already knows.
enum SettingsSurface {

    /// The card corner. Continuous, never circular — §6.4 for the island, and the same eye reads
    /// this window.
    static let cornerRadius: CGFloat = 16

    // MARK: - The window's whitespace
    //
    // Tightened on 2026-08-25, from a pane that needed scrolling to reach its third card on a window
    // the user had sized for four. Every number below came down; none of the *controls* did, and
    // that is the line this group is drawn along. A settings window is dense with text a person has
    // to read, so the space between a control and its own caption is load-bearing and the space
    // between one group and the next is not — see `SettingsRow` for why the switches are already
    // small and the sliders deliberately are not.

    /// The gap between two cards in a pane.
    ///
    /// Was 18. Fourteen still reads as two cards rather than one, because they are separately
    /// rounded and separately lit — the gap is not what separates them, the shape is.
    static let cardSpacing: CGFloat = 14

    /// The margin between a pane's cards and the window's edges.
    ///
    /// Was 22. Eighteen keeps the cards clear of the sidebar's divider and of the window's rounded
    /// corners, which is all this margin was ever for.
    static let paneInset: CGFloat = 18

    /// A card's own padding, inside its edge.
    ///
    /// Was 16. This one is the tightest of the three on purpose: it is the only margin a person
    /// reads *text* against, and text against a rounded edge wants more room than a card does.
    ///
    /// Applied to a card's **rows**, not to the card, which is what lets `SettingsDivider` run the
    /// full width while the text it separates stays inset. See that type for why the hairline is
    /// the one thing in a card that is allowed past this margin.
    static let cardPadding: CGFloat = 14

    /// The gap between two settings inside one card — a row, the divider under it, the next row.
    ///
    /// Was 14, applied uniformly, which is what made a card of six rows tall: every divider took the
    /// gap twice. Ten is the number that shortened the Sides card by about a fifth without any two
    /// rows starting to read as one.
    static let rowSpacing: CGFloat = 10

    /// The gap between a card's title and the card.
    ///
    /// Was 10, which is more than the distance from the title to the *card above it* once
    /// `cardSpacing` came down — a heading floating between two things it might belong to.
    static let titleSpacing: CGFloat = 6

    /// The air above and below the pane header's icon and name.
    ///
    /// **The number that mattered here was not this one.** The header measured 73pt from the
    /// window's top edge to its hairline while its own padding accounted for 20 of them: the window
    /// is `.fullSizeContentView`, so SwiftUI reserved the title bar's 28pt above the header and the
    /// name sat in the bottom third of a band that was mostly empty. The detail column reclaims
    /// that band — see `SettingsView.detail`, which is where the fix is — and this is then the
    /// whole of the header's height either side of a 22pt icon.
    ///
    /// Eight rather than ten, so the reclaimed band does not simply become a header that is tall on
    /// purpose instead of tall by accident.
    static let headerPadding: CGFloat = 8
}

/// One group of settings, on its own surface.
struct SettingsCard<Content: View>: View {

    /// Which side of the palette to take the card's fill from.
    ///
    /// Read here rather than passed in: a card is used in three files and none of them should have
    /// to know that the window has two appearances.
    @Environment(\.colorScheme) private var colorScheme

    /// Reduce transparency does **not** change the card any more, and the absence is the note.
    ///
    /// It used to swap the glass for an opaque fill, because glass is a thing you read through.
    /// The fill is already opaque, so there is nothing left for the setting to turn off — the only
    /// transparency left in this window is `SettingsBackdrop`, which honours it there. A branch
    /// here would be a branch that produced the same pixels either way, which is worse than none:
    /// the next reader would assume it was doing something.
    private let title: String?
    private let content: Content

    init(_ title: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: SettingsSurface.titleSpacing) {
            if let title {
                Text(title)
                    .font(.system(.subheadline, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
            }

            surface
        }
    }

    /// The card's content on its surface.
    ///
    /// Three things are load-bearing:
    ///
    /// - **The fill is opaque.** That is the entire reason this is no longer `glassEffect`: a
    ///   material resolves toward the system's neutral gray whatever is behind it, so a card on a
    ///   teal window came out gray, and eight of them made the window gray. An opaque mix of the
    ///   icon's colors cannot drift, because there is nothing behind it to sample.
    /// - **The margin stays on the card, and only the hairline is let out of it.** The alternative
    ///   — pad the rows instead of the card — reaches the same picture and needs every one of the
    ///   dozen kinds of thing that can sit in a card to remember to do it. `SettingsDivider` undoes
    ///   the margin for itself, in one place, and everything else keeps the margin it always had.
    /// - **`.clipShape` before the border.** The clip is what stops a full-width hairline drawing
    ///   past the card's rounded corner; the stroke goes on afterwards as an overlay on the same
    ///   shape, so the border stays a hairline rather than being clipped to half of one.
    private var surface: some View {
        VStack(alignment: .leading, spacing: SettingsSurface.rowSpacing) { content }
            .padding(SettingsSurface.cardPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(SettingsPalette.card(colorScheme))
            .clipShape(shape)
            .overlay(shape.strokeBorder(SettingsPalette.hairline(colorScheme), lineWidth: 1))
    }

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: SettingsSurface.cornerRadius, style: .continuous)
    }
}

/// The hairline between two rows of a card.
///
/// It exists as a type rather than as a `Divider()` at each call site for one reason: it has to
/// reach past the card's own text margin to both edges, and the negative padding that does that is
/// exactly the kind of thing that gets copied to twelve places and then corrected in eleven.
///
/// **The negative padding is safe here and is not safe in general.** This codebase has a trap about
/// a decorative rectangle overhanging its container and swallowing the clicks of the control
/// underneath — see `SettingsView.identity` for the sidebar version, which cost a session. A
/// `Divider` is one point tall, sits *between* two rows rather than over either of them, and has
/// nothing under it to swallow. If this ever grows a height, that stops being true.
struct SettingsDivider: View {

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Rectangle()
            .fill(SettingsPalette.hairline(colorScheme))
            .frame(height: 1)
            .padding(.horizontal, -SettingsSurface.cardPadding)
    }
}

/// A control with a label above it and an explanation below it.
///
/// The explanation is not optional, and that is the point of the type. Every switch in this window
/// changes something a user cannot see from its name — what a haptic is, what a source can do
/// without permission, what "delights" means — and a settings pane of bare switches is a pane the
/// user has to experiment on. Making the caption a required argument means the next control added
/// here has to say what it does before it compiles.
struct SettingsRow<Control: View>: View {

    private let caption: String
    private let control: Control

    init(caption: String, @ViewBuilder control: () -> Control) {
        self.caption = caption
        self.control = control()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // Small, and scoped here rather than set on the pane.
            //
            // A macOS switch at its regular size is drawn for a control that is the point of the
            // window it is in. In a card it is the largest, brightest thing on the glass and pulls
            // the eye away from the label that says what it does — with three of them stacked, the
            // pane reads as a row of blue lozenges with text beside them.
            //
            // Set on the whole detail pane it would also shrink the sliders, and those are the one
            // control here that wants its full size: a slider is dragged rather than clicked, and a
            // small one has a smaller target and less room for its ticks. `SettingsSlider` does not
            // route through this type, which is what keeps the two sizes apart without a flag.
            control
                .controlSize(.small)
            Text(caption)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A continuous setting, as macOS 26 draws one.
///
/// Everything characteristic of the new slider is here and none of it is decoration:
///
/// - **`neutralValue`** draws the fill from the default outward rather than from the left edge, so
///   "I have moved this" and "I have moved this a lot" are visible at a glance, and the shipped
///   default is a place the thumb can be returned to rather than a number to remember.
/// - **Ticks** are the honest way to say a range is not continuous in the ways that matter. A peek
///   scale of 1.03 is not a setting anybody wants; 1x, 1.5x, 2x are.
/// - **`currentValueLabel`** puts the value where the thumb is instead of in a column beside it,
///   which is what lets these rows share the cards' left margin with the switches.
///
/// The value is rendered by a caller-supplied formatter rather than by `%.2f`, because these four
/// sliders mean four different things — milliseconds, a multiple, a percentage — and a slider whose
/// label reads "0.35" for an opacity is a slider the user has to translate.
struct SettingsSlider: View {

    let title: String
    let caption: String
    let value: Binding<Double>
    let range: ClosedRange<Double>

    /// Where the shipped default sits. The slider fills outward from here.
    let neutral: Double

    /// The stops worth landing on exactly. Empty for a genuinely continuous setting.
    var ticks: [Double] = []

    /// Turns the raw value into what the user reads. See the type note on why this is injected.
    let format: (Double) -> String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            slider
            Text(caption)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var slider: some View {
        if ticks.isEmpty {
            Slider(value: value, in: range, neutralValue: neutral) {
                Text(title)
            } currentValueLabel: {
                Text(format(value.wrappedValue)).monospacedDigit()
            }
        } else {
            Slider(value: value, in: range, neutralValue: neutral) {
                Text(title)
            } currentValueLabel: {
                Text(format(value.wrappedValue)).monospacedDigit()
            } ticks: {
                // `SliderTickContentForEach`, not `ForEach`: the `ticks:` builder is
                // `SliderTickBuilder`, which composes `SliderTickContent` rather than `View`, and
                // SwiftUI's ordinary `ForEach` does not conform to it.
                //
                // Labeled with the same formatter as the value, so the tick a user is dragging
                // toward is spelled the way the readout will spell it when they arrive.
                SliderTickContentForEach(ticks, id: \.self) { tick in
                    SliderTick(format(tick), tick)
                }
            }
        }
    }
}

/// How the continuous settings read out loud.
///
/// Pure, and deliberately not on `SettingsView`. A `View` is `@MainActor`, so a formatter declared
/// there is main-actor isolated too — which is invisible until a test calls one from a synchronous
/// nonisolated context and the build fails on strict concurrency. Nothing here touches a view, so
/// nothing here needs an actor.
///
/// Separate functions rather than one `%.2f`, because the four sliders mean four different things.
/// A slider whose readout says "0.35" for an opacity is a slider the user has to translate, and one
/// that says "0 ms" for no delay at all is answering a question nobody asked.
enum SettingsFormat {

    /// Milliseconds, because that is the unit the value is small in. "0.15 s" asks the reader to
    /// count zeroes; "150 ms" does not.
    static func delay(_ seconds: Double) -> String {
        seconds <= 0
            ? settingsText("island.hover.delay.none", "None")
            : "\(Int((seconds * 1000).rounded())) ms"
    }

    /// One decimal place, and no trailing ".0" on the whole numbers the ticks sit on — the default
    /// should read "1×", not "1.0×".
    ///
    /// `formatted(.number)` rather than `String(format: "%.1f×")`, and that is a bug fix rather than
    /// a preference: `String(format:)` takes no locale and always emits a full stop, so a German or
    /// French reader saw "1.5×" for a number their whole system spells "1,5". The `×` is a symbol
    /// and is not translated.
    static func multiple(_ scale: Double) -> String {
        let rounded = (scale * 10).rounded() / 10
        let places = rounded == rounded.rounded() ? 0 : 1
        return "\(rounded.formatted(.number.precision(.fractionLength(places))))×"
    }

    /// Points, signed, with a word at zero.
    ///
    /// "+0 pt" is the readout this must not have: zero means *the size Isleta measured*, which is a
    /// statement about the hardware rather than an adjustment of nought, and a signed zero reads as
    /// a setting that has been fiddled with and put back.
    static func points(_ points: Double) -> String {
        let whole = Int(points.rounded())
        // Not "no adjustment" and not "Default": the word has to say that this is *the size Isleta
        // measured on this Mac*, which is a statement about the hardware rather than a setting
        // sitting at nought. Each language's entry is chosen for that meaning, not for brevity.
        if whole == 0 { return settingsText("appearance.size.measured", "Measured") }
        return "\(whole > 0 ? "+" : "")\(whole) pt"
    }

    /// `formatted(.percent)` rather than a hand-built "%", so the space French and German put before
    /// the sign is the system's rather than ours.
    static func percentage(_ fraction: Double) -> String {
        fraction.formatted(.percent.precision(.fractionLength(0)))
    }

    /// How long the user has to have been away. Seconds under a minute, minutes above it, and words
    /// at zero.
    ///
    /// "0 min" is the readout this must not have. The value means *greet every return, however
    /// brief*, and a zero with a unit after it reads as the feature being switched off — which is
    /// the exact opposite, and is what the source's own toggle is for.
    ///
    /// Minutes are floored to whole ones above 60s rather than shown as "7.5 min", because the
    /// number is a judgement about what counts as leaving the desk and half-minutes are precision
    /// nobody has an opinion about.
    static func absence(_ seconds: Double) -> String {
        if seconds <= 0 { return settingsText("island.activities.absence.any", "Any return") }
        // `s` and `min` are left in place for the reason `ms` and `pt` are: they are the SI symbols
        // rather than English words, and de and fr write them identically. zh-Hans would idiomatically
        // read 秒 / 分钟; that is recorded in the README rather than fixed by translating a symbol.
        if seconds < 60 { return "\(Int(seconds.rounded())) s" }
        return "\(Int((seconds / 60).rounded())) min"
    }
}
