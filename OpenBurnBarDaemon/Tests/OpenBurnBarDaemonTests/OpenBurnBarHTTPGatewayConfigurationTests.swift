import OpenBurnBarEngine
@testable import OpenBurnBarDaemon
import XCTest

// Keep configuration contracts with the gateway suite while shrinking its monolith.
extension BurnBarHTTPGatewayServerTests {
    func testGatewayConfigurationValidationRejectsUnsafeHosts() {
        XCTAssertEqual(
            BurnBarGatewayConfiguration(isEnabled: true, host: "0.0.0.0", port: 8317, authToken: nil).validationError,
            "Gateway wildcard bind addresses are not allowed. Use a specific interface address."
        )

        XCTAssertEqual(
            BurnBarGatewayConfiguration(isEnabled: true, host: "bad host", port: 8317, authToken: nil).validationError,
            "Gateway host 'bad host' is not a valid hostname or IP address."
        )

        XCTAssertEqual(
            BurnBarGatewayConfiguration(isEnabled: true, host: "192.168.0.10", port: 8317, authToken: nil).validationError,
            "A non-loopback gateway bind address requires an auth token for security."
        )
    }

    func testGatewayConfigurationFailsClosedOnLoopbackWithoutToken() {
        // A1: an unauthenticated loopback bind would let any same-host process
        // POST to the gateway and spend the user's provider credits. Reject it
        // unless the operator explicitly opts in.
        for host in ["127.0.0.1", "localhost", "::1"] {
            XCTAssertEqual(
                BurnBarGatewayConfiguration(isEnabled: true, host: host, port: 8317, authToken: nil).validationError,
                "The gateway requires an auth token. Enable \"Allow unauthenticated loopback\" to bind 127.0.0.1 without one.",
                "Loopback host \(host) must fail closed without a token"
            )
            XCTAssertEqual(
                BurnBarGatewayConfiguration(isEnabled: true, host: host, port: 8317, authToken: "   ").validationError,
                "The gateway requires an auth token. Enable \"Allow unauthenticated loopback\" to bind 127.0.0.1 without one.",
                "A whitespace-only token must be treated as absent for \(host)"
            )
        }
    }

    func testGatewayConfigurationAcceptsLoopbackWithTokenOrDebugExplicitOptIn() {
        // With a token, loopback is valid.
        XCTAssertNil(
            BurnBarGatewayConfiguration(isEnabled: true, host: "127.0.0.1", port: 8317, authToken: "gateway-secret").validationError
        )
        // The opt-in never relaxes a non-loopback bind: those still require a token.
        XCTAssertEqual(
            BurnBarGatewayConfiguration(
                isEnabled: true,
                host: "192.168.0.10",
                port: 8317,
                authToken: nil,
                allowUnauthenticatedLoopback: true
            ).validationError,
            "A non-loopback gateway bind address requires an auth token for security."
        )
        // A disabled gateway is always valid regardless of token state.
        XCTAssertNil(
            BurnBarGatewayConfiguration(isEnabled: false, host: "127.0.0.1", port: 8317, authToken: nil).validationError
        )
        #if DEBUG
        // With the explicit opt-in, an unauthenticated loopback bind is permitted.
        XCTAssertNil(
            BurnBarGatewayConfiguration(
                isEnabled: true,
                host: "127.0.0.1",
                port: 8317,
                authToken: nil,
                allowUnauthenticatedLoopback: true
            ).validationError
        )
        #else
        // In release builds the escape hatch is compile-gated out.
        XCTAssertEqual(
            BurnBarGatewayConfiguration(
                isEnabled: true,
                host: "127.0.0.1",
                port: 8317,
                authToken: nil,
                allowUnauthenticatedLoopback: true
            ).validationError,
            "The gateway requires an auth token. Enable \"Allow unauthenticated loopback\" to bind 127.0.0.1 without one."
        )
        #endif
    }
}
