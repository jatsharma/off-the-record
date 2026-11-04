import Foundation
import GRDB

enum MeetingStatus: String, Codable {
    case recording, transcribing, summarizing, done, failed
}

struct Meeting: Codable, Identifiable, Hashable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "meeting"
    static let segments = hasMany(Segment.self)

    var id: String
    var title: String
    var createdAt: Date
    var durationSeconds: Double
    var audioPath: String?
    var summary: String?
    var status: MeetingStatus
    var errorMessage: String?

    var audioURL: URL? { audioPath.map { AppDatabase.audioDirectory.appendingPathComponent($0) } }
}

struct Segment: Codable, Identifiable, Hashable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "segment"
    static let meeting = belongsTo(Meeting.self)

    var id: String
    var meetingId: String
    var startTime: Double
    var endTime: Double
    var speaker: String?
    var text: String
}

/// A named voice, averaged from every meeting where the user named that speaker.
struct VoicePrint: Codable, Identifiable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "voiceprint"
    var id: String
    var name: String
    var vector: Data
    var samples: Int
    var updatedAt: Date
}

/// The voice embedding of one speaker label in one meeting, kept so a later rename can teach a VoicePrint.
struct MeetingSpeaker: Codable, Identifiable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "meetingSpeaker"
    var id: String
    var meetingId: String
    var speaker: String
    var vector: Data
}

enum Vectors {
    static func data(_ v: [Float]) -> Data { v.withUnsafeBufferPointer { Data(buffer: $0) } }
    static func floats(_ d: Data) -> [Float] {
        d.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    }
    static func cosine(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot: Float = 0, na: Float = 0, nb: Float = 0
        for i in 0..<a.count { dot += a[i] * b[i]; na += a[i] * a[i]; nb += b[i] * b[i] }
        return na > 0 && nb > 0 ? dot / (na.squareRoot() * nb.squareRoot()) : 0
    }
    static func mean(_ vs: [[Float]]) -> [Float] {
        guard let first = vs.first else { return [] }
        var out = [Float](repeating: 0, count: first.count)
        for v in vs where v.count == first.count { for i in 0..<v.count { out[i] += v[i] } }
        return out.map { $0 / Float(vs.count) }
    }
}
