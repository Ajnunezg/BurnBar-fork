import XCTest
@testable import OpenBurnBar
import OpenBurnBarCore

final class BugReportingTests: XCTestCase {
    func testSystemDiagnosticsCollectorCapturesValidSnapshot() {
        let snapshot = SystemDiagnosticsCollector.capture(
            isDaemonConnected: true,
            activeProviders: ["claude", "codex"]
        )

        XCTAssertFalse(snapshot.osVersion.isEmpty)
        XCTAssertFalse(snapshot.macModel.isEmpty)
        XCTAssertFalse(snapshot.appVersion.isEmpty)
        XCTAssertGreaterThan(snapshot.physicalMemoryGB, 0)
        XCTAssertTrue(snapshot.isDaemonConnected)
        XCTAssertEqual(snapshot.activeProviders, ["claude", "codex"])

        let dict = snapshot.asDictionary
        XCTAssertEqual(dict["osVersion"], snapshot.osVersion)
        XCTAssertEqual(dict["macModel"], snapshot.macModel)
        XCTAssertEqual(dict["isDaemonConnected"], "true")
    }

    func testBugInvestigationMissionRuntimeResolution() {
        let backend = CLIAgentMissionRuntimePlanner.resolve(
            requestedRuntime: "auto",
            missionKind: "bug_investigation",
            enabledBackends: [.claude, .codex]
        )

        XCTAssertEqual(backend.rawValue, "claude")
    }

    func testBugInvestigationPromptFormatting() {
        // Linear context is authored server-side (formatBugInvestigationPrompt in
        // functions-sync/src/domains/support/bugReporting.ts); the Mac planner has no
        // bug-specific branch and must carry that prompt through verbatim.
        let serverPrompt = "You are investigating a bug report filed on macOS and tracked in Linear as [BB-42](https://linear.app/example/issue/BB-42)."
        let data: [String: Any] = [
            "source": "macos-bug-report",
            "targetProject": "BurnBar",
            "missionKind": "bug_investigation",
            "commandsAllowed": true,
            "fileEditsAllowed": true
        ]

        let prompt = CLIAgentMissionRuntimePlanner.prompt(
            title: "[Bug BB-42] Fix menu bar crash",
            prompt: serverPrompt,
            backend: CLIAgentMissionBackend(chatBackend: .claude),
            data: data
        )

        XCTAssertTrue(prompt.contains(serverPrompt), "server-authored Linear context must reach the CLI verbatim")
        XCTAssertTrue(prompt.contains("Mission: [Bug BB-42] Fix menu bar crash"))
        XCTAssertTrue(prompt.contains("Target project: BurnBar"))
        XCTAssertTrue(prompt.contains("Commands allowed: yes"))
        XCTAssertTrue(prompt.contains("File edits allowed: yes"))
    }

    @MainActor
    func testAppCommandRouterHandlesBugReportAndHelpSupportUrls() {
        let router = AppCommandRouter()
        var bugReportOpened = false
        var helpSupportOpened = false

        router.openBugReport = { bugReportOpened = true }
        router.openHelpSupport = { helpSupportOpened = true }

        let bugUrl = URL(string: "openburnbar://bug-report")!
        let handledBug = router.handle(bugUrl)
        XCTAssertTrue(handledBug)
        XCTAssertTrue(bugReportOpened)

        let supportUrl = URL(string: "openburnbar://support")!
        let handledSupport = router.handle(supportUrl)
        XCTAssertTrue(handledSupport)
        XCTAssertTrue(helpSupportOpened)
    }
}
