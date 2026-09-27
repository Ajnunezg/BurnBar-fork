import OpenBurnBarEngine
import OpenBurnBarKernel
@testable import OpenBurnBarDaemon
import XCTest

/// Wire-level contracts for the domain handlers that run off the
/// `BurnBarDaemonServer` actor: the envelope a caller receives, and the error
/// code each failure maps to.
final class BurnBarDaemonRPCDomainHandlerTests: XCTestCase {
    private let wire = BurnBarDaemonRPCWire(logger: BurnBarDaemonLogger(category: "domain-handler-tests"))

    private func call(_ method: BurnBarRPCMethod, _ json: String) -> BurnBarDaemonRPCCall {
        BurnBarDaemonRPCCall(method: method, requestData: Data(json.utf8))
    }

    private func decode<Result: Codable & Sendable>(
        _ type: Result.Type,
        _ data: Data
    ) throws -> BurnBarRPCResponseEnvelope<Result> {
        try JSONDecoder().decode(BurnBarRPCResponseEnvelope<Result>.self, from: data)
    }

    // MARK: - War Room

    func testWarRoomRoutesListsAndSettlesThroughTheDistillLog() async throws {
        let snapshot = FleetSnapshot(bodies: [
            FleetBodySnapshot(
                bodyID: "mac-a",
                displayName: "MAC-A",
                isLocal: true,
                isOnline: true,
                hermesGatewayReachable: true,
                wireReachable: true,
                capabilities: ["hermes_chat"],
                activeRunCount: 0,
                performanceCores: 8
            )
        ])
        let handler = BurnBarWarRoomRPCHandler(
            flameService: BurnBarFlameService(fleetProvider: { snapshot }, makeDecisionID: { "decision-1" }),
            wire: wire
        )

        let routed = try decode(
            BurnBarWarFlameRouteResponse.self,
            try await handler.handle(call(
                .warFlameRoute,
                #"{"id":"route-1","method":"daemon.war.flame.route","params":{"requiredCapabilities":["hermes_chat"],"instruction":"ship it"}}"#
            ))
        )
        XCTAssertEqual(routed.id, "route-1")
        XCTAssertEqual(routed.protocolVersion, BurnBarProtocolVersion.current)
        XCTAssertEqual(routed.result?.record.id, "decision-1")

        let listed = try decode(
            BurnBarWarFlameDistillListResponse.self,
            try await handler.handle(call(
                .warFlameDistillList,
                #"{"id":"list-1","method":"daemon.war.flame.distill.list","params":{"limit":10}}"#
            ))
        )
        XCTAssertEqual(listed.result?.records.map(\.id), ["decision-1"])

        let settled = try decode(
            BurnBarWarFlameDistillSettleResponse.self,
            try await handler.handle(call(
                .warFlameDistillSettle,
                #"{"id":"settle-1","method":"daemon.war.flame.distill.settle","params":{"decisionID":"decision-1","outcome":"succeeded","runID":"run-9"}}"#
            ))
        )
        XCTAssertEqual(settled.result?.settled, true)
        XCTAssertEqual(settled.result?.record?.outcome, .succeeded)
        XCTAssertEqual(settled.result?.record?.runID, "run-9")

        let missed = try decode(
            BurnBarWarFlameDistillSettleResponse.self,
            try await handler.handle(call(
                .warFlameDistillSettle,
                #"{"id":"settle-2","method":"daemon.war.flame.distill.settle","params":{"decisionID":"unknown","outcome":"failed"}}"#
            ))
        )
        XCTAssertEqual(missed.result?.settled, false)
        XCTAssertNil(missed.result?.record)
    }

    // MARK: - Client arbitration

