import OpenBurnBarEngine
import OpenBurnBarComputerUseCore
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation

extension BurnBarDaemonServer {
    public func healthResponse() -> BurnBarHealthResponse {
        BurnBarHealthResponse(
            ok: true,
            daemonVersion: configuration.daemonVersion,
            protocolVersion: BurnBarProtocolVersion.current,
            socketPath: configuration.socketPath,
            gatewayEnabled: configuration.gateway.isEnabled,
            gatewayHost: configuration.gateway.isEnabled ? configuration.gateway.host : nil,
            gatewayPort: configuration.gateway.isEnabled ? configuration.gateway.port : nil
        )
    }

    private func responseData(for requestData: Data) async -> Data {
        await responseData(for: requestData, peerPID: nil)
    }

    private func responseData(
        for requestData: Data,
        peerPID: pid_t?,
        peerCapabilityProfile: BurnBarPeerCapabilityProfile? = nil
    ) async -> Data {
        let rpcStartedAt = ContinuousClock.now
        defer {
            let elapsed = rpcStartedAt.duration(to: ContinuousClock.now)
            let milliseconds = Int(elapsed.components.seconds * 1000)
                + Int(elapsed.components.attoseconds / 1_000_000_000_000_000)
            BurnBarDaemonMetricsCounters.recordRPCLatency(milliseconds: milliseconds)
        }
        do {
            let decoder = JSONDecoder()
            let incomingRequest = try decoder.decode(IncomingRequestEnvelope.self, from: requestData)
            BurnBarDaemonMetricsCounters.recordRPCRequest()

            if let requiredToken = configuration.socketAuthToken?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty {
                let providedToken = incomingRequest.authToken?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
                guard let providedToken, constantTimeTokensEqual(providedToken, requiredToken) else {
                    BurnBarDaemonMetricsCounters.recordRPCError()
                    logger.warning(
                        "rpc_request_unauthorized",
                        metadata: [
                            "request_id": incomingRequest.id,
                            "method": incomingRequest.method,
                            "peer_pid": peerPID.map(String.init) ?? "unknown"
                        ]
                    )
                    return encodeErrorResponse(
                        id: incomingRequest.id,
                        code: BurnBarRPCErrorCode.unauthorized,
                        message: "Unauthorized OpenBurnBar RPC request."
                    )
                }
            }

            guard let method = BurnBarRPCMethod(rawValue: incomingRequest.method) else {
                BurnBarDaemonMetricsCounters.recordRPCError()
                logger.error(
                    "rpc_method_not_found",
                    metadata: [
                        "request_id": incomingRequest.id,
                        "method": incomingRequest.method
                    ]
                )
                return encodeErrorResponse(
                    id: incomingRequest.id,
                    code: BurnBarRPCErrorCode.methodNotFound,
                    message: "Unsupported OpenBurnBar RPC method '\(incomingRequest.method)'."
                )
            }

            // T-DMN-01: per-operation capability attenuation. Refuse — fail closed
            // — any method whose capability group is outside this peer's scoped
            // profile, BEFORE the rate limiter or any handler runs. This bounds
            // what an authenticated-but-compromised first-party peer may do.
            let effectiveCapabilityProfile = peerCapabilityProfile
                .map { capabilityProfile.attenuated(to: $0) }
                ?? capabilityProfile
            guard effectiveCapabilityProfile.permits(method) else {
                BurnBarDaemonMetricsCounters.recordRPCError()
                logger.warning(
                    "rpc_request_capability_denied",
                    metadata: [
                        "request_id": incomingRequest.id,
                        "method": incomingRequest.method,
                        "capability": BurnBarRPCCapability.capability(for: method).rawValue,
                        "peer_pid": peerPID.map(String.init) ?? "unknown"
                    ]
                )
                return encodeErrorResponse(
                    id: incomingRequest.id,
                    code: BurnBarRPCErrorCode.unauthorized,
                    message: "OpenBurnBar RPC method '\(incomingRequest.method)' is outside this peer's capability scope."
                )
            }

            // Rate limiting check (per peer PID)
            if let rateLimiter {
                let clientKey = peerPID.map(String.init) ?? "unknown"
                let limitResult = await rateLimiter.checkLimit(clientKey: clientKey)
                if case .throttled(let retryAfter) = limitResult {
                    BurnBarDaemonMetricsCounters.recordRPCError()
                    logger.warning(
                        "rpc_rate_limit_exceeded",
                        metadata: [
                            "request_id": incomingRequest.id,
                            "method": incomingRequest.method,
                            "peer_pid": clientKey,
                            "retry_after": "\(retryAfter)"
                        ]
                    )
                    return encodeErrorResponse(
                        id: incomingRequest.id,
                        code: BurnBarRPCErrorCode.rateLimitExceeded,
                        message: "Rate limit exceeded. Retry after \(String(format: "%.1f", retryAfter)) seconds."
                    )
                }
            }

            let request = BurnBarRPCRequestEnvelope(id: incomingRequest.id, method: method, authToken: incomingRequest.authToken)

            guard let domain = BurnBarDaemonSocketRPCCoverage.domain(for: method) else {
                BurnBarDaemonMetricsCounters.recordRPCError()
                logger.error(
                    "rpc_method_unrouted",
                    metadata: ["request_id": incomingRequest.id, "method": incomingRequest.method]
                )
                return encodeErrorResponse(
                    id: incomingRequest.id,
                    code: BurnBarRPCErrorCode.methodNotFound,
                    message: "OpenBurnBar RPC method '\(incomingRequest.method)' has no daemon handler domain."
                )
            }
            if let handler = isolatedRPCHandler(for: domain) {
                return try await handler.handle(BurnBarDaemonRPCCall(method: method, requestData: requestData))
            }

            switch domain {
            case .auth:
                return try await handleLinuxAuthRPC(method: method, decoder: decoder, requestData: requestData)
            case .lifecycle:
                return try await handleLifecycleRPC(method: method, decoder: decoder, request: request, requestData: requestData)
            case .config:
                return try await handleConfigRPC(method: method, decoder: decoder, requestData: requestData)
            case .privacy:
#if os(Linux)
                return try await handleLinuxPrivacyRPC(method: method, decoder: decoder, requestData: requestData)
#else
                return encodeErrorResponse(
                    id: request.id,
                    code: BurnBarRPCErrorCode.methodNotFound,
                    message: "Linux privacy RPCs are unavailable on macOS."
                )
#endif
            case .usage:
                return try await handleUsageRPC(method: method, decoder: decoder, requestData: requestData)
            case .inbox:
                return try await handleInboxRPC(method: method, decoder: decoder, request: request, requestData: requestData)
            case .observability:
                return try await handleObservabilityRPC(method: method, decoder: decoder, requestData: requestData)
            case .computerUse:
                return try await handleComputerUseRPC(method: method, decoder: decoder, requestData: requestData, peerPID: peerPID)
            case .media:
                return try await handleMediaRPC(method: method, decoder: decoder, request: request, requestData: requestData)
            case .missionControl:
                return try await handleMissionControlRPC(method: method, decoder: decoder, requestData: requestData)
            case .runWorkspaceApproval:
                return try await handleRunWorkspaceApprovalRPC(method: method, decoder: decoder, requestData: requestData)
            case .search:
                return try await handleSearchRPC(method: method, decoder: decoder, requestData: requestData)
            case .switcher:
                return try await handleSwitcherRPC(method: method, decoder: decoder, requestData: requestData)
            case .memory:
                return try await handleMemoryRPC(method: method, decoder: decoder, requestData: requestData)
            case .code:
                return try await handleCodeRPC(method: method, decoder: decoder, requestData: requestData)
            case .databaseRecovery:
                return try await handleDatabaseRecoveryRPC(method: method, decoder: decoder, requestData: requestData)
            case .chat, .membership, .client, .tooling, .fleet, .warRoom:
                preconditionFailure("\(domain.rawValue) RPCs are served by an isolated domain handler")
            }
        } catch {
            BurnBarDaemonMetricsCounters.recordRPCError()
            logger.error(
                "rpc_request_failed",
                metadata: ["error": "\(error)"]
            )
            return encodeErrorResponse(
                id: "invalid-request",
                code: error is DecodingError ? BurnBarRPCErrorCode.invalidParams : BurnBarRPCErrorCode.internalError,
                message: error.localizedDescription
            )
        }
    }

