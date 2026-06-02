import ChatKit
import SwiftUI

// MARK: - ChoiceCardView (macOS)
//
// Renders a `kind == "choice"` IM message as a compact 红包-style interactive
// card. Tapping a pending card opens ChoicePollSheet (a vote-like selection);
// an answered card renders dimmed with the result summary and isn't tappable.

struct ChoiceCardView: View {
    let card: ChoiceCard
    let conversationId: String

    @Environment(AppViewModel.self) private var vm
    @State private var showPoll = false

    private var accent: Color { AppColors.sendButton }   // WeChat green
    private var icon: String { card.isExitPlanMode ? "checklist" : "questionmark.bubble.fill" }
    private var title: String { card.isExitPlanMode ? "Claude 提交了一个计划" : "Claude 需要你选择" }

    var body: some View {
        Group {
            if card.isAnswered {
                resolvedCard
            } else {
                pendingCard
                    .onTapGesture { showPoll = true }
            }
        }
        .frame(maxWidth: 320, alignment: .leading)
        .sheet(isPresented: $showPoll) {
            ChoicePollSheet(card: card, conversationId: conversationId)
                .environment(vm)
        }
    }

    private var pendingCard: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 22))
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .background(accent, in: RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(AppColors.titleText)
                Text("点击查看")
                    .font(.system(size: 11))
                    .foregroundStyle(accent)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.system(size: 11))
                .foregroundStyle(AppColors.secondaryText)
        }
        .padding(12)
        .background(AppColors.cardBackground, in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(accent.opacity(0.4), lineWidth: 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: 12))
    }

    private var resolvedCard: some View {
        HStack(spacing: 12) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 20))
                .foregroundStyle(AppColors.secondaryText)
                .frame(width: 40, height: 40)
                .background(AppColors.cardIconBackground, in: RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(AppColors.secondaryText)
                Text(card.answer ?? "已处理")
                    .font(.system(size: 12))
                    .foregroundStyle(AppColors.tertiaryText)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(AppColors.cardBackground.opacity(0.6), in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(AppColors.cardDivider, lineWidth: 1)
        )
        .opacity(0.85)
    }
}

// MARK: - ChoicePollSheet (macOS)

struct ChoicePollSheet: View {
    let card: ChoiceCard
    let conversationId: String

    @Environment(AppViewModel.self) private var vm
    @Environment(\.dismiss) private var dismiss

    /// Per-question selected labels (keyed by question text).
    @State private var selections: [String: Set<String>] = [:]
    @State private var submitting = false

    private var accent: Color { AppColors.sendButton }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if card.isExitPlanMode {
                        planBody
                    } else {
                        questionsBody
                    }
                }
                .padding(20)
            }
            Divider()
            footer
        }
        .frame(width: 460, height: 520)
        .background(AppColors.background)
    }

    private var header: some View {
        HStack {
            Text(card.isExitPlanMode ? "审阅计划" : "请选择")
                .font(.system(size: 15, weight: .semibold))
            Spacer()
            Button { dismiss() } label: {
                Image(systemName: "xmark.circle.fill").foregroundStyle(AppColors.secondaryText)
            }.buttonStyle(.plain)
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .background(AppColors.sidebar)
    }

    // MARK: ExitPlanMode

    private var planBody: some View {
        Text(card.plan ?? "")
            .font(.system(size: 13))
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: AskUserQuestion

    @ViewBuilder private var questionsBody: some View {
        ForEach(Array((card.questions ?? []).enumerated()), id: \.offset) { _, q in
            VStack(alignment: .leading, spacing: 10) {
                if let header = q.header, !header.isEmpty {
                    Text(header)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(accent)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(accent.opacity(0.12), in: Capsule())
                }
                Text(q.question)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(AppColors.titleText)
                ForEach(Array(q.options.enumerated()), id: \.offset) { _, opt in
                    optionRow(question: q, option: opt)
                }
            }
        }
    }

    private func optionRow(question: ChoiceQuestion, option: ChoiceOption) -> some View {
        let selected = selections[question.question]?.contains(option.label) ?? false
        let multi = question.allowsMultiple
        return Button {
            toggle(question: question, label: option.label)
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: multi
                      ? (selected ? "checkmark.square.fill" : "square")
                      : (selected ? "largecircle.fill.circle" : "circle"))
                    .font(.system(size: 16))
                    .foregroundStyle(selected ? accent : AppColors.secondaryText)
                VStack(alignment: .leading, spacing: 2) {
                    Text(option.label)
                        .font(.system(size: 13))
                        .foregroundStyle(AppColors.titleText)
                    if let d = option.description, !d.isEmpty {
                        Text(d)
                            .font(.system(size: 11))
                            .foregroundStyle(AppColors.secondaryText)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(10)
            .background(selected ? accent.opacity(0.08) : AppColors.cardBackground,
                        in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8)
                .strokeBorder(selected ? accent.opacity(0.5) : AppColors.cardDivider, lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }

    private func toggle(question: ChoiceQuestion, label: String) {
        var set = selections[question.question] ?? []
        if question.allowsMultiple {
            if set.contains(label) { set.remove(label) } else { set.insert(label) }
        } else {
            set = [label]
        }
        selections[question.question] = set
    }

    // MARK: Footer

    @ViewBuilder private var footer: some View {
        if card.isExitPlanMode {
            HStack(spacing: 12) {
                Button { submit(approve: false) } label: {
                    Text("拒绝").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                Button { submit(approve: true) } label: {
                    Text("同意").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(accent)
            }
            .disabled(submitting)
            .padding(.horizontal, 16).padding(.vertical, 12)
        } else {
            Button { submitAnswers() } label: {
                Text(submitting ? "提交中…" : "提交").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(accent)
            .disabled(submitting || !allAnswered)
            .padding(.horizontal, 16).padding(.vertical, 12)
        }
    }

    private var allAnswered: Bool {
        guard let qs = card.questions else { return false }
        return qs.allSatisfy { !(selections[$0.question]?.isEmpty ?? true) }
    }

    private func submitAnswers() {
        var answers: [String: [String]] = [:]
        for q in card.questions ?? [] {
            answers[q.question] = Array(selections[q.question] ?? [])
        }
        submitting = true
        Task {
            await vm.respondChoice(conversationId: conversationId, requestId: card.requestId,
                                   answers: answers, approve: nil)
            dismiss()
        }
    }

    private func submit(approve: Bool) {
        submitting = true
        Task {
            await vm.respondChoice(conversationId: conversationId, requestId: card.requestId,
                                   answers: nil, approve: approve)
            dismiss()
        }
    }
}
