import Foundation
import GRDB

/// One SQLite file under ~/Library/Application Support/Notes, WAL mode, two tables.
final class AppDatabase {
    static let shared = AppDatabase()

    static let supportDirectory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Notes", isDirectory: true)
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
        return m
    }
}
