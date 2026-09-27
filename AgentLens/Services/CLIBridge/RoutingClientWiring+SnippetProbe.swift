import Foundation

extension RoutingClientWiring {

    // MARK: - Snippet-mode wiring

    /// A copy/pasteable shell block that achieves the same wiring without
    /// touching any config file. Users on managed dotfiles or non-standard
    /// shells prefer this path. The snippet is always self-contained and can
    /// be pasted into `~/.zshrc`, `~/.bashrc`, or sourced ad-hoc.
    ///
    /// Tokens are emitted inside single quotes so `$`, backticks, double
    /// quotes, and backslashes pass through verbatim. Any literal `'` in
    /// the token is escaped with the standard `'\''` POSIX dance.
    func shellSnippet(
        target: RoutingClientWiringTarget,
        gateway: RoutingClientGateway
    ) -> String {
        let baseURL = Self.shellQuote(gateway.baseURL)
        let openAIBaseURL = Self.shellQuote("\(gateway.baseURL)/v1")
        let token = Self.shellQuote(gateway.effectiveClientToken)
        switch target {
        case .claudeCode:
            return """
            # OpenBurnBar — wire Claude Code through the local gateway
            export ANTHROPIC_BASE_URL=\(baseURL)
            export ANTHROPIC_AUTH_TOKEN=\(token)
            export CLAUDE_CODE_ENABLE_GATEWAY_MODEL_DISCOVERY=1
            export ANTHROPIC_CUSTOM_HEADERS=\(Self.shellQuote(Self.claudeCodeClientHeader))
            """
        case .codex:
            return """
            # OpenBurnBar — wire Codex CLI through the local gateway
            # OpenBurnBar Settings -> Agents -> CLIs writes
            # ~/.codex/openburnbar.config.toml and a merged model catalog so:
            #   codex exec --profile openburnbar --model openburnbar/<model> "..."
            # works with the local gateway.
            export OPENAI_BASE_URL=\(openAIBaseURL)
            export OPENAI_API_KEY=\(token)
            export OPENBURNBAR_GATEWAY_TOKEN=\(token)
            """
        case .opencode:
            return """
            # OpenBurnBar — wire OpenCode CLI through the local gateway
            # The Settings -> Agents -> CLIs Connect button adds provider.openburnbar to
            # ~/.config/opencode/opencode.json.
            export OPENBURNBAR_GATEWAY_TOKEN=\(token)
            export OPENAI_BASE_URL=\(openAIBaseURL)
            export OPENAI_API_KEY=\(token)
            """
        case .forge:
            return """
            # OpenBurnBar — wire Forge CLI through the local gateway
            # The Settings -> Agents -> CLIs Connect button adds a Forge provider named `openburnbar`
            # at ~/forge/.forge.toml. This env var supplies its api_key_var.
            export OPENBURNBAR_GATEWAY_TOKEN=\(token)
            export OPENAI_BASE_URL=\(openAIBaseURL)
            export OPENAI_API_KEY=\(token)
            """
        case .droid:
            return """
            # OpenBurnBar — wire Droid CLI through the local gateway
            # In OpenBurnBar Settings -> Agents -> CLIs, press Connect + Sync
            # or Sync models to write live BurnBar models under ~/.factory/.
            export OPENBURNBAR_GATEWAY_TOKEN=\(token)
            export OPENAI_BASE_URL=\(openAIBaseURL)
            export OPENAI_API_KEY=\(token)
            """
            let models = advertisedModels.isEmpty
                ? await self.advertisedModels(gateway: gateway, session: session, timeoutSeconds: timeoutSeconds)
                : advertisedModels
            guard let liveModel = firstXAIGatewayServedModel(models) else {
                return .failed(
                    status: 503,
                    message: RoutingClientWiringTarget.grok.missingRouteReadyAccountMessage,
                    modelID: nil,
                    providerID: nil
                )
            }
            probeModel = liveModel.id
            probeProviderID = liveModel.providerID
            body = [
                "model": probeModel,
                "max_completion_tokens": 1,
                "messages": [["role": "user", "content": "ping"]]
            ]
        case .opencode, .forge, .droid:
            let models = advertisedModels.isEmpty
                ? await self.advertisedModels(gateway: gateway, session: session, timeoutSeconds: timeoutSeconds)
                : advertisedModels
            // P2: `.first` after provider-name sort is not a health oracle.
            // Skip local-CLI executors when any HTTP provider is advertised
            // so Droid / Forge / OpenCode do not ping Codex/Factory by default.
            guard let liveModel = preferredOpenAICompatProbeModel(models, target: target) else {
                return .failed(
                    status: 503,
                    message: "No route-eligible gateway models are advertised by /v1/models.",
                    modelID: nil,
                    providerID: nil
                )
            }
            probeModel = liveModel.id
            probeProviderID = liveModel.providerID
            // OpenAI Chat Completions deprecated `max_tokens` for reasoning-
            // capable models in favor of `max_completion_tokens`. The
            // gateway's structured-executor tests use `max_completion_tokens`
            // (OpenBurnBarHTTPGatewayServerTests.swift:258), so we match.
            body = [
                "model": probeModel,
                "max_completion_tokens": 1,
                "messages": [["role": "user", "content": "ping"]]
            ]
        }

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        } catch {
            return .failed(
                status: 0,
                message: "could not encode probe body: \(error.localizedDescription)",
                modelID: probeModel,
                providerID: probeProviderID
            )
        }

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return .failed(
                    status: 0,
                    message: "missing HTTP response",
                    modelID: probeModel,
                    providerID: probeProviderID
                )
            }
            if (200..<300).contains(http.statusCode) {
                return .ok(modelID: probeModel)
            }
            let bodyText = String(data: data, encoding: .utf8)?.prefix(200) ?? ""
            return .failed(
                status: http.statusCode,
                message: String(bodyText),
                modelID: probeModel,
                providerID: probeProviderID
            )
        } catch {
            return .failed(
                status: 0,
                message: error.localizedDescription,
                modelID: probeModel,
                providerID: probeProviderID
            )
        }
    }

    func firstXAIGatewayServedModel(
        _ advertisedModels: [RoutingClientAdvertisedModel]
    ) -> RoutingClientAdvertisedModel? {
        gatewayServedModels(advertisedModels, target: .grok).first { model in
            model.providerID.caseInsensitiveCompare("xai") == .orderedSame
        }
    }

    /// Local-CLI executors that advertise OpenAI-compat rows and sort first
    /// on a default install. A generic Chat Completions health ping must not
    /// treat those rows as readiness when any HTTP provider is advertised —
    /// that is how a Droid / Forge / OpenCode card showed a missing-`codex`
    /// 503 (#2616 P2). Grok stays on `firstXAIGatewayServedModel` (P1).
    static let localCLIExecutorProviderIDs: Set<String> = ["codex", "factory"]

    static func isLocalCLIExecutorProvider(_ providerID: String) -> Bool {
        localCLIExecutorProviderIDs.contains(
            providerID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        )
    }

    /// Prefer an HTTP-provider row for generic OpenAI-compat probes. When
    /// the catalog is local-CLI only, keep the first remaining row so a
    /// Codex-only ping still carries P0 model + provider attribution.
    func preferredOpenAICompatProbeModel(
        _ advertisedModels: [RoutingClientAdvertisedModel],
        target: RoutingClientWiringTarget
    ) -> RoutingClientAdvertisedModel? {
        let served = gatewayServedModels(advertisedModels, target: target)
        let httpModels = served.filter { !Self.isLocalCLIExecutorProvider($0.providerID) }
        return httpModels.first ?? served.first
    }

    // MARK: - Private helpers

    func assertGatewayConfigured(_ gateway: RoutingClientGateway) throws {
        if gateway.host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw RoutingClientWiringError.gatewayMisconfigured(detail: "Gateway host is empty.")
        }
        if gateway.port <= 0 || gateway.port > 65_535 {
            throw RoutingClientWiringError.gatewayMisconfigured(detail: "Gateway port \(gateway.port) is out of range.")
        }
        if gateway.authToken.isEmpty && !gateway.isLoopbackHost {
            throw RoutingClientWiringError.gatewayMisconfigured(
                detail: "A non-loopback gateway needs an auth token. Generate one under Settings → Daemon → HTTP gateway before wiring a client."
            )
        }
    }

    private func probeURL(target: RoutingClientWiringTarget, gateway: RoutingClientGateway) -> URL? {
        let base = URL(string: gateway.baseURL)
        switch target {
        case .antigravity:
            return nil
        case .cursorAgent:
            return nil
        case .claudeCode:
            return base?.appending(path: "v1/messages")
        case .codex:
            return base?.appending(path: "v1/responses")
        case .opencode, .forge, .droid, .grok:
            return base?.appending(path: "v1/chat/completions")
        }
    }
}
