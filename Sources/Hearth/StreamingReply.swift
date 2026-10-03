import Foundation
import Observation
import HearthCore

/// Only the active message and scroll anchor observe token updates.
/// The catalog, sidebar, composer, and saved messages remain unchanged while streaming.
@MainActor @Observable
final class StreamingReply {
    let conversationID: UUID
    let messageID: UUID
    var message: ChatMessage
    /// What the model is doing before its first words, such as looking at an image.
    var phase: String?
    init(conversationID: UUID, message: ChatMessage) {
        self.conversationID = conversationID
        self.messageID = message.id
        self.message = message
    }
}
