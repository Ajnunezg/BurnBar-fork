import Foundation
import OpenBurnBarEngine

/// Multi-client attach / detach / control arbitration (`client.*`).
struct BurnBarClientRPCHandler: BurnBarDaemonRPCDomainHandler {
    static let domain: BurnBarDaemonRPCDomain = .client

    let clientRegistry: BurnBarClientRegistry
    let wire: BurnBarDaemonRPCWire
    let logger: BurnBarDaemonLogger

    func handle(_ call: BurnBarDaemonRPCCall) async throws -> Data {
        switch call.method {
        case .clientAttach:
            let request = try decode(BurnBarRPCRequestEnvelopeWithParams<BurnBarClientAttachRequest>.self, from: call)
            let (attachResponse, arbitration) = await clientRegistry.attach(request.params)
            logger.notice(
                "client_arbitration_updated",
                metadata: [
                    "active_client_id": arbitration.activeClientID?.rawValue ?? "none",
                    "reason": arbitration.reason ?? "none"
                ]
            )
            return wire.encodeResult(id: request.id, attachResponse)
        case .clientDetach:
            let request = try decode(BurnBarRPCRequestEnvelopeWithParams<BurnBarClientDetachRequest>.self, from: call)
            return wire.encodeResult(id: request.id, try await clientRegistry.detach(request.params))
        case .clientClaimControl:
            let request = try decode(BurnBarRPCRequestEnvelopeWithParams<BurnBarClientClaimControlRequest>.self, from: call)
            return wire.encodeResult(id: request.id, try await clientRegistry.claimControl(request.params))
        default:
            unhandled(call)
        }
    }
}
