import OpenBurnBarEngine
@testable import OpenBurnBarDaemon
import XCTest

final class BurnBarDaemonSocketRPCCoverageTests: XCTestCase {
    func testEveryBurnBarRPCMethodMapsToDaemonHandler() {
        let handled = BurnBarDaemonSocketRPCCoverage.allHandled
        let allMethods = Set(BurnBarRPCMethod.allCases)

        for method in BurnBarRPCMethod.allCases {
            XCTAssertNotNil(
                BurnBarDaemonSocketRPCCoverage.domain(for: method),
                "BurnBarRPCMethod.\(method) (\(method.rawValue)) has no handler domain assignment"
            )
        }

        XCTAssertEqual(
            handled,
            allMethods,
            "Daemon handler registry must cover exactly BurnBarRPCMethod.allCases with no extras"
        )
    }

    func testHandlerDomainsAreDisjoint() {
        let total = BurnBarDaemonRPCDomain.allCases.reduce(0) { $0 + $1.methods.count }
        XCTAssertEqual(
            total,
            BurnBarRPCMethod.allCases.count,
            "Every RPC method must belong to exactly one handler domain"
        )
        for domain in BurnBarDaemonRPCDomain.allCases {
            XCTAssertFalse(domain.methods.isEmpty, "Domain \(domain.rawValue) owns no methods")
            for method in domain.methods {
                XCTAssertEqual(BurnBarDaemonSocketRPCCoverage.domain(for: method), domain)
            }
        }
    }

    func testChatMethodsUseChatDomain() {
        for method in [
            BurnBarRPCMethod.chatThreadCreate,
            .chatThreadList,
            .chatThreadGet,
            .chatMessageAppend
        ] {
            XCTAssertTrue(BurnBarDaemonSocketRPCCoverage.chat.contains(method))
            XCTAssertEqual(BurnBarDaemonSocketRPCCoverage.domain(for: method), .chat)
        }
    }

    func testLinuxPrivacyMethodsHaveTheirOwnDomain() {
        for method in [
            BurnBarRPCMethod.linuxPrivacyInventory,
            .linuxPrivacyDeletionPreview,
            .linuxPrivacyDeletionExecute,
            .linuxPrivacyExport,
            .linuxPrivacyRetentionStatus,
            .linuxPrivacyRetentionApply
        ] {
            XCTAssertEqual(BurnBarDaemonSocketRPCCoverage.domain(for: method), .privacy)
        }
    }

    func testIsolatedHandlersDeclareTheDomainTheyAreRoutedFor() async {
        let server = BurnBarDaemonServer(
            configuration: BurnBarDaemonConfiguration(
                socketAuthToken: "test-token",
                startsMissionControlBackgroundLoops: false
            )
        )
        var isolated: Set<BurnBarDaemonRPCDomain> = []
        for domain in BurnBarDaemonRPCDomain.allCases {
            guard let handler = await server.isolatedRPCHandler(for: domain) else { continue }
            XCTAssertEqual(type(of: handler).domain, domain)
            isolated.insert(domain)
        }
        XCTAssertEqual(isolated, [.chat, .membership, .client, .tooling, .fleet, .warRoom])
    }

    func testDomainRawValuesMatchIPCCanonNames() {
        XCTAssertEqual(BurnBarDaemonRPCDomain.computerUse.rawValue, "computer_use")
        XCTAssertEqual(BurnBarDaemonRPCDomain.missionControl.rawValue, "mission_control")
        XCTAssertEqual(BurnBarDaemonRPCDomain.runWorkspaceApproval.rawValue, "run_workspace_approval")
        XCTAssertEqual(BurnBarDaemonRPCDomain.databaseRecovery.rawValue, "database_recovery")
        XCTAssertEqual(BurnBarDaemonRPCDomain.warRoom.rawValue, "war_room")
    }
}
