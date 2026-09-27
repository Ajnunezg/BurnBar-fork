import Foundation
import OpenBurnBarEngine

/// Canonical local chat history (`daemon.chat.*`).
struct BurnBarChatRPCHandler: BurnBarDaemonRPCDomainHandler {
    static let domain: BurnBarDaemonRPCDomain = .chat

    /// `nil` when no database path is configured, or while `code.database.restore`
    /// is reopening the store.
    let service: (any BurnBarChatThreadServing)?
    let wire: BurnBarDaemonRPCWire
    let logger: BurnBarDaemonLogger

    func handle(_ call: BurnBarDaemonRPCCall) async throws -> Data {
        switch call.method {
        case .chatThreadList:
            let request = try decode(BurnBarRPCRequestEnvelopeWithParams<BurnBarChatThreadListRequest>.self, from: call)
            return await respond(id: request.id) { try await $0.listThreads(request.params) }
        case .chatThreadGet:
            let request = try decode(BurnBarRPCRequestEnvelopeWithParams<BurnBarChatThreadGetRequest>.self, from: call)
            return await respond(id: request.id) { try await $0.getThread(request.params) }
        case .chatMessageAppend:
            let request = try decode(BurnBarRPCRequestEnvelopeWithParams<BurnBarChatMessageAppendRequest>.self, from: call)
            return await respond(id: request.id) { try await $0.appendMessage(request.params) }
        case .chatThreadCreate:
            let request = try decode(BurnBarRPCRequestEnvelopeWithParams<BurnBarChatThreadCreateRequest>.self, from: call)
            return await respond(id: request.id) { try await $0.createThread(request.params) }
        default:
            unhandled(call)
        }
    }

    private func respond<Result: Codable & Sendable>(
        id: String,
        _ operation: (any BurnBarChatThreadServing) async throws -> Result
    ) async -> Data {
        guard let service else {
            return wire.encodeErrorResponse(
                id: id,
                code: BurnBarRPCErrorCode.unavailable,
                message: "Canonical local chat history is unavailable. Configure the OpenBurnBar database path and restart the daemon."
            )
        }
        do {
            return wire.encodeResult(id: id, try await operation(service))
        } catch {
            return errorResponse(id: id, error: error)
        }
    }

    private func errorResponse(id: String, error: Error) -> Data {
        let code: Int
        let message: String
        switch error {
        case BurnBarChatThreadServiceError.invalidRequest(let detail):
            code = BurnBarRPCErrorCode.invalidParams
            message = "Invalid chat request: \(detail)"
        case BurnBarChatThreadServiceError.conflict(let detail):
            code = BurnBarRPCErrorCode.conflict
            message = "Chat history conflict: \(detail)"
        case BurnBarChatThreadServiceError.unavailable(let detail):
            code = BurnBarRPCErrorCode.unavailable
            message = "Chat history unavailable: \(detail)"
        case BurnBarChatThreadServiceError.corruptData(_):
            code = BurnBarRPCErrorCode.internalError
            message = "Canonical local chat history contains invalid data."
        case BurnBarChatThreadServiceError.database(_):
            code = BurnBarRPCErrorCode.internalError
            message = "Canonical local chat history could not be read or updated."
        default:
            code = BurnBarRPCErrorCode.internalError
            message = "Canonical local chat history request failed."
        }
        logger.error(
            "chat_rpc_failed",
            metadata: ["request_id": id, "error": "\(error)"]
        )
        return wire.encodeErrorResponse(id: id, code: code, message: message)
    }
}
