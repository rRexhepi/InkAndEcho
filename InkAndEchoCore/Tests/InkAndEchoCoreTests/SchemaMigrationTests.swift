import Testing
import Foundation
import SwiftData
@testable import InkAndEchoCore

/// Proves the V1→V2 lightweight migration actually carries user data: a
/// store written with the as-shipped V1 schema reopens through
/// `InkAndEchoMigrationPlan` with books, annotations, progress, and the
/// new V2 default intact. This is the test that keeps "model change"
/// from meaning "crash loop" for installed copies.
@Suite("Schema migration")
struct SchemaMigrationTests {
    @Test func v1StoreMigratesToV2WithDataIntact() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("inkandecho-migration-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let storeURL = dir.appendingPathComponent("test.store")

        // Write a store with the frozen V1 schema (what build 11 shipped).
        do {
            let v1 = Schema(versionedSchema: InkAndEchoSchemaV1.self)
            let container = try ModelContainer(
                for: v1,
                configurations: [ModelConfiguration(schema: v1, url: storeURL)]
            )
            let context = ModelContext(container)
            let book = InkAndEchoSchemaV1.Book(title: "Migrate Me", author: "Tester")
            context.insert(book)
            let progress = InkAndEchoSchemaV1.ReadingProgress(
                book: book, currentCFI: "c1", currentPageIndex: 7
            )
            context.insert(progress)
            book.progress = progress
            let note = InkAndEchoSchemaV1.Annotation(
                book: book, cfiStart: "c1#p2", cfiEnd: "c1#p2",
                kindRaw: "note", colorRaw: "amber", note: "survives"
            )
            context.insert(note)
            book.annotations.append(note)
            try context.save()
        }

        // Reopen with V2 through the migration plan — the exact code path
        // `InkAndEchoApp.makeContainer()` runs on first launch after update.
        let v2 = Schema(versionedSchema: InkAndEchoSchemaV2.self)
        let container = try ModelContainer(
            for: v2,
            migrationPlan: InkAndEchoMigrationPlan.self,
            configurations: [ModelConfiguration(schema: v2, url: storeURL)]
        )
        let context = ModelContext(container)
        let books = try context.fetch(FetchDescriptor<Book>())

        #expect(books.count == 1)
        let book = try #require(books.first)
        #expect(book.title == "Migrate Me")
        #expect(book.progress?.currentPageIndex == 7)
        #expect(book.progress?.firstWordIndex == -1)   // V2 addition defaulted
        #expect(book.annotations.count == 1)
        #expect(book.annotations.first?.note == "survives")
    }
}
