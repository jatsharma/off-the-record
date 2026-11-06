import Foundation
import GRDB

/// One SQLite file under ~/Library/Application Support/Off the Record, WAL mode.
final class AppDatabase {
    static let shared = AppDatabase()

    static let supportDirectory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Off the Record", isDirectory: true)
    }()
    static let audioDirectory = supportDirectory.appendingPathComponent("Audio", isDirectory: true)

    let pool: DatabasePool

    private init() {
        do {
            try FileManager.default.createDirectory(at: Self.audioDirectory, withIntermediateDirectories: true)
            var config = Configuration()
            config.foreignKeysEnabled = true
            let path = Self.supportDirectory.appendingPathComponent("notes.sqlite").path
            pool = try DatabasePool(path: path, configuration: config)
            try Self.migrator.migrate(pool)
        } catch {
            fatalError("Database setup failed: \(error)")
        }
    }

    private static var migrator: DatabaseMigrator {
        var m = DatabaseMigrator()
        m.registerMigration("v1") { db in
            try db.create(table: "meeting") { t in
                t.primaryKey("id", .text)
                t.column("title", .text).notNull()
                t.column("createdAt", .datetime).notNull()
                t.column("durationSeconds", .double).notNull().defaults(to: 0)
                t.column("audioPath", .text)
                t.column("summary", .text)
                t.column("status", .text).notNull()
                t.column("errorMessage", .text)
            }
            try db.create(table: "segment") { t in
                t.primaryKey("id", .text)
                t.belongsTo("meeting", onDelete: .cascade).notNull()
                t.column("startTime", .double).notNull()
                t.column("endTime", .double).notNull()
                t.column("speaker", .text)
                t.column("text", .text).notNull()
            }
        }
        m.registerMigration("v2-voices") { db in
            try db.create(table: "voiceprint") { t in
                t.primaryKey("id", .text)
                t.column("name", .text).notNull().unique()
                t.column("vector", .blob).notNull()
                t.column("samples", .integer).notNull().defaults(to: 1)
                t.column("updatedAt", .datetime).notNull()
            }
            try db.create(table: "meetingSpeaker") { t in
                t.primaryKey("id", .text)
                t.belongsTo("meeting", onDelete: .cascade).notNull()
                t.column("speaker", .text).notNull()
                t.column("vector", .blob).notNull()
                t.uniqueKey(["meetingId", "speaker"])
            }
        }
        m.registerMigration("v3-vocabulary") { db in
            try db.alter(table: "segment") { t in
                t.add(column: "rawText", .text)
                t.add(column: "altText", .text)
            }
            try db.create(table: "screenText") { t in
                t.primaryKey("id", .text)
                t.belongsTo("meeting", onDelete: .cascade).notNull()
                t.column("capturedAt", .datetime).notNull()
                t.column("text", .text).notNull()
            }
        }
        m.registerMigration("v4-notes-edited") { db in
            try db.alter(table: "meeting") { t in
                t.add(column: "notesEdited", .boolean).notNull().defaults(to: false)
            }
        }
        m.registerMigration("v5-typed-notes") { db in
            try db.alter(table: "meeting") { t in t.add(column: "typedNotes", .text) }
        }
        m.registerMigration("v6-screen-terms-only") { db in
            // Meetings recorded before this keep only the terms read off the screen, not the text.
            try Vocabulary.keepOnlyScreenTerms(db)
        }
        return m
    }
}