    static func runAcceptLoop(
        server: BurnBarDaemonServer,
        listenerFileDescriptor: Int32,
        connectionGate: BurnBarConnectionGate,
        logger: BurnBarDaemonLogger
    ) async {
        while !Task.isCancelled {
            let clientFileDescriptor = accept(listenerFileDescriptor, nil, nil)
            if clientFileDescriptor == -1 {
                let code = errno
                if code == EINTR {
                    continue
                }

                if code == EBADF || code == EINVAL || Task.isCancelled {
                    break
                }

                logger.error(
                    "accept_failed",
                    metadata: ["errno": "\(code)"]
                )
                continue
            }

            // Round-4 perf sweep: back-pressure. If the gate is at capacity,
            // close the connection immediately rather than spawning an
            // unbounded handler. This prevents FD/memory exhaustion under
            // client bursts; the client's retry is cheap over a local socket.
            guard connectionGate.tryAcquire() else {
                close(clientFileDescriptor)
                logger.warning(
                    "connection_limit_reached",
                    metadata: ["max": "\(connectionGate.maxCount)"]
                )
                continue
            }

            Task.detached(priority: .utility) { [logger] in
                await Self.handleClientConnection(
                    server: server,
                    clientFileDescriptor: clientFileDescriptor,
                    connectionGate: connectionGate,
                    logger: logger
                )
            }
        }

        logger.debug("accept_loop_stopped")
    }

