import XCTest
@testable import Off_the_Record

/// What the app learns from hand edits: word fixes from notes edits, mishearings from transcript
/// corrections, and the glossary. Each test uses its own throwaway settings, never the user's.
final class WordFixLearningTests: XCTestCase {
    private let suiteName = "io.stackera.offtherecord.tests"

    override func setUp() {
        super.setUp()
        let suite = UserDefaults(suiteName: suiteName)!
        suite.removePersistentDomain(forName: suiteName)
        Vocabulary.defaults = suite
    }

    override func tearDown() {
        Vocabulary.defaults.removePersistentDomain(forName: suiteName)
        Vocabulary.defaults = .standard
        super.tearDown()
    }

    // MARK: Notes edits

    func testSmallSwapIsLearnedAsFixAndTerm() {
        let lesson = Vocabulary.learnFromNotesEdit(old: "We will move the queue to cash flow next week",
                                                   new: "We will move the queue to Kafka next week")
        XCTAssertEqual(lesson.fixes, [.init(heard: "cash flow", wanted: "Kafka")])
        XCTAssertEqual(lesson.terms, ["Kafka"])
        XCTAssertEqual(Vocabulary.notesFixes.map(\.heard), ["cash flow"])
        XCTAssertEqual(Vocabulary.notesFixes.map(\.wanted), ["Kafka"])
        XCTAssertEqual(Vocabulary.manual, ["Kafka"])
        XCTAssertTrue(Vocabulary.notesFixesBlock().contains("\"cash flow\" → \"Kafka\""))
    }

    func testSameEditTwiceLearnsNothingNew() {
        Vocabulary.learnFromNotesEdit(old: "Deploy on cash flow", new: "Deploy on Kafka")
        let again = Vocabulary.learnFromNotesEdit(old: "Deploy on cash flow", new: "Deploy on Kafka")
        XCTAssertTrue(again.isEmpty)
        XCTAssertEqual(Vocabulary.notesFixes.count, 1)
        XCTAssertEqual(Vocabulary.manual, ["Kafka"])
    }

    func testRewrittenSentenceIsNotAFix() {
        let lesson = Vocabulary.learnFromNotesEdit(old: "Ship it Friday",
                                                   new: "Hold the release until the security review is finished")
        XCTAssertTrue(lesson.fixes.isEmpty)
        XCTAssertTrue(Vocabulary.notesFixes.isEmpty)
    }

    func testEverydayWordSwapIsIgnored() {
        let lesson = Vocabulary.learnFromNotesEdit(old: "Send a draft", new: "Send the draft")
        XCTAssertTrue(lesson.isEmpty)
        XCTAssertTrue(Vocabulary.notesFixes.isEmpty)
        XCTAssertTrue(Vocabulary.manual.isEmpty)
    }

    func testUndoForgetsWhatTheEditTaught() {
        let lesson = Vocabulary.learnFromNotesEdit(old: "Move it to cash flow", new: "Move it to Kafka")
        XCTAssertFalse(lesson.isEmpty)
        Vocabulary.forget(lesson)
        XCTAssertTrue(Vocabulary.notesFixes.isEmpty)
        XCTAssertTrue(Vocabulary.manual.isEmpty)
    }

    // MARK: Transcript corrections

    func testTranscriptCorrectionIsLearnedAndApplied() {
        Vocabulary.learnCorrections(from: "check the dix screener dashboard", to: "check the DexScreener dashboard")
        XCTAssertEqual(Vocabulary.corrections.map(\.heard), ["dix screener"])
        XCTAssertEqual(Vocabulary.corrections.map(\.wanted), ["DexScreener"])

        XCTAssertEqual(Vocabulary.applyCorrections("Open DIX  screener now"), "Open DexScreener now")
        // Whole words only.
        XCTAssertEqual(Vocabulary.applyCorrections("two dix screeners"), "two dix screeners")
    }

    func testOrdinaryRewordingIsNotACorrection() {
        Vocabulary.learnCorrections(from: "we can do it later", to: "we can do it tomorrow")
        XCTAssertTrue(Vocabulary.corrections.isEmpty)
    }

    // MARK: Glossary

    func testGlossaryParsingKeepsOrderAndDropsDuplicates() {
        XCTAssertEqual(Vocabulary.parse("Solana, TimescaleDB\n\nsolana\n RPC "), ["Solana", "TimescaleDB", "RPC"])
    }

    func testLearnAddsOnlyNewTerms() {
        Vocabulary.learn(["Solana", "RPC"])
        Vocabulary.learn(["rpc", "Postgres"])
        XCTAssertEqual(Vocabulary.manual, ["Solana", "RPC", "Postgres"])
    }

    func testScreenReadingIsOffUntilTurnedOn() {
        XCTAssertFalse(Vocabulary.readScreenEnabled)
        Vocabulary.defaults.set(true, forKey: Vocabulary.screenKey)
        XCTAssertTrue(Vocabulary.readScreenEnabled)
    }
}
