import IslandActivities
import SwiftUI

/// The questions a coding agent is asking, drawn on the open island one at a time with their
/// options as buttons (`ActivityContent.questions`).
///
/// A question that takes one answer is answered by pressing it, and the next question follows. A
/// question that takes several toggles its options and is sent with the button under them. The
/// choices go out together after the last question, as one `CodingAgentAnswer.choices`, because
/// the agent takes them in one reply. There is no way back to an earlier question. The terminal's
/// picker is still on screen for a person who wants to change one, or to type an answer the island
/// does not offer.
///
/// **The view keeps the step and the selection, and nothing else does.** They are the person's
/// progress through one prompt and mean nothing once it is sent. `ActivityContentView` gives this
/// view the questions as its identity, so a new prompt starts at the first question.
///
/// **The island is sized for the tallest question** (`ActivityExpandedHeight.questionsHeight`), and
/// this view is laid out from the top of that room. A shorter question leaves the space under its
/// options empty rather than moving the block above it between steps.
struct ActivityQuestionsView: View {

    let questions: [ActivityQuestion]
    let increaseContrast: Bool
    let reduceMotion: Bool
    /// Nil draws the questions inert, as a preview. The height is the same either way.
    let onAnswer: ((CodingAgentAnswer) -> Void)?

    @State private var step = 0
    @State private var answered: [[String]] = []
    @State private var selection: Set<String> = []

    private var question: ActivityQuestion {
        questions[min(step, questions.count - 1)]
    }

    private var isLast: Bool { step >= questions.count - 1 }

    private var secondaryOpacity: Double {
        ActivityPalette.secondaryOpacity(increaseContrast: increaseContrast)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if ActivityExpandedHeight.questionsHaveCaption(questions) {
                Text(caption)
                    .font(.system(size: ActivityExpandedHeight.captionStyle.size, weight: .regular))
                    .foregroundStyle(.white.opacity(secondaryOpacity))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .padding(.bottom, ActivityExpandedHeight.captionQuestionSpacing)
            }
            Text(question.text)
                .font(.system(size: ActivityExpandedHeight.questionStyle.size, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(ActivityExpandedHeight.questionLineLimit)
                .truncationMode(.tail)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, ActivityExpandedHeight.questionOptionsSpacing)
            VStack(spacing: ActivityExpandedHeight.optionSpacing) {
                ForEach(question.options, id: \.self) { option in
                    optionButton(option)
                }
                if question.allowsMultiple {
                    IslandAnswerButton(
                        title: isLast
                            ? islandText("codingAgent.question.submit", "Submit")
                            : islandText("codingAgent.question.next", "Next"),
                        prominent: true, increaseContrast: increaseContrast
                    ) {
                        advance(with: question.options.filter(selection.contains))
                    }
                    .disabled(selection.isEmpty || onAnswer == nil)
                    .opacity(selection.isEmpty ? 0.45 : 1)
                }
            }
        }
        // The step is part of the identity, so the whole question crossfades as one piece. The
        // container stays put, which makes this a content swap and not a morph (§6.2).
        .id(step)
        .transition(.opacity)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// The header, if the asker named the question, and how far along the person is, if there is
    /// more than one question.
    private var caption: String {
        var parts: [String] = []
        if let header = question.header, !header.isEmpty { parts.append(header) }
        if questions.count > 1 {
            let position = step + 1
            let count = questions.count
            parts.append(islandText("codingAgent.question.progress", "\(position) of \(count)"))
        }
        return parts.joined(separator: " · ")
    }

    private func optionButton(_ option: String) -> some View {
        let multiple = question.allowsMultiple
        let selected = multiple && selection.contains(option)
        return IslandAnswerButton(
            title: option, prominent: selected, increaseContrast: increaseContrast,
            symbol: multiple ? (selected ? "checkmark.circle.fill" : "circle") : nil
        ) {
            guard multiple else {
                advance(with: [option])
                return
            }
            if selected {
                selection.remove(option)
            } else {
                selection.insert(option)
            }
        }
        .disabled(onAnswer == nil)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func advance(with choice: [String]) {
        guard let onAnswer, !choice.isEmpty else { return }
        let all = answered + [choice]
        if all.count >= questions.count {
            onAnswer(.choices(all))
            return
        }
        answered = all
        withAnimation(Motion.contentSwap) {
            selection = []
            step = all.count
        }
    }
}

/// One answer button on the open island: Allow, Deny, or an option to a question. A SwiftUI
/// `Button`, so a press reaches SwiftUI rather than the island's own click handler. That is the
/// same mechanism the glance's Join button documents.
///
/// Prominent is the brighter fill: the answer being asked for, or an option that is chosen.
struct IslandAnswerButton: View {

    let title: String
    let prominent: Bool
    let increaseContrast: Bool
    var symbol: String?
    let action: () -> Void

    init(
        title: String, prominent: Bool, increaseContrast: Bool, symbol: String? = nil,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.prominent = prominent
        self.increaseContrast = increaseContrast
        self.symbol = symbol
        self.action = action
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: ActivityExpandedHeight.answerRowHeight / 2, style: .continuous)
        let fill: Double = prominent
            ? (increaseContrast ? 0.42 : 0.26)
            : (increaseContrast ? 0.24 : 0.12)
        Button(action: action) {
            HStack(spacing: 6) {
                if let symbol {
                    Image(systemName: symbol)
                        .font(.system(size: 12, weight: .semibold))
                        .accessibilityHidden(true)
                }
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity)
            .frame(height: ActivityExpandedHeight.answerRowHeight)
            .contentShape(shape)
            .background(shape.fill(.white.opacity(fill)))
        }
        .buttonStyle(GlanceButtonStyle())
        .accessibilityLabel(title)
    }
}
