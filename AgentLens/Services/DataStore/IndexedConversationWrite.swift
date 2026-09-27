import Foundation

struct IndexedConversationWrite: Sendable {
    let record: ConversationRecord
    let jobType: ProjectionJobType
}
