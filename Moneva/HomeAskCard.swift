import SwiftUI
import SwiftData

/// Home-screen entry point for free-text financial questions.
/// Reuses the existing tool-calling layer (`FinancialToolRegistry.answer`) —
/// Swift computes every number, the model only picks tools and phrases the result.
struct HomeAskCard: View {
    let scope: Scope
    @AppStorage(Money.storageKey) private var currencyCode = Money.code
    @Environment(\.modelContext) private var modelContext
    @State private var question = ""
    @State private var answer: String?
    @State private var error: String?
    @State private var busy = false
    @State private var task: Task<Void, Never>?
    @FocusState private var focused: Bool

    private static let examples: [String.LocalizationValue] = [
        "How much did I spend on food last month?",
        "Will my money last until the end of the month?",
        "Which category costs me the most?",
        "What do my subscriptions cost next month?"
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "sparkles").foregroundStyle(Palette.accent)
                Eyebrow("Ask about your money")
            }

            TextField("How much did I spend on food last month?", text: $question, axis: .vertical)
                .font(.subheadline)
                .foregroundStyle(Palette.ink)
                .lineLimit(1...3)
                .padding(12)
                .background(Palette.accentSoft, in: .rect(cornerRadius: 14))
                .submitLabel(.go)
                .focused($focused)
                .onSubmit(ask)

            if question.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(Array(Self.examples.enumerated()), id: \.offset) { _, example in
                            let text = String(localized: example)
                            Button {
                                question = text
                                ask()
                            } label: {
                                Text(text)
                                    .font(.caption)
                                    .lineLimit(1)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 7)
                                    .background(Palette.line.opacity(0.6), in: .capsule)
                                    .foregroundStyle(Palette.inkMuted)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }

            if busy {
                ProgressView("Reading your records…").font(.footnote)
            } else if let answer {
                TypewriterText(text: answer)
                    .font(.subheadline)
                    .foregroundStyle(Palette.ink)
            }

            if let error {
                Text(error).font(.footnote).foregroundStyle(Palette.over)
            } else if let reason = TransactionDrafter.unavailableReason {
                Text(reason).font(.caption).foregroundStyle(Palette.inkMuted)
            } else {
                Button("Ask", systemImage: "arrow.up.circle.fill") { ask() }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Palette.accent)
                    .disabled(busy || question.isEmpty)
            }
        }
        .monevaCard()
        .onDisappear { task?.cancel() }
    }

    private func ask() {
        focused = false
        let asked = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !asked.isEmpty, !busy else { return }
        task?.cancel()
        busy = true
        error = nil
        answer = nil
        task = Task {
            defer { busy = false }
            do {
                let service = FinancialToolService(context: modelContext, scope: scope, currency: currencyCode)
                answer = try await FinancialToolRegistry.answer(question: asked, service: service)
            } catch is CancellationError {} catch { self.error = error.localizedDescription }
        }
    }
}
