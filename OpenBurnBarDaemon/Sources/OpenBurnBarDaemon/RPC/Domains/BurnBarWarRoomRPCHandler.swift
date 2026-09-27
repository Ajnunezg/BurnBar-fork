import Foundation
import OpenBurnBarKernel

/// War Room, the Flame (`daemon.war.flame.*`): decides which machine should do a
/// thing next and keeps the distill log of how those decisions settled.
struct BurnBarWarRoomRPCHandler: BurnBarDaemonRPCDomainHandler {
    static let domain: BurnBarDaemonRPCDomain = .warRoom

    let flameService: BurnBarFlameService
    let wire: BurnBarDaemonRPCWire

    func handle(_ call: BurnBarDaemonRPCCall) async throws -> Data {
        switch call.method {
        case .warFlameRoute:
            let request = try decode(BurnBarRPCRequestEnvelopeWithParams<BurnBarWarFlameRouteParams>.self, from: call)
            let routed = await flameService.route(
                requiredCapabilities: Set(request.params.requiredCapabilities),
                instruction: request.params.instruction
            )
            return wire.encodeResult(
                id: request.id,
                BurnBarWarFlameRouteResponse(decision: routed.decision, record: routed.record)
            )
        case .warFlameDistillList:
            let request = try decode(BurnBarRPCRequestEnvelopeWithParams<BurnBarWarFlameDistillListParams>.self, from: call)
            // Clamp deliberately rather than relying on the log's capacity to
            // happen to bound the response.
            let requested = request.params.limit ?? 50
            let records = await flameService.recentRecords(limit: min(requested, DistillLog.defaultCapacity))
            let rate = await flameService.successRate()
            return wire.encodeResult(
                id: request.id,
                BurnBarWarFlameDistillListResponse(records: records, successRate: rate)
            )
        case .warFlameDistillSettle:
            let request = try decode(BurnBarRPCRequestEnvelopeWithParams<BurnBarWarFlameDistillSettleParams>.self, from: call)
            let record = await flameService.settle(
                decisionID: request.params.decisionID,
                outcome: request.params.outcome,
                runID: request.params.runID
            )
            return wire.encodeResult(
                id: request.id,
                BurnBarWarFlameDistillSettleResponse(settled: record != nil, record: record)
            )
        default:
            unhandled(call)
        }
    }
}
