import SwiftUI
import SwiftData

struct StatementExportView: View {
    @AppStorage("scope") private var scopeRaw = Scope.personal.rawValue
    @Query private var transactions: [Transaction]
    @State private var exportURL: URL?
    @State private var error: String?

    private var scope: Scope { Scope(rawValue: scopeRaw) ?? .personal }
    private var scoped: [Transaction] { transactions.filter { $0.scope == scope } }

    var body: some View {
        List {
            Section {
                LabeledContent("Scope", value: scope.title)
                LabeledContent("Transactions", value: "\(scoped.count)")
            }
            Section {
                Button {
                    prepare()
                } label: {
                    Label("Prepare CSV", systemImage: "square.and.arrow.up")
                }
                .disabled(scoped.isEmpty)
                if let exportURL {
                    ShareLink(item: exportURL) {
                        Label("Share CSV", systemImage: "doc.text")
                    }
                }
            } footer: {
                if let error {
                    Text(error).foregroundStyle(.red)
                } else {
                    Text("Exports every \(scope.title.lowercased())-scope transaction. Currencies and categories are kept as recorded.")
                }
            }
        }
        .navigationTitle("Export statement")
    }

    private func prepare() {
        do {
            exportURL = try TransactionExport.write(scoped)
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}
