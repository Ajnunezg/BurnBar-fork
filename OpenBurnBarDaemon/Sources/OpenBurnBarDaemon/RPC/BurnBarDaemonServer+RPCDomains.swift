import Foundation
import OpenBurnBarEngine

extension BurnBarDaemonServer {
    /// The handler for a domain that runs off the server actor, or `nil` when the
    /// domain is still implemented as a `BurnBarDaemonServer` extension.
    ///
    /// Built per call from current server state, so a dependency the server swaps
    /// at runtime (the chat store during `code.database.restore`) is never stale.
    /// A domain stays actor-bound while its handler does synchronous work that must
    /// stay serialized with other server state: `switcher` and `databaseRecovery`
    /// write the database file that `code.database.restore` replaces.
    func isolatedRPCHandler(for domain: BurnBarDaemonRPCDomain) -> (any BurnBarDaemonRPCDomainHandler)? {
        switch domain {
        case .chat:
            BurnBarChatRPCHandler(service: chatThreadService, wire: rpcWire, logger: logger)
        case .membership:
            BurnBarMembershipRPCHandler(service: membershipService, wire: rpcWire)
        case .client:
            BurnBarClientRPCHandler(clientRegistry: clientRegistry, wire: rpcWire, logger: logger)
        case .tooling:
            BurnBarToolingRPCHandler(toolingProxy: toolingProxy, wire: rpcWire)
        case .fleet:
            BurnBarFleetRPCHandler(fleetService: fleetService, wire: rpcWire)
        case .warRoom:
            BurnBarWarRoomRPCHandler(flameService: flameService, wire: rpcWire)
        case .auth, .lifecycle, .config, .privacy, .usage, .observability,
             .computerUse, .media, .missionControl, .runWorkspaceApproval,
             .search, .switcher, .memory, .code, .databaseRecovery, .inbox:
            nil
        }
    }

    func handleChatRPC(method: BurnBarRPCMethod, decoder _: JSONDecoder, requestData: Data) async throws -> Data {
        try await BurnBarChatRPCHandler(service: chatThreadService, wire: rpcWire, logger: logger)
            .handle(BurnBarDaemonRPCCall(method: method, requestData: requestData))
    }

    func handleMembershipRPC(method: BurnBarRPCMethod, decoder _: JSONDecoder, requestData: Data) async throws -> Data {
        try await BurnBarMembershipRPCHandler(service: membershipService, wire: rpcWire)
            .handle(BurnBarDaemonRPCCall(method: method, requestData: requestData))
    }
}
