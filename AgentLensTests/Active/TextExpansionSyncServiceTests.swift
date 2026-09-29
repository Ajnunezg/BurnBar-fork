import XCTest
import OpenBurnBarCore
@testable import OpenBurnBar

@MainActor
final class TextExpansionSyncServiceTests: XCTestCase {
    private var dataStore: DataStore!
    private var accountManager: FakeAccountManager!
    private var settingsManager: SettingsManager!
    private var fakeGateway: CloudSyncFirestoreFakeGateway!
    private var context: CloudSyncContext!
    private var vaultKeyStore: StaticSessionLogVaultKeyStore!
    private var vaultKeyPublisher: FakeTextExpansionVaultKeyPublisher!
    private var originalSharedCloudSyncEnabled = true

    override func setUp() async throws {
        dataStore = try makeDiscoveryInMemoryStore()
        accountManager = FakeAccountManager.makeSignedIn()
        settingsManager = SettingsManager(defaults: UserDefaults(suiteName: "test-\(UUID().uuidString)")!)
        // Snippet sync is opt-in; the consent tests below cover the defaults.
        settingsManager.textExpansion.cloudSyncEnabled = true
        fakeGateway = CloudSyncFirestoreFakeGateway()
        vaultKeyStore = StaticSessionLogVaultKeyStore(keyData: Data(repeating: 0x33, count: 32))
        vaultKeyPublisher = FakeTextExpansionVaultKeyPublisher()
        context = CloudSyncContext(
            dataStore: dataStore,
            accountManager: accountManager,
            settingsManager: settingsManager,
            firestoreGateway: fakeGateway
        )
        originalSharedCloudSyncEnabled = SettingsManager.shared.textExpansion.cloudSyncEnabled
        SettingsManager.shared.textExpansion.cloudSyncEnabled = true
    }

    override func tearDown() {
        SettingsManager.shared.textExpansion.cloudSyncEnabled = originalSharedCloudSyncEnabled
        dataStore = nil
        accountManager = nil
        settingsManager = nil
        fakeGateway = nil
        context = nil
        vaultKeyStore = nil
        vaultKeyPublisher = nil
        super.tearDown()
    }

    func testSyncUploadsTextExpansionSnippetAndMarksLocalRowSynced() async throws {
        let updatedAt = Date(timeIntervalSince1970: 1_780_000_000)
        let snippet = TextExpansionSnippet(
            id: "snippet-1",
            title: "Greeting",
            trigger: "hello",
            body: "Hi there",
            mode: .staticText,
            scope: TextExpansionScope(surfaces: [.inAppThread]),
            revision: 3,
            createdAt: updatedAt.addingTimeInterval(-60),
            updatedAt: updatedAt
        )
        try await dataStore.upsertTextExpansionSnippet(snippet)

        let service = TextExpansionSyncService(
            context: context,
            vaultKeyStore: vaultKeyStore,
            vaultKeyPublisher: vaultKeyPublisher
        )

        await service.sync()

        XCTAssertFalse(service.isSyncing)
        XCTAssertNil(service.lastSyncError)
        XCTAssertNotNil(service.lastSyncDate)
        XCTAssertEqual(vaultKeyPublisher.publishedKeys.map(\.uid), ["test-uid-1"])
        XCTAssertEqual(fakeGateway.batchCommitCount, 1)

        let doc = try XCTUnwrap(fakeGateway.documentData(at: "users/test-uid-1/text_snippets/snippet-1"))
        XCTAssertEqual(doc["id"] as? String, "snippet-1")
        XCTAssertEqual(doc["uid"] as? String, "test-uid-1")
        XCTAssertEqual(doc["sourceDeviceID"] as? String, "test-device-1")
        XCTAssertNotNil(doc["triggerHash"])
        XCTAssertNotNil(doc["sealedTitle"])
        XCTAssertNotNil(doc["sealedTrigger"])
        XCTAssertNotNil(doc["sealedBody"])
        XCTAssertNil(doc["title"])
        XCTAssertNil(doc["trigger"])
        XCTAssertNil(doc["body"])

        let unsynced = try await dataStore.fetchUnsyncedTextExpansionSnippets()
        XCTAssertTrue(unsynced.isEmpty)
    }

    func testFakeGatewayExposesNoRawSignalPayloadFirestore() {
        // The protocol's default implementation is the fake-path contract:
        // fakes never surface a real SDK handle, so tests never resolve the
        // global Firestore singleton.
        XCTAssertNil(fakeGateway.rawSignalPayloadFirestore())
    }

    func testSignalPayloadFirestoreThrowsWhenGatewayHasNoRawHandle() {
        let service = TextExpansionSyncService(
            context: context,
            vaultKeyStore: vaultKeyStore,
            vaultKeyPublisher: vaultKeyPublisher
        )

        XCTAssertThrowsError(try service.signalPayloadFirestore()) { error in
            XCTAssertEqual(
                error.localizedDescription,
                TextExpansionSignalSyncError.signalFirestoreUnavailable.errorDescription
            )
        }
    }

