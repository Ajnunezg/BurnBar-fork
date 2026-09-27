import Foundation
import OpenBurnBarKernel

/// What the agents on this machine are doing (`daemon.fleet.*`).
struct BurnBarFleetRPCHandler: BurnBarDaemonRPCDomainHandler {
    static let domain: BurnBarDaemonRPCDomain = .fleet

    let fleetService: BurnBarFleetService
    let wire: BurnBarDaemonRPCWire

    func handle(_ call: BurnBarDaemonRPCCall) async throws -> Data {
        switch call.method {
        case .fleetSnapshot:
            let request = try decode(BurnBarRPCRequestEnvelope.self, from: call)
            switch await fleetService.readLatestSnapshot() {
            case .notReady:
                return wire.encodeErrorResponse(
                    id: request.id,
                    code: BurnBarRPCErrorCode.internalError,
                    message:
                        "BurnBar fleet snapshot is not ready yet: the first probe tick has not completed. Retry shortly."
                )
            case .degraded(let reason, _):
                return wire.encodeErrorResponse(
                    id: request.id,
                    code: BurnBarRPCErrorCode.internalError,
                    message: "BurnBar fleet snapshot tick degraded: \(reason)"
                )
            case .ready(let snapshot):
                return wire.encodeResult(id: request.id, BurnBarFleetSnapshotResponse(snapshot: snapshot))
            }
        case .fleetOrchestratorGet:
            let request = try decode(BurnBarRPCRequestEnvelope.self, from: call)
            return wire.encodeResult(
                id: request.id,
                BurnBarFleetOrchestratorGetResponse(state: try await fleetService.orchestratorStateChecked())
            )
        case .fleetOrchestratorSet:
            let request = try decode(BurnBarRPCRequestEnvelopeWithParams<BurnBarFleetOrchestratorSetParams>.self, from: call)
            do {
                let updated = try await fleetService.setOrchestratorState(
                    BurnBarOrchestratorState(designation: request.params.designation)
                )
                return wire.encodeResult(id: request.id, BurnBarFleetOrchestratorSetResponse(state: updated))
            } catch {
                return rejectedPayload(id: request.id, call: call, error: error)
            }
        case .fleetDirectiveRecord:
            let request = try decode(BurnBarRPCRequestEnvelopeWithParams<BurnBarFleetDirectiveRecordRequest>.self, from: call)
            do {
                let recorded = try await fleetService.recordDirective(request.params.directive)
                return wire.encodeResult(id: request.id, BurnBarFleetDirectiveRecordResponse(directive: recorded))
            } catch {
                return rejectedPayload(id: request.id, call: call, error: error)
            }
        default:
            unhandled(call)
        }
    }

    private func rejectedPayload(id: String, call: BurnBarDaemonRPCCall, error: Error) -> Data {
        wire.encodeErrorResponse(
            id: id,
            code: BurnBarRPCErrorCode.internalError,
            message: "BurnBar RPC method '\(call.method.rawValue)' rejected the payload: \(error.localizedDescription)"
        )
    }
}

private struct BurnBarFleetOrchestratorSetParams: Codable, Sendable {
    let designation: BurnBarOrchestratorDesignation

    private struct StateProbe: Codable {
        let designation: BurnBarOrchestratorDesignation
    }

    private enum CodingKeys: String, CodingKey {
        case state
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let state = try container.decode(StateProbe.self, forKey: .state)
        designation = state.designation
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(StateProbe(designation: designation), forKey: .state)
    }
}
