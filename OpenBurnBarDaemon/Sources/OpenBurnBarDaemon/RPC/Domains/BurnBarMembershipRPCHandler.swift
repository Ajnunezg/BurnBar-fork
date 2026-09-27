import Foundation
import OpenBurnBarEngine

/// BurnBar Pro membership (`daemon.membership.*`).
struct BurnBarMembershipRPCHandler: BurnBarDaemonRPCDomainHandler {
    static let domain: BurnBarDaemonRPCDomain = .membership

    let service: any BurnBarMembershipServing
    let wire: BurnBarDaemonRPCWire

    func handle(_ call: BurnBarDaemonRPCCall) async throws -> Data {
        switch call.method {
        case .membershipStatus:
            let request = try decode(BurnBarRPCRequestEnvelope.self, from: call)
            return wire.encodeResult(id: request.id, await service.status())
        case .membershipCheckoutURL:
            let request = try decode(
                BurnBarRPCRequestEnvelopeWithParams<BurnBarMembershipCheckoutURLRequest>.self,
                from: call
            )
            do {
                return wire.encodeResult(id: request.id, try await service.checkoutURL(request.params))
            } catch let error as BurnBarMembershipServiceError {
                return errorResponse(id: request.id, error: error)
            }
        case .membershipPortalURL:
            let request = try decode(
                BurnBarRPCRequestEnvelopeWithParams<BurnBarMembershipPortalURLRequest>.self,
                from: call
            )
            do {
                return wire.encodeResult(id: request.id, try await service.portalURL(request.params))
            } catch let error as BurnBarMembershipServiceError {
                return errorResponse(id: request.id, error: error)
            }
        case .membershipRestore:
            let request = try decode(BurnBarRPCRequestEnvelope.self, from: call)
            return wire.encodeResult(id: request.id, await service.restore())
        default:
            unhandled(call)
        }
    }

    private func errorResponse(id: String, error: BurnBarMembershipServiceError) -> Data {
        wire.encodeErrorResponse(
            id: id,
            code: error.membershipCode == .unauthenticated ? BurnBarRPCErrorCode.unauthorized : BurnBarRPCErrorCode.internalError,
            message: error.localizedDescription
        )
    }
}
