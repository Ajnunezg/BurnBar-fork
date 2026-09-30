import XCTest
import SwiftUI
import SnapshotTesting
import OpenBurnBarUI
@testable import OpenBurnBar

// MARK: - Chat Visual Regression Tests

/// Guards chat bubbles, panel chrome, and FAB visuals in both color schemes.
@MainActor
final class ChatVisualSnapshotTests: XCTestCase {

    func test_chatMessageView_user() throws {
        let message = ViewTestFixtures.makeUserMessage(content: "What's my burn rate today?")
        let view = ChatMessageView(
            message: message,
            isStreaming: false,
            showViaBadge: false
        )
        try XCTAssertAdaptiveSnapshot(
            of: view,
            size: CGSize(width: 400, height: 80),
            named: "chatVisual.userMessage"
        )
    }

    func test_chatMessageView_hermesWithBadge() throws {
        let message = ViewTestFixtures.makeHermesAssistantMessage(
            textPieces: ["Your burn rate is $4.20 today."],
            toolPieces: [],
            cliUsed: "hermes"
        )
        let view = ChatMessageView(
            message: message,
            isStreaming: false,
            showViaBadge: true,
            isHermes: true
        )
        try XCTAssertAdaptiveSnapshot(
            of: view,
            size: CGSize(width: 400, height: 120),
            named: "chatVisual.hermesBadge"
        )
    }

    func test_chatFAB_withInsights() throws {
        let view = ChatFAB(hasNewInsights: true, action: {})
        try XCTAssertAdaptiveSnapshot(
            of: view,
            size: CGSize(width: 80, height: 80),
            named: SnapshotName.chatFAB
        )
    }

    /// The test host is the real app, so its preferences are the developer's
    /// own plist, where a stray `appSkin = editorial` light-locks every dark
    /// render. The argument domain stands in for that plist because it outranks
    /// it. Runs without a snapshot host: nothing is rendered.
    func test_hostAppearancePreferencesDoNotReachRenders() {
        do {
            let defaults = UserDefaults.standard
            let domain = UserDefaults.argumentDomain
            let saved = defaults.volatileDomain(forName: domain)
            defaults.setVolatileDomain(
                saved.merging([AppSkin.storageKey: AppSkin.editorial.rawValue]) { _, host in host },
                forName: domain
            )
            defer { defaults.setVolatileDomain(saved, forName: domain) }
            XCTAssertEqual(AppSkin.current, .editorial, "precondition: the host skin is visible outside the isolation")

            withIsolatedSnapshotDefaults {
                XCTAssertEqual(AppSkin.current, .aurora)
            }
            XCTAssertEqual(AppSkin.current, .editorial, "the isolation restores the argument domain")
        }

        let hostDomain = UserDefaults.standard.persistentDomain(forName: Bundle.main.bundleIdentifier ?? "") ?? [:]
        for key in hostDomain.keys {
            XCTAssertNil(snapshotAppStorage.object(forKey: key), "@AppStorage in a render sees the host's \(key)")
        }
    }

    func test_chatFAB_withoutInsights() throws {
        let view = ChatFAB(hasNewInsights: false, action: {})
        try XCTAssertAdaptiveSnapshot(
            of: view,
            size: CGSize(width: 80, height: 80),
            named: "chatFAB.noInsights"
        )
    }
}
