import SwiftUI
import SwiftData

/// Tapping the Category field opens this. Grid of icons, search, and a way in
/// to a brand new category that comes back selected.
struct CategoryPickerView: View {
    @Environment(\.dismiss) private var dismiss
    @Query private var all: [SpendingCategory]

    @Binding var selection: SpendingCategory?
    let scope: Scope
    var kind: TransactionKind = .expense
    var suggestedName = ""
    var suggestedSymbol = "cart"

    @State private var query = ""
    @State private var isCreating = false
    @State private var isManaging = false

    private let columns = [GridItem(.adaptive(minimum: 96), spacing: 12)]

    private var visible: [SpendingCategory] {
        CategoryLibrary.search(CategoryLibrary.visible(all, scope: scope, kind: kind), for: query)
    }

    private var personal: [SpendingCategory] { visible.filter { $0.scope == .personal } }
    private var shared: [SpendingCategory] { visible.filter { $0.scope == .shared } }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    newCategoryButton

                    if visible.isEmpty {
                        EmptyHint(
                            title: "No category matches",
                            message: query.isEmpty ? "Add one to get started." : "Try another word, or make a new category.",
                            symbol: "magnifyingglass"
                        )
                    }

                    section("Personal", personal)
                    section("Shared", shared)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
            }
            .background(Palette.ground)
            .searchable(text: $query, placement: .navigationBarDrawer, prompt: "Search categories")
            .navigationTitle(kind == .income ? "Income category" : "Category")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .primaryAction) { Button("Manage") { isManaging = true } }
            }
            .sheet(isPresented: $isCreating) {
                // A category made here is the one the user wanted to pick.
                CategoryEditorView(scope: scope, kind: kind, suggestedName: suggestedName.isEmpty ? query : suggestedName, suggestedSymbol: suggestedSymbol) { created in
                    selection = created
                    dismiss()
                }
            }
            .sheet(isPresented: $isManaging) { CategoryManagerView(kind: kind) }
        }
    }

    private var newCategoryButton: some View {
        Button { isCreating = true } label: {
            HStack(spacing: 12) {
                Image(systemName: "plus")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Palette.card)
                    .frame(width: 44, height: 44)
                    .background(Palette.accent, in: .rect(cornerRadius: 14))
                VStack(alignment: .leading, spacing: 2) {
                    Text("New category").font(.subheadline.weight(.semibold)).foregroundStyle(Palette.ink)
                    Text(kind == .income ? "Pick an icon and a colour" : "Pick an icon, a colour and a limit").font(.footnote).foregroundStyle(Palette.inkMuted)
                }
                Spacer()
            }
            .monevaCard(padding: 14)
        }
    }

    @ViewBuilder
    private func section(_ title: String, _ categories: [SpendingCategory]) -> some View {
        if !categories.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                // The heading only earns its space once both scopes are on screen.
                if scope == .shared { Eyebrow(title) }
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(categories, id: \.persistentModelID) { category in
                        cell(category)
                    }
                }
            }
        }
    }

    private func cell(_ category: SpendingCategory) -> some View {
        let isSelected = selection?.persistentModelID == category.persistentModelID
        return Button {
            selection = category
            dismiss()
        } label: {
            VStack(spacing: 8) {
                CategoryBadge(category: category, size: 46)
                Text(category.name)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(Palette.ink)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(Palette.card, in: .rect(cornerRadius: 20))
            .overlay {
                RoundedRectangle(cornerRadius: 20)
                    .strokeBorder(isSelected ? Palette.accent : .clear, lineWidth: 2)
            }
        }
        .accessibilityLabel(category.name)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}

/// Optional second choice under a category. Shows nothing when the category
/// has no subcategories, and drops a stale pick when the category changes.
struct SubcategoryPicker: View {
    let category: SpendingCategory?
    @Binding var selection: Subcategory?

    var body: some View {
        let options = CategoryLibrary.subcategories(of: category)
        if !options.isEmpty {
            Picker("Subcategory", selection: $selection) {
                Text("None").tag(Subcategory?.none)
                ForEach(options, id: \.persistentModelID) { Text($0.name).tag(Subcategory?.some($0)) }
            }
            .onChange(of: category?.persistentModelID) { _, _ in
                if !CategoryLibrary.isSelectable(selection, under: category) { selection = nil }
            }
        }
    }
}
