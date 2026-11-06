import XCTest
import GRDB
@testable import Off_the_Record

final class SecurityTests: XCTestCase {
    func testOnlyWebLinksCanOpen() {
        XCTAssertTrue(ExternalLink.isWeb(URL(string: "https://example.com/deck")!))
        XCTAssertTrue(ExternalLink.isWeb(URL(string: "http://example.com")!))
        XCTAssertFalse(ExternalLink.isWeb(URL(string: "file:///etc/passwd")!))
        XCTAssertFalse(ExternalLink.isWeb(URL(string: "x-apple.systempreferences:com.apple.preference.security")!))
        XCTAssertFalse(ExternalLink.isWeb(URL(string: "zoommtg://join?confno=1")!))
        XCTAssertFalse(ExternalLink.isWeb(URL(string: "https:")!))
    }

    func testLocalServerAddresses() {
        for local in ["http://127.0.0.1:11434", "http://localhost:11434", "http://[::1]:11434"] {
            XCTAssertTrue(OllamaClient.isLocal(URL(string: local)!), local)
        }
        for remote in ["http://0.0.0.0:11434", "http://192.168.1.5:11434", "https://ollama.example.com"] {
            XCTAssertFalse(OllamaClient.isLocal(URL(string: remote)!), remote)
        }
    }

    /// After processing, a meeting keeps the terms read off the screen but not the screen text.
    func testScreenTextIsReducedToTerms() throws {
        let db = try DatabaseQueue()
        try db.write { db in
            try db.create(table: "screenText") { t in
                t.primaryKey("id", .text)
                t.column("meetingId", .text).notNull()
                t.column("capturedAt", .datetime).notNull()
                t.column("text", .text).notNull()
            }
            for (i, text) in ["Deploy TimescaleDB on Kubernetes\npassword swordfish", "TimescaleDB rollout with PgBouncer"].enumerated() {
                try ScreenText(id: "\(i)", meetingId: "m1", capturedAt: Date(), text: text).insert(db)
            }
        }
        let before = try db.read { try Vocabulary.screenTerms(ScreenText.fetchAll($0)) }
        XCTAssertTrue(before.contains("TimescaleDB"))

        try db.write { try Vocabulary.keepOnlyScreenTerms($0, meetingId: "m1") }
        let rows = try db.read { try ScreenText.fetchAll($0) }
        XCTAssertEqual(rows.count, 1)
        XCTAssertFalse(rows[0].text.contains("swordfish"))
        XCTAssertEqual(Vocabulary.screenTerms(rows), before)

        // Running it again changes nothing.
        try db.write { try Vocabulary.keepOnlyScreenTerms($0) }
        XCTAssertEqual(try db.read { try ScreenText.fetchAll($0) }.map(\.text), rows.map(\.text))
    }
}
