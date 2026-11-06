import XCTest
@testable import Off_the_Record

/// The echo gate: microphone frames where the call is clearly louder are silenced, so the other
/// side heard through the speakers is not transcribed as "You". Signals are 16 kHz, 20 ms frames.
final class EchoGateTests: XCTestCase {
    private let frame = 320

    /// A tone of the given amplitude for `frames` frames.
    private func tone(_ amplitude: Float, frames: Int, hz: Float = 440) -> [Float] {
        (0..<(frames * frame)).map { amplitude * sinf(2 * .pi * hz * Float($0) / 16_000) }
    }

    private func frameIsSilent(_ samples: [Float], _ k: Int) -> Bool {
        samples[(k * frame)..<((k + 1) * frame)].allSatisfy { $0 == 0 }
    }

    func testEchoThroughSpeakersIsRemoved() {
        let call = tone(0.3, frames: 200)
        let mic = call.map { $0 * 0.16 }                      // the call leaking in at about -16 dB
        let out = SpeechEngine.suppressEcho(mic: mic, system: call)
        XCTAssertTrue(out.allSatisfy { $0 == 0 })
    }

    func testYourVoiceIsKeptWhenTheCallIsQuiet() {
        let call = [Float](repeating: 0, count: 200 * frame)
        let mic = tone(0.2, frames: 200)
        XCTAssertEqual(SpeechEngine.suppressEcho(mic: mic, system: call), mic)
    }

    /// With headphones the mic barely hears the call, so talking over the other side is kept and
    /// only the faint leak goes.
    func testHeadphonesKeepTalkingOverTheCall() {
        let call = tone(0.3, frames: 200)
        var mic = call.map { $0 * 0.005 }                     // faint leak, far under -35 dB
        let voice = tone(0.1, frames: 50, hz: 220)
        mic.replaceSubrange((150 * frame)..<(200 * frame), with: voice)
        let out = SpeechEngine.suppressEcho(mic: mic, system: call)
        for k in 0..<150 { XCTAssertTrue(frameIsSilent(out, k), "leak frame \(k) kept") }
        XCTAssertEqual(Array(out[(150 * frame)...]), voice)
    }

    /// Echo arriving up to 60 ms after the call stops speaking is still caught.
    func testLateEchoIsCaught() {
        let call = tone(0.3, frames: 100) + [Float](repeating: 0, count: 100 * frame)
        let delay = 2 * frame                                 // 40 ms
        var mic = [Float](repeating: 0, count: delay) + call.map { $0 * 0.16 }
        mic.removeLast(delay)
        let out = SpeechEngine.suppressEcho(mic: mic, system: call)
        XCTAssertTrue(frameIsSilent(out, 100))
        XCTAssertTrue(frameIsSilent(out, 101))
    }

    func testTooShortToJudgeIsLeftAlone() {
        let mic: [Float] = Array(repeating: 0.5, count: 100)
        XCTAssertEqual(SpeechEngine.suppressEcho(mic: mic, system: Array(repeating: 0.9, count: 100)), mic)
    }
}
