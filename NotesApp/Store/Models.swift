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
