import XCTest
@testable import Off_the_Record

/// The action-item step: the model's task lines are checked against the transcript before they
/// replace the list in the notes.
final class ActionItemTests: XCTestCase {
    private let meetingDate = Date(timeIntervalSince1970: 1_793_000_000)   // a fixed day
    private let turns = [
        NotesPipeline.Turn(start: 0, end: 10, speaker: "You", text: "I'll send the deck tomorrow."),
        NotesPipeline.Turn(start: 60, end: 70, speaker: "Priya", text: "Someone should review the budget."),
    ]

    func testCountsEveryListStyleInTheSection() {
        let notes = """
        ## Summary
        - A point that is not a task

        ## Action items
        - [ ] Send the deck — You
        *   [ ] Book the room
        1. Review the budget
        not a list line

        ## Next meeting
        - Thursday
        """
        XCTAssertEqual(NotesPipeline.actionItemCount(in: notes), 3)
        XCTAssertEqual(NotesPipeline.actionItemCount(in: "## Summary\n- nothing to do"), 0)
    }

    func testChecksTimesOwnersAndDuplicates() {
        let answer = """
        Here are the tasks:
        {"task": "Send the deck", "owner": "You", "when": "tomorrow", "time": "00:05"}
        {"task": "Invented task", "owner": "You", "when": "", "time": "05:00"}
        {"task": "Review the budget", "owner": "Bob", "when": "", "time": "01:02"}
        {"task": "send the deck", "owner": "You", "when": "", "time": "00:06"}
        not json at all
        """
        let items = NotesPipeline.checkedItems(answer, turns: turns, speakers: ["You", "Priya"], meetingDate: meetingDate)
        XCTAssertEqual(items.map(\.task), ["Send the deck", "Review the budget"])   // 05:00 is on no line; duplicate dropped
        XCTAssertEqual(items[0].owner, "You")
        XCTAssertEqual(items[1].owner, "")                                          // Bob was not in the meeting
        XCTAssertEqual(items[0].when, NotesPipeline.resolve("tomorrow", from: meetingDate))
        XCTAssertEqual(items[0].time, 5)
    }

    func testSpokenDaysBecomeDates() {
        XCTAssertEqual(NotesPipeline.resolve("kal", from: meetingDate), NotesPipeline.resolve("tomorrow", from: meetingDate))
        XCTAssertEqual(NotesPipeline.resolve("aaj", from: meetingDate), NotesPipeline.resolve("today", from: meetingDate))
        XCTAssertNotEqual(NotesPipeline.resolve("tomorrow", from: meetingDate), "tomorrow")
        XCTAssertTrue(NotesPipeline.resolve("next week", from: meetingDate).hasPrefix("by "))
        XCTAssertEqual(NotesPipeline.resolve(" 15 March ", from: meetingDate), "15 March")
    }

    func testCheckedItemsReplaceTheSection() {
        let notes = "## Summary\nShort.\n\n## Action items\n- [ ] Old task\n\n## Next meeting\n- Thursday"
        let items = [NotesPipeline.ActionItem(task: "Send the deck", owner: "You", when: "Fri 13 Nov", time: 5),
                     NotesPipeline.ActionItem(task: "Review the budget", owner: "", when: "", time: 62)]
        let out = NotesPipeline.replaceActionItems(in: notes, with: items)
        XCTAssertTrue(out.contains("- [ ] Send the deck — You — Fri 13 Nov [00:05]"))
        XCTAssertTrue(out.contains("- [ ] Review the budget [01:02]"))
        XCTAssertFalse(out.contains("Old task"))
        XCTAssertTrue(out.hasSuffix("## Next meeting\n- Thursday"))
    }

    func testNotesKeepTheirListWhenTheCheckFindsFewer() {
        let notes = "## Action items\n- [ ] One\n- [ ] Two\n- [ ] Three"
        let items = [NotesPipeline.ActionItem(task: "One", owner: "", when: "", time: 0)]
        XCTAssertEqual(NotesPipeline.replaceActionItems(in: notes, with: items), notes)
        XCTAssertEqual(NotesPipeline.replaceActionItems(in: notes, with: []), notes)
    }

    func testSectionIsAddedWhenTheNotesHaveNone() {
        let items = [NotesPipeline.ActionItem(task: "Send the deck", owner: "", when: "", time: 5)]
        XCTAssertEqual(NotesPipeline.replaceActionItems(in: "## Summary\nShort.", with: items),
                       "## Summary\nShort.\n\n## Action items\n- [ ] Send the deck [00:05]")
    }
}
