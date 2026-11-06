import Foundation
import GRDB

/// Live list of meetings, newest first.
@MainActor
final class MeetingsObserver: ObservableObject {
    @Published var items: [Meeting] = []
    private var cancellable: AnyDatabaseCancellable?

    init() {
        cancellable = ValueObservation
            .tracking { db in try Meeting.order(Column("createdAt").desc).fetchAll(db) }
            .start(in: AppDatabase.shared.pool, scheduling: .immediate,
                   onError: { AppLog.write("meetings observation failed: \($0)") },
                   onChange: { [weak self] in self?.items = $0 })
    }
}

/// One meeting plus its transcript, kept current.
@MainActor
final class MeetingObserver: ObservableObject {
    @Published var meeting: Meeting?
    @Published var segments: [Segment] = []
    private var cancellable: AnyDatabaseCancellable?

    init(id: String) {
        cancellable = ValueObservation
            .tracking { db -> (Meeting?, [Segment]) in
                let meeting = try Meeting.fetchOne(db, key: id)
                let segments = try Segment.filter(Column("meetingId") == id).order(Column("startTime")).fetchAll(db)
                return (meeting, segments)
            }
            .start(in: AppDatabase.shared.pool, scheduling: .immediate,
                   onError: { AppLog.write("meeting observation failed: \($0)") },
                   onChange: { [weak self] in self?.meeting = $0.0; self?.segments = $0.1 })
    }
}
