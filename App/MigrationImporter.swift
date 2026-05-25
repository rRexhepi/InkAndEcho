import Foundation
import SwiftData
import InkAndEchoCore

@MainActor
enum MigrationImporter {
    static let appGroupID = "group.com.rexhep.InkAndEcho"
    private static let didMigrateKey = "inkandecho.didMigratePalimpsest"

    static var alreadyImported: Bool {
        UserDefaults.standard.bool(forKey: didMigrateKey)
    }

    static var hasPendingMigration: Bool {
        guard !alreadyImported else { return false }
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupID
        ) else { return false }
        return FileManager.default.fileExists(
            atPath: container.appendingPathComponent("migration.json").path
        )
    }

    static func importIfNeeded(context: ModelContext) async throws -> Int {
        guard hasPendingMigration else { return 0 }
        guard let groupContainer = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupID
        ) else { return 0 }

        let manifestURL = groupContainer.appendingPathComponent("migration.json")
        let data = try Data(contentsOf: manifestURL)
        guard let manifest = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let books = manifest["books"] as? [[String: Any]] else {
            return 0
        }

        let appSupport = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let localBooksRoot = appSupport
            .appendingPathComponent("InkAndEcho", isDirectory: true)
            .appendingPathComponent("Books", isDirectory: true)
        try FileManager.default.createDirectory(at: localBooksRoot, withIntermediateDirectories: true)

        let groupBooksDir = groupContainer.appendingPathComponent("Books", isDirectory: true)
        let iso = ISO8601DateFormatter()
        var imported = 0

        for entry in books {
            guard let idStr = entry["id"] as? String,
                  let bookUUID = UUID(uuidString: idStr),
                  let title = entry["title"] as? String,
                  let author = entry["author"] as? String else { continue }

            let existing = try context.fetch(
                FetchDescriptor<Book>(predicate: #Predicate { $0.id == bookUUID })
            )
            if !existing.isEmpty { continue }

            let srcDir = groupBooksDir.appendingPathComponent(idStr, isDirectory: true)
            let destDir = localBooksRoot.appendingPathComponent(idStr, isDirectory: true)
            try FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)

            var coverData: Data?
            if let b64 = entry["coverImageBase64"] as? String {
                coverData = Data(base64Encoded: b64)
            }

            var ebookURL: URL?
            if let filename = entry["ebookFilename"] as? String {
                let src = srcDir.appendingPathComponent(filename)
                let dst = destDir.appendingPathComponent(filename)
                if FileManager.default.fileExists(atPath: src.path) {
                    try? FileManager.default.copyItem(at: src, to: dst)
                    ebookURL = dst
                }
            }

            var audioURL: URL?
            if let filename = entry["audiobookFilename"] as? String {
                let src = srcDir.appendingPathComponent(filename)
                let dst = destDir.appendingPathComponent(filename)
                if FileManager.default.fileExists(atPath: src.path) {
                    try? FileManager.default.copyItem(at: src, to: dst)
                    audioURL = dst
                }
            }

            var alignmentURL: URL?
            if entry["hasAlignment"] as? Bool == true {
                let src = srcDir.appendingPathComponent("alignment.json")
                let dst = destDir.appendingPathComponent("alignment.json")
                if FileManager.default.fileExists(atPath: src.path) {
                    try? FileManager.default.copyItem(at: src, to: dst)
                    alignmentURL = dst
                }
            }

            let addedAt = (entry["addedAt"] as? String).flatMap { iso.date(from: $0) } ?? Date()
            let duration = entry["totalDurationSeconds"] as? Double ?? 0
            let pages = entry["totalPages"] as? Int ?? 0

            let book = Book(
                id: bookUUID,
                title: title,
                author: author,
                coverImageData: coverData,
                ebookFileURL: ebookURL,
                audiobookFileURL: audioURL,
                alignmentMapURL: alignmentURL,
                totalDurationSeconds: duration,
                totalPages: pages,
                addedAt: addedAt
            )
            context.insert(book)

            if let annots = entry["annotations"] as? [[String: Any]] {
                for a in annots {
                    let annotation = Annotation(
                        id: (a["id"] as? String).flatMap(UUID.init) ?? UUID(),
                        book: book,
                        cfiStart: a["cfiStart"] as? String ?? "",
                        cfiEnd: a["cfiEnd"] as? String ?? "",
                        kind: AnnotationKind(rawValue: a["kindRaw"] as? String ?? "") ?? .highlight,
                        color: AnnotationColor(rawValue: a["colorRaw"] as? String ?? "") ?? .amber,
                        note: a["note"] as? String ?? "",
                        createdAt: (a["createdAt"] as? String).flatMap { iso.date(from: $0) } ?? Date()
                    )
                    context.insert(annotation)
                }
            }

            if let p = entry["progress"] as? [String: Any] {
                let progress = ReadingProgress(
                    book: book,
                    currentCFI: p["currentCFI"] as? String ?? "",
                    currentAudioSeconds: p["currentAudioSeconds"] as? Double ?? 0,
                    currentPageIndex: p["currentPageIndex"] as? Int ?? 0,
                    lastReadAt: (p["lastReadAt"] as? String).flatMap { iso.date(from: $0) } ?? Date()
                )
                context.insert(progress)
            }

            imported += 1
        }

        if imported > 0 {
            try context.save()
        }

        UserDefaults.standard.set(true, forKey: didMigrateKey)
        return imported
    }
}