    func testSignalSyncErrorsCarryOperatorReadableDescriptions() {
        XCTAssertEqual(
            TextExpansionSignalSyncError.vaultKeyMismatch.errorDescription,
            "Device identity and CloudVault resolved different vault keys. Re-verify this device before syncing snippets."
        )
        XCTAssertEqual(
            TextExpansionSignalSyncError.signalFirestoreUnavailable.errorDescription,
            "The Firestore gateway does not expose a raw handle for payload sealing. Snippet sync was skipped."
        )
    }

    func testSnippetFromSignalPayloadRoundTripsISO8601Snippet() throws {
        let snippet = TextExpansionSnippet(
            id: "snippet-signal-1",
            title: "Signal Greeting",
            trigger: "sig",
            body: "Sealed hi",
            mode: .staticText,
            scope: TextExpansionScope(surfaces: [.inAppThread]),
            revision: 2,
            createdAt: Date(timeIntervalSince1970: 1_780_000_100),
            updatedAt: Date(timeIntervalSince1970: 1_780_000_200)
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let payload = try encoder.encode(snippet)

        let decoded = try XCTUnwrap(TextExpansionSyncService.snippetFromSignalPayload(payload))

        XCTAssertEqual(decoded.id, snippet.id)
        XCTAssertEqual(decoded.title, snippet.title)
        XCTAssertEqual(decoded.trigger, snippet.trigger)
        XCTAssertEqual(decoded.body, snippet.body)
        XCTAssertEqual(decoded.revision, snippet.revision)
        XCTAssertEqual(decoded.createdAt, snippet.createdAt)
        XCTAssertEqual(decoded.updatedAt, snippet.updatedAt)
    }

    func testSnippetFromSignalPayloadReturnsNilForUndecodablePayload() {
        XCTAssertNil(TextExpansionSyncService.snippetFromSignalPayload(Data("not a snippet".utf8)))
    }

    // MARK: - Consent (mirrors AccountManagerCloudSyncConsentTests)

    func testFreshInstallDefaultsSnippetSyncOff() {
        XCTAssertFalse(makeSettingsManager().textExpansion.cloudSyncEnabled)
    }

    func testSnippetSyncChoicePersistsAcrossLaunches() {
        let defaults = makeIsolatedDefaults()
        let first = makeSettingsManager(defaults: defaults)
        first.textExpansion.cloudSyncEnabled = true
        first.persistence.flush()
        XCTAssertTrue(makeSettingsManager(defaults: defaults).textExpansion.cloudSyncEnabled)
    }

    func testUpgradeKeepsTheStoredSnippetSyncChoice() {
        // Every launch since text expansion shipped has persisted this key, so an
        // upgrade reads what it stored rather than the new default.
        let defaults = makeIsolatedDefaults()
        defaults.set(true, forKey: "textExpansion.cloudSyncEnabled")
        XCTAssertTrue(makeSettingsManager(defaults: defaults).textExpansion.cloudSyncEnabled)
    }

    func testCloudSyncOffWritesNothingToFirestore() async throws {
        let docPath = "users/test-uid-1/text_snippets/snippet-consent"
        try await dataStore.upsertTextExpansionSnippet(consentSnippet())
        // Signed in with snippet sync on, but the master switch was never enabled.
        accountManager.isCloudSyncEnabled = false
        let service = makeService()

        await service.sync()
        XCTAssertEqual(fakeGateway.batchCommitCount, 0)
        XCTAssertNil(fakeGateway.documentData(at: docPath))
        XCTAssertTrue(vaultKeyPublisher.publishedKeys.isEmpty)

        // Control: the same snippet uploads once consent is granted, proving the
        // zero above comes from the gate rather than a broken fixture.
        accountManager.isCloudSyncEnabled = true
        await service.sync()
        XCTAssertEqual(fakeGateway.batchCommitCount, 1)
        XCTAssertNotNil(fakeGateway.documentData(at: docPath))
    }

    func testSnippetSyncOffWritesNothingEvenWithCloudSyncOn() async throws {
        try await dataStore.upsertTextExpansionSnippet(consentSnippet())
        settingsManager.textExpansion.cloudSyncEnabled = false

        await makeService().sync()

        XCTAssertEqual(fakeGateway.batchCommitCount, 0)
        XCTAssertNil(fakeGateway.documentData(at: "users/test-uid-1/text_snippets/snippet-consent"))
        XCTAssertTrue(vaultKeyPublisher.publishedKeys.isEmpty)
    }

    private func makeService() -> TextExpansionSyncService {
        TextExpansionSyncService(context: context, vaultKeyStore: vaultKeyStore, vaultKeyPublisher: vaultKeyPublisher)
    }

    private func consentSnippet() -> TextExpansionSnippet {
        let updatedAt = Date(timeIntervalSince1970: 1_780_000_000)
        return TextExpansionSnippet(
            id: "snippet-consent",
            title: "Password",
            trigger: "pw",
            body: "not-a-real-secret",
            mode: .staticText,
            scope: TextExpansionScope(surfaces: [.inAppThread]),
            createdAt: updatedAt.addingTimeInterval(-60),
            updatedAt: updatedAt
        )
    }
}

@MainActor
private final class FakeTextExpansionVaultKeyPublisher: SessionLogVaultKeyPublishing {
    private(set) var publishedKeys: [(uid: String, key: Data)] = []

    func publishCloudVaultKey(uid: String, vaultKey: Data, context: CloudSyncContext) async throws {
        publishedKeys.append((uid, vaultKey))
    }
}
