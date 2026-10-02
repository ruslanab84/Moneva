import SwiftUI
import SwiftData

/// Reorder, edit, archive and restore. Nothing here deletes — an archived
/// category keeps every transaction it ever held.
struct CategoryManagerView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query private var all: [SpendingCategory]

    /// Manage one side of the ledger at a time — whichever picker opened this.
    var kind: TransactionKind = .expense

    @State private var editing: SpendingCategory?

    private var listed: [SpendingCategory] { all.filter { $0.kind == kind } }

    private var active: [SpendingCategory] {
        listed.filter { !$0.isArchived }.sorted {
            $0.sortIndex != $1.sortIndex ? $0.sortIndex < $1.sortIndex
                : $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    private var archived: [SpendingCategory] {
        listed.filter(\.isArchived).sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    var body: some View {
        NavigationStack {
            List {
                Section("Active") {
                    ForEach(active, id: \.persistentModelID) { category in
                        Button { editing = category } label: { row(category) }
                            .swipeActions {
                                Button("Archive", systemImage: "archivebox") { archive(category) }.tint(Palette.warning)
                            }
                    }
                    .onMove(perform: move)

                    if active.isEmpty {
                        Text("Every category is archived.").font(.footnote).foregroundStyle(Palette.inkMuted)
                    }
                }

                if !archived.isEmpty {
                    Section("Archived") {
                        ForEach(archived, id: \.persistentModelID) { category in
                            row(category)
                                .swipeActions {
                                    Button("Restore", systemImage: "arrow.uturn.backward") { restore(category) }.tint(Palette.accent)
                                }
                        }
                    }
                }
            }
            .environment(\.editMode, .constant(.active))
            .navigationTitle(kind == .income ? "Income categories" : "Categories")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .sheet(item: $editing) { CategoryEditorView(editing: $0) }
        }
    }

    private func row(_ category: SpendingCategory) -> some View {
        HStack(spacing: 12) {
            CategoryBadge(category: category, size: 34)
            VStack(alignment: .leading, spacing: 1) {
                Text(category.name).font(.subheadline).foregroundStyle(Palette.ink)
                Text(subtitle(for: category)).font(.caption).foregroundStyle(Palette.inkMuted)
            }
            Spacer()
        }
    }

    private func subtitle(for category: SpendingCategory) -> String {
        var parts = [category.scope.title]
        if let limit = category.monthlyLimit { parts.append("\(limit.money()) a month") }
        if !category.transactions.isEmpty { parts.append("\(category.transactions.count) transactions") }
        return parts.joined(separator: " · ")
    }

    private func move(from source: IndexSet, to destination: Int) {
        var ordered = active
        ordered.move(fromOffsets: source, toOffset: destination)
        for (index, category) in ordered.enumerated() { category.sortIndex = index }
        try? context.save()
    }

    private func archive(_ category: SpendingCategory) {
        category.isArchived = true
        try? context.save()
    }

    private func restore(_ category: SpendingCategory) {
        category.isArchived = false
        category.sortIndex = CategoryLibrary.nextSortIndex(in: all, scope: category.scope, kind: category.kind)
        try? context.save()
    }
}
