import XCTest
@testable import Off_the_Record

/// The rule that restarts a crawling download on a new connection.
final class SlowDownloadTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)
    private let mb: Int64 = 1_048_576

    /// Feeds one reading per second at `bytesPerSecond` for `seconds`; returns the seconds at which the rule fired.
    private func feed(_ rule: inout SlowDownload, from start: Int, seconds: Int, bytesPerSecond: Int64,
                      startBytes: Int64 = 0, active: Bool = true) -> [Int] {
        var fired: [Int] = []
        for s in 0...seconds {
            let bytes = startBytes + Int64(s) * bytesPerSecond
            if rule.tooSlow(bytes: bytes, active: active, now: t0.addingTimeInterval(TimeInterval(start + s))) {
                fired.append(start + s)
            }
        }
        return fired
    }

    func testFastDownloadIsLeftAlone() {
        var rule = SlowDownload()
        XCTAssertEqual(feed(&rule, from: 0, seconds: 300, bytesPerSecond: 10 * mb), [])
    }

    func testCrawlingDownloadRestartsAfterTwentySeconds() {
        var rule = SlowDownload()
        XCTAssertEqual(feed(&rule, from: 0, seconds: 25, bytesPerSecond: 84 * 1024), [20])
    }

    func testEachRestartDoublesTheWait() {
        var rule = SlowDownload()
        XCTAssertEqual(feed(&rule, from: 0, seconds: 20, bytesPerSecond: 84 * 1024), [20])
        XCTAssertEqual(rule.window, 40)
        // The next reading starts a new window, which fires 40 s later.
        XCTAssertEqual(feed(&rule, from: 21, seconds: 45, bytesPerSecond: 84 * 1024), [61])
        XCTAssertEqual(rule.window, 80)
        for _ in 0..<10 { rule = rule.afterFiring() }
        XCTAssertEqual(rule.window, SlowDownload.longestWindow)
    }

    func testIdleTimeIsNotCountedAsSlow() {
        // Listing files or loading the model: nothing is being written.
        var rule = SlowDownload()
        XCTAssertEqual(feed(&rule, from: 0, seconds: 120, bytesPerSecond: 0, active: false), [])
    }

    func testFileStartingOverResetsTheWindow() {
        var rule = SlowDownload()
        XCTAssertEqual(feed(&rule, from: 0, seconds: 10, bytesPerSecond: 0, startBytes: 50 * mb), [])
        // Fewer bytes than before (the file was started again): measured from here, at full speed.
        XCTAssertEqual(feed(&rule, from: 11, seconds: 60, bytesPerSecond: 5 * mb), [])
    }
}

private extension SlowDownload {
    /// The rule after one more slow window.
    func afterFiring() -> SlowDownload {
        var rule = self
        _ = rule.tooSlow(bytes: 0, active: true, now: Date(timeIntervalSince1970: 0))
        _ = rule.tooSlow(bytes: 0, active: true, now: Date(timeIntervalSince1970: rule.window))
        return rule
    }
}