    private static func peerPID(for clientFileDescriptor: Int32) -> pid_t? {
        #if canImport(Darwin)
        var pid: pid_t = 0
        var pidSize = socklen_t(MemoryLayout<pid_t>.size)
        let result = getsockopt(clientFileDescriptor, SOL_LOCAL, LOCAL_PEERPID, &pid, &pidSize)
        return result == 0 ? pid : nil
        #elseif os(Linux)
        var credential = BurnBarLinuxPeerSocketCredentials()
        var credentialSize = socklen_t(MemoryLayout<BurnBarLinuxPeerSocketCredentials>.size)
        let result = withUnsafeMutablePointer(to: &credential) { pointer in
            getsockopt(clientFileDescriptor, SOL_SOCKET, SO_PEERCRED, pointer, &credentialSize)
        }
        guard result == 0,
              credentialSize == socklen_t(MemoryLayout<BurnBarLinuxPeerSocketCredentials>.size) else {
            return nil
        }
        return credential.pid
        #else
        return nil
        #endif
    }

    private static func handleClientConnection(
        server: BurnBarDaemonServer,
        clientFileDescriptor: Int32,
        connectionGate: BurnBarConnectionGate,
        logger: BurnBarDaemonLogger
    ) async {
        defer {
            close(clientFileDescriptor)
            connectionGate.release()
        }

        BurnBarUnixDomainSocket.configureNoSigPipe(for: clientFileDescriptor)
        BurnBarUnixDomainSocket.configureIOTimeouts(for: clientFileDescriptor)

        let peerPID = Self.peerPID(for: clientFileDescriptor)

        // RR-3: authenticate the peer's first-party code signature on the live
        // socket BEFORE reading or honoring any RPC. Fail closed — a mismatched,
        // forged, or swapped peer binary never reaches `responseData`, so the
        // bearer token alone can no longer authorize a non-first-party process.
        let peerAuthenticator = server.peerAuthenticator
        let peerCapabilityProfile: BurnBarPeerCapabilityProfile
        do {
            peerCapabilityProfile = try peerAuthenticator.validatePeer(
                socketFD: clientFileDescriptor,
                peerPID: peerPID
            )
        } catch {
            logger.warning(
                "rpc_peer_rejected",
                metadata: [
                    "error": "\(error)",
                    "peer_pid": peerPID.map(String.init) ?? "unknown"
                ]
            )
            // Fail closed, but do not leave the client staring at Cocoa's
            // empty-body decode string. The envelope is unauthorized; the
            // app can then fall back to fleet-snapshot.json.
            let rejection = await server.encodeErrorResponse(
                id: "peer-rejected",
                code: BurnBarRPCErrorCode.unauthorized,
                message: "OpenBurnBar RPC peer failed first-party code-signature verification."
            ) + Data([0x0A])
            try? BurnBarUnixDomainSocket.writeAll(rejection, to: clientFileDescriptor)
            return
        }

        do {
            let requestData = try BurnBarUnixDomainSocket.readRequest(
                from: clientFileDescriptor,
                maxBytes: maxRequestBytes
            )
            let responseData = await server.responseData(
                for: requestData,
                peerPID: peerPID,
                peerCapabilityProfile: peerCapabilityProfile
            ) + Data([0x0A])
            try BurnBarUnixDomainSocket.writeAll(responseData, to: clientFileDescriptor)
            logger.debug(
                "rpc_response_sent",
                metadata: ["bytes": "\(responseData.count)"]
            )
        } catch {
            logger.error(
                "client_request_failed",
                metadata: ["error": "\(error)"]
            )
        }
    }
}
