import Foundation
import OpenBurnBarEngine

/// One authenticated, capability-checked, rate-limited RPC that the socket
/// router has already resolved to a domain.
struct BurnBarDaemonRPCCall: Sendable {
    let method: BurnBarRPCMethod
    let requestData: Data
}

/// A daemon RPC domain implemented outside the `BurnBarDaemonServer` actor.
///
/// Conformers are `Sendable` values that hold only the dependencies their domain
/// needs (each of which is itself an actor or a `Sendable` store). The server
/// builds one from its current state at dispatch time and awaits `handle`, which
/// runs on the global concurrent executor. Decoding, encoding and error mapping
/// for the domain therefore never occupy the server actor, and the server's own
/// RPC surface shrinks by the domain's method count. The domain-ceiling gate
/// (`scripts/debt/check-rpc-domain-ceiling.sh`) recognises an isolated domain by
/// the `static let domain` declaration in this directory.
protocol BurnBarDaemonRPCDomainHandler: Sendable {
    static var domain: BurnBarDaemonRPCDomain { get }
    func handle(_ call: BurnBarDaemonRPCCall) async throws -> Data
}

extension BurnBarDaemonRPCDomainHandler {
    func decode<Envelope: Decodable>(_ type: Envelope.Type, from call: BurnBarDaemonRPCCall) throws -> Envelope {
        try JSONDecoder().decode(type, from: call.requestData)
    }

    func unhandled(_ call: BurnBarDaemonRPCCall) -> Never {
        preconditionFailure("Unhandled \(Self.domain.rawValue) RPC method: \(call.method.rawValue)")
    }
}

/// Response encoding shared by the server actor and the isolated domain handlers,
/// so both produce byte-identical envelopes and log encode failures the same way.
struct BurnBarDaemonRPCWire: Sendable {
    let logger: BurnBarDaemonLogger

    func encode<Result: Codable & Sendable>(_ envelope: BurnBarRPCResponseEnvelope<Result>) -> Data {
        do {
            return try JSONEncoder().encode(envelope)
        } catch {
            logger.error(
                "rpc_encode_failed",
                metadata: ["error": "\(error)"]
            )
            return encodeErrorResponse(
                id: envelope.id,
                code: BurnBarRPCErrorCode.internalError,
                message: "Failed to encode OpenBurnBar RPC response."
            )
        }
    }

    func encodeResult<Result: Codable & Sendable>(id: String, _ result: Result) -> Data {
        encode(
            BurnBarRPCResponseEnvelope(
                id: id,
                protocolVersion: BurnBarProtocolVersion.current,
                result: result
            )
        )
    }

    func encodeErrorResponse(id: String, code: Int, message: String) -> Data {
        let envelope = BurnBarRPCResponseEnvelope<BurnBarEmptyResult>(
            id: id,
            protocolVersion: BurnBarProtocolVersion.current,
            result: nil,
            error: BurnBarRPCError(code: code, message: message)
        )

        do {
            return try JSONEncoder().encode(envelope)
        } catch {
            logger.error(
                "encode_error_response_failed",
                metadata: ["id": id, "code": "\(code)", "message": message, "error": "\(error)"]
            )
            let fallback = ["error": ["code": code, "message": "Internal encoding error"]] as [String: Any]
            do {
                return try JSONSerialization.data(withJSONObject: fallback)
            } catch {
                logger.silentFailure("encode_fallback_error_response", error: error)
                return Data()
            }
        }
    }
}
