import OpenBurnBarEngine
import Foundation

extension BurnBarDaemonServer {
    var rpcWire: BurnBarDaemonRPCWire {
        BurnBarDaemonRPCWire(logger: logger)
    }

    func encode<Result: Codable & Sendable>(_ envelope: BurnBarRPCResponseEnvelope<Result>) -> Data {
        rpcWire.encode(envelope)
    }

    func encodeErrorResponse(id: String, code: Int, message: String) -> Data {
        rpcWire.encodeErrorResponse(id: id, code: code, message: message)
    }
}
