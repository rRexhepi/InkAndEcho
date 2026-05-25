import SwiftUI
import SwiftData

struct MigrationGate<Content: View>: View {
    @Environment(\.modelContext) private var modelContext
    @ViewBuilder let content: () -> Content

    var body: some View {
        content()
            .task {
                guard MigrationImporter.hasPendingMigration else { return }
                do {
                    let count = try await MigrationImporter.importIfNeeded(context: modelContext)
                    if count > 0 {
                        debugPrint("Migrated \(count) books from Palimpsest")
                    }
                } catch {
                    debugPrint("Palimpsest migration failed: \(error)")
                }
            }
    }
}
