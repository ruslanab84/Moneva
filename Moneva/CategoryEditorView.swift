import SwiftUI
import SwiftData

/// New or existing category. Everything on screen feeds the preview at the top,
/// so what is saved is what was seen.
struct CategoryEditorView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query private var all: [SpendingCategory]

    private let existing: SpendingCategory?
    private let onSave: ((SpendingCategory) -> Void)?

    @State private var name: String
    @State private var symbol: String
    @State private var paletteIndex: Int
    @State private var hasLimit: Bool
    @State private var limit: Decimal
    @State private var scope: Scope

    init(scope: Scope = .personal, onSave: ((SpendingCategory) -> Void)? = nil) {
        existing = nil
        self.onSave = onSave
        _name = State(initialValue: "")
        _symbol = State(initialValue: CategoryLibrary.symbols.first ?? "circle")
        _paletteIndex = State(initialValue: 0)
        _hasLimit = State(initialValue: false)
        _limit = State(initialValue: 0)
        _scope = State(initialValue: scope)
    }

    init(editing category: SpendingCategory) {
        existing = category
        onSave = nil
        _name = State(initialValue: category.name)
        _symbol = State(initialValue: category.symbol)
        _paletteIndex = State(initialValue: CategoryLibrary.palette.firstIndex { $0.tint == category.tintHex } ?? 0)
        _hasLimit = State(initialValue: category.monthlyLimit != nil)
        _limit = State(initialValue: category.monthlyLimit ?? 0)
        _scope = State(initialValue: category.scope)
    }

    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var colors: (tint: String, soft: String) { CategoryLibrary.palette[paletteIndex] }

    private var nameIsFree: Bool {
        CategoryLibrary.isNameAvailable(trimmedName, scope: scope, in: all, excluding: existing)
    }

    private var canSave: Bool { !trimmedName.isEmpty && nameIsFree && (!hasLimit || limit > 0) }

    var body: some View {
        NavigationStack {
            Form {
                Section { preview.listRowBackground(Color.clear) }

                Section("Name") {
                    TextField("Category name", text: $name)
                    if !trimmedName.isEmpty && !nameIsFree {
                        Label("A \(scope.title.lowercased()) category is already called that.", systemImage: "exclamationmark.triangle")
                            .font(.footnote)
                            .foregroundStyle(Palette.over)
                    }
                }

                Section("Icon") { iconPicker }
                Section("Colour") { colorPicker }

                Section("Monthly limit") {
                    Toggle("Set a limit", isOn: $hasLimit)
                    if hasLimit {
                        AmountField(title: "Limit", value: $limit)
                        if limit <= 0 {
                            Text("A limit has to be more than zero.")
                                .font(.footnote)
                                .foregroundStyle(Palette.over)
                        }
                    }
                }

                Section("Scope") { ScopePicker(scope: $scope) }
            }
            .navigationTitle(existing == nil ? "New category" : "Edit category")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }.disabled(!canSave)
                }
            }
        }
    }

    private var preview: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 20))
                .foregroundStyle(Color(hex: colors.tint))
                .frame(width: 46, height: 46)
                .background(Color(hex: colors.soft), in: .rect(cornerRadius: 15))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(trimmedName.isEmpty ? "Category name" : trimmedName)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(trimmedName.isEmpty ? Palette.inkMuted : Palette.ink)
                Text(hasLimit && limit > 0 ? "\(limit.money()) a month · \(scope.title)" : scope.title)
                    .font(.footnote)
                    .foregroundStyle(Palette.inkMuted)
            }
            Spacer()
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Preview: \(trimmedName.isEmpty ? "unnamed category" : trimmedName)")
    }

    private var iconPicker: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(CategoryLibrary.symbolGroups, id: \.name) { group in
                VStack(alignment: .leading, spacing: 8) {
                    Eyebrow(group.name)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 52), spacing: 8)], spacing: 8) {
                        ForEach(group.symbols, id: \.self) { candidate in
                            Button { symbol = candidate } label: {
                                Image(systemName: candidate)
                                    .font(.system(size: 18))
                                    .foregroundStyle(symbol == candidate ? Palette.card : Palette.ink)
                                    .frame(width: 46, height: 46)
                                    .background(symbol == candidate ? Palette.accent : Palette.ground, in: .rect(cornerRadius: 14))
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(candidate.replacingOccurrences(of: ".", with: " "))
                            .accessibilityAddTraits(symbol == candidate ? [.isSelected] : [])
                        }
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }

    private var colorPicker: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 52), spacing: 8)], spacing: 8) {
            ForEach(CategoryLibrary.palette.indices, id: \.self) { index in
                Button { paletteIndex = index } label: {
                    Circle()
                        .fill(Color(hex: CategoryLibrary.palette[index].tint))
                        .frame(width: 36, height: 36)
                        .overlay {
                            Circle().strokeBorder(Palette.ink.opacity(paletteIndex == index ? 0.9 : 0), lineWidth: 2)
                                .padding(-4)
                        }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Colour \(index + 1)")
                .accessibilityAddTraits(paletteIndex == index ? [.isSelected] : [])
            }
        }
        .padding(.vertical, 6)
    }

    private func save() {
        let monthlyLimit: Decimal? = hasLimit && limit > 0 ? limit : nil
        if let existing {
            existing.name = trimmedName
            existing.symbol = symbol
            existing.tintHex = colors.tint
            existing.softHex = colors.soft
            existing.monthlyLimit = monthlyLimit
            existing.scope = scope
        } else {
            let created = SpendingCategory(
                name: trimmedName,
                symbol: symbol,
                tintHex: colors.tint,
                softHex: colors.soft,
                monthlyLimit: monthlyLimit,
                scope: scope,
                sortIndex: CategoryLibrary.nextSortIndex(in: all, scope: scope)
            )
            context.insert(created)
            try? context.save()
            onSave?(created)
        }
        dismiss()
    }
}
