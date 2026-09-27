import Foundation
import OpenBurnBarEngine

/// Connector plane and browser tooling (`daemon.connector.*`, `daemon.browser.*`).
struct BurnBarToolingRPCHandler: BurnBarDaemonRPCDomainHandler {
    static let domain: BurnBarDaemonRPCDomain = .tooling

    let toolingProxy: BurnBarToolingProxyService
    let wire: BurnBarDaemonRPCWire

    func handle(_ call: BurnBarDaemonRPCCall) async throws -> Data {
        switch call.method {
        case .connectorPlaneGet:
            let request = try decode(BurnBarRPCRequestEnvelope.self, from: call)
            return wire.encodeResult(
                id: request.id,
                BurnBarConnectorPlaneResponse(snapshot: try await toolingProxy.connectorPlaneSnapshot())
            )
        case .connectorConfigUpdate:
            let request = try decode(BurnBarRPCRequestEnvelopeWithParams<BurnBarConnectorConfigUpdateRequest>.self, from: call)
            return wire.encodeResult(
                id: request.id,
                BurnBarConnectorPlaneResponse(snapshot: try await toolingProxy.updateConnectorPlane(request.params))
            )
        case .connectorAction:
            let request = try decode(BurnBarRPCRequestEnvelopeWithParams<BurnBarConnectorActionRequest>.self, from: call)
            return wire.encodeResult(id: request.id, try await toolingProxy.performConnectorAction(request.params))
        case .browserToolingGet:
            let request = try decode(BurnBarRPCRequestEnvelope.self, from: call)
            return wire.encodeResult(
                id: request.id,
                BurnBarBrowserToolingResponse(snapshot: try await toolingProxy.browserToolingSnapshot())
            )
        case .browserToolingUpdate:
            let request = try decode(BurnBarRPCRequestEnvelopeWithParams<BurnBarBrowserToolingUpdateRequest>.self, from: call)
            return wire.encodeResult(
                id: request.id,
                BurnBarBrowserToolingResponse(snapshot: try await toolingProxy.updateBrowserTooling(request.params))
            )
        case .browserAction:
            let request = try decode(BurnBarRPCRequestEnvelopeWithParams<BurnBarBrowserActionRequest>.self, from: call)
            return wire.encodeResult(id: request.id, try await toolingProxy.performBrowserAction(request.params))
        default:
            unhandled(call)
        }
    }
}