    func testClientAttachClaimAndDetachRoundTrip() async throws {
        let handler = BurnBarClientRPCHandler(
            clientRegistry: BurnBarClientRegistry(logger: BurnBarDaemonLogger(category: "domain-handler-tests")),
            wire: wire,
            logger: BurnBarDaemonLogger(category: "domain-handler-tests")
        )

        let attached = try await handler.handle(call(
            .clientAttach,
            #"{"id":"attach-1","method":"client.attach","params":{"clientID":"app","sessionID":"s-1","clientName":"OpenBurnBar","supportedProtocolVersions":[1,2]}}"#
        ))
        let attachEnvelope = try decode(BurnBarClientAttachResponse.self, attached)
        XCTAssertEqual(attachEnvelope.id, "attach-1")
        XCTAssertNil(attachEnvelope.error)

        let claimed = try decode(
            BurnBarClientArbitrationSnapshot.self,
            try await handler.handle(call(
                .clientClaimControl,
                #"{"id":"claim-1","method":"client.claimControl","params":{"clientID":"app","sessionID":"s-1"}}"#
            ))
        )
        XCTAssertEqual(claimed.result?.activeClientID?.rawValue, "app")

        let detached = try decode(
            BurnBarClientArbitrationSnapshot.self,
            try await handler.handle(call(
                .clientDetach,
                #"{"id":"detach-1","method":"client.detach","params":{"clientID":"app","sessionID":"s-1"}}"#
            ))
        )
        XCTAssertEqual(detached.id, "detach-1")
        XCTAssertNil(detached.result?.activeClientID)
    }

    // MARK: - Chat error mapping

    func testChatServiceErrorsMapToStableRPCCodes() async throws {
        let cases: [(BurnBarChatThreadServiceError, Int, String)] = [
            (.invalidRequest("bad limit"), BurnBarRPCErrorCode.invalidParams, "Invalid chat request: bad limit"),
            (.conflict("exists"), BurnBarRPCErrorCode.conflict, "Chat history conflict: exists"),
            (.unavailable("locked"), BurnBarRPCErrorCode.unavailable, "Chat history unavailable: locked"),
            (.corruptData("row"), BurnBarRPCErrorCode.internalError, "Canonical local chat history contains invalid data."),
            (.database("io"), BurnBarRPCErrorCode.internalError, "Canonical local chat history could not be read or updated.")
        ]
        for (error, code, message) in cases {
            let handler = BurnBarChatRPCHandler(
                service: FailingChatThreadService(error: error),
                wire: wire,
                logger: BurnBarDaemonLogger(category: "domain-handler-tests")
            )
            for request in [
                call(.chatThreadList, #"{"id":"list","method":"daemon.chat.thread.list","params":{"limit":10}}"#),
                call(.chatThreadCreate, #"{"id":"create","method":"daemon.chat.thread.create","params":{"threadID":"t","createdAt":"2026-07-10T12:00:00Z"}}"#)
            ] {
                let envelope = try decode(BurnBarEmptyResult.self, try await handler.handle(request))
                XCTAssertNil(envelope.result)
                XCTAssertEqual(envelope.error?.code, code, "\(error) via \(request.method.rawValue)")
                XCTAssertEqual(envelope.error?.message, message)
            }
        }

        let unknown = BurnBarChatRPCHandler(
            service: FailingChatThreadService(error: CocoaError(.fileReadUnknown)),
            wire: wire,
            logger: BurnBarDaemonLogger(category: "domain-handler-tests")
        )
        let envelope = try decode(
            BurnBarEmptyResult.self,
            try await unknown.handle(call(.chatThreadList, #"{"id":"list","method":"daemon.chat.thread.list","params":{"limit":10}}"#))
        )
        XCTAssertEqual(envelope.error?.code, BurnBarRPCErrorCode.internalError)
        XCTAssertEqual(envelope.error?.message, "Canonical local chat history request failed.")
    }

    func testChatHandlerReportsUnavailableWithoutAService() async throws {
        let handler = BurnBarChatRPCHandler(service: nil, wire: wire, logger: BurnBarDaemonLogger(category: "domain-handler-tests"))
        let envelope = try decode(
            BurnBarEmptyResult.self,
            try await handler.handle(call(.chatThreadList, #"{"id":"list","method":"daemon.chat.thread.list","params":{"limit":10}}"#))
        )
        XCTAssertEqual(envelope.id, "list")
        XCTAssertEqual(envelope.error?.code, BurnBarRPCErrorCode.unavailable)
    }
}

private struct FailingChatThreadService: BurnBarChatThreadServing {
    let error: Error

    func listThreads(_ request: BurnBarChatThreadListRequest) async throws -> BurnBarChatThreadListResponse {
        throw error
    }

    func getThread(_ request: BurnBarChatThreadGetRequest) async throws -> BurnBarChatThreadGetResponse {
        throw error
    }

    func appendMessage(_ request: BurnBarChatMessageAppendRequest) async throws -> BurnBarChatMessageAppendResponse {
        throw error
    }

    func createThread(_ request: BurnBarChatThreadCreateRequest) async throws -> BurnBarChatThreadCreateResponse {
        throw error
    }
}
