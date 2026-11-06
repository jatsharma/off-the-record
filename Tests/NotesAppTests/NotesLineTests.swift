import XCTest
@testable import Off_the_Record

/// How one line of the notes' Markdown is split into kind, marker and content for in-place editing.
final class NotesLineTests: XCTestCase {
    func testHeading() {
        let line = NotesLine("## Decisions")
        XCTAssertEqual(line.kind, .heading(2))
        XCTAssertEqual(line.prefix, "## ")
        XCTAssertEqual(line.content, "Decisions")
        XCTAssertEqual(line.level, 0)
    }

    func testOpenAndDoneTasks() {
        let open = NotesLine("  - [ ] Send the deck — Priya")
        XCTAssertEqual(open.kind, .task(done: false))
        XCTAssertEqual(open.prefix, "  - [ ] ")
        XCTAssertEqual(open.content, "Send the deck — Priya")
        XCTAssertEqual(open.level, 1)
        XCTAssertTrue(open.isTask)

        XCTAssertEqual(NotesLine("- [x] Book the room").kind, .task(done: true))
        XCTAssertEqual(NotesLine("* [X] Book the room").kind, .task(done: true))
    }

    func testBulletsAndNumbers() {
        let bullet = NotesLine("* Budget approved")
        XCTAssertEqual(bullet.kind, .bullet)
        XCTAssertEqual(bullet.prefix, "* ")
        XCTAssertFalse(bullet.isTask)

        let numbered = NotesLine("3. Ship the beta")
        XCTAssertEqual(numbered.kind, .numbered(3))
        XCTAssertEqual(numbered.prefix, "3. ")
        XCTAssertEqual(numbered.content, "Ship the beta")
    }

    func testIndentationLevels() {
        XCTAssertEqual(NotesLine("\t- nested").level, 2)        // a tab counts as four spaces
        XCTAssertEqual(NotesLine("      - deep").level, 3)
        XCTAssertEqual(NotesLine("            - deeper").level, 3)  // capped
    }

    func testBlankAndParagraph() {
        XCTAssertEqual(NotesLine("").kind, .blank)
        XCTAssertEqual(NotesLine("   ").kind, .blank)

        let text = NotesLine("The team agreed to move the launch.")
        XCTAssertEqual(text.kind, .paragraph)
        XCTAssertEqual(text.prefix, "")
        XCTAssertEqual(text.content, "The team agreed to move the launch.")

        XCTAssertEqual(NotesLine("#hashtag without a space").kind, .paragraph)
    }

    /// Editing replaces only the content, so marker plus content must give back the line as written.
    func testPrefixAndContentRebuildTheLine() {
        let lines = ["## Action items", "  - [ ]   Call the vendor", "1) First", "• Point", "    indented text", "-   spaced bullet"]
        for raw in lines {
            let line = NotesLine(raw)
            XCTAssertEqual(line.prefix + line.content, raw, raw)
        }
    }
}
