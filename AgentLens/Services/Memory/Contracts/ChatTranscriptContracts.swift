import Foundation

/// Read seam the extractor needs from the control-plane store: the transcript for a
/// job's thread. Narrow on purpose so the extractor is decoupled from the full store
/// surface and testable with a fake.
///
/// A thread id carrying `AgentConversationExtractionSource.threadIDPrefix` resolves
/// against the `conversations` table (the 28-agent corpus) instead of `chat_messages`
/// (BurnBar's own chat panel). The store owns that branch so the extractor and the
/// provenance-recomputing worker read through one seam.
protocol ChatExtractionTranscriptReading: Sendable {
    func fetchChatTranscriptForExtraction(threadID: String) async throws -> [ChatTranscriptMessage]
}

// MARK: - Agent-conversation extraction source

/// Identity + transcript mapping for memory extraction sourced from the indexed
/// AGENT CORPUS (`conversations` table) rather than BurnBar's own chat panel.
///
/// This is the wire the product thesis runs on: BurnBar observes every agent's
/// sessions, and extraction learns from them — not only from conversations the
/// user had with BurnBar itself. Encoding the source in the job's thread id keeps
/// the v50 `memory_extraction_jobs` schema untouched; the prefix is namespaced so
/// no real chat thread id can collide with it.
enum AgentConversationExtractionSource {
    static let threadIDPrefix = "agent-conversation:"
    /// Prompt-identity for conversation-sourced extraction. Distinct from the chat
    /// prompt version so re-extraction policies can evolve independently.
    static let promptVersion = "agent-conversation-v1"

    static func threadID(forConversationID conversationID: String) -> String {
        threadIDPrefix + conversationID
    }

    static func conversationID(fromThreadID threadID: String) -> String? {
        guard threadID.hasPrefix(threadIDPrefix) else { return nil }
        let id = String(threadID.dropFirst(threadIDPrefix.count))
        return id.isEmpty ? nil : id
    }

    static func turnID(conversationID: String, index: Int) -> String {
        "\(conversationID)#turn-\(index)"
    }

    /// Split an indexed conversation's `fullText` into citable turns.
    ///
    /// The parsers render turns as markdown headed by `## You` (Claude family via
    /// `SessionLogMarkdownFormatter`), `## User` (Codex), or `## Assistant`. Text
    /// before the first heading — or a transcript with no headings at all (several
    /// parsers store plain concatenated text) — becomes one user-role turn, so
    /// every provider's transcript stays extractable even when its shape is
    /// unknown. Deterministic: the same `fullText` always yields the same turn
    /// ids, which is what lets the worker re-resolve citations for provenance.
    static func splitTranscript(
        conversationID: String,
        fullText: String,
        anchoredAt: Date
    ) -> [ChatTranscriptMessage] {
        let trimmed = fullText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return [] }

        var turns: [(role: String, body: String)] = []
        var currentRole: String?
        var currentLines: [String] = []
        var sawHeading = false

        func flush() {
            guard currentRole != nil || currentLines.isEmpty == false else { return }
            let body = currentLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if body.isEmpty == false {
                turns.append((role: currentRole ?? "user", body: body))
            }
            currentLines = []
        }

        for line in trimmed.split(separator: "\n", omittingEmptySubsequences: false) {
            let heading = line.trimmingCharacters(in: .whitespaces)
            switch heading {
            case "## You", "## User":
                flush()
                sawHeading = true
                currentRole = "user"
            case "## Assistant":
                flush()
                sawHeading = true
                currentRole = "assistant"
            default:
                currentLines.append(String(line))
            }
        }
        flush()

        guard turns.isEmpty == false else { return [] }

        // Providers whose `fullText` carries no role headings would otherwise
        // become ONE turn holding the entire conversation. The prompt renderer
        // truncates a single oversized turn from its head, so every later
        // re-extraction would keep re-reading the same oldest slice and the
        // durable facts a growing session accumulates would stay permanently
        // out of the prompt. Chunking on line boundaries keeps the whole
        // transcript addressable and lets the renderer's newest-first budget do
        // its job.
        if sawHeading == false, turns.count == 1 {
            turns = Self.chunkUnheadedBody(turns[0].body).map { (role: "user", body: $0) }
        }

        return turns.enumerated().map { index, turn in
            ChatTranscriptMessage(
                id: turnID(conversationID: conversationID, index: index),
                role: turn.role,
                body: turn.body,
                authoredAt: anchoredAt
            )
        }
    }

    /// Split an unheaded transcript into stable, bounded turns on line
    /// boundaries. Deterministic: the same text always yields the same chunks,
    /// so re-extraction collapses onto the same turn ids.
    static let maxUnheadedTurnChars = 4_000

    static func chunkUnheadedBody(_ body: String) -> [String] {
        guard body.count > maxUnheadedTurnChars else { return [body] }
        var chunks: [String] = []
        var current: [String] = []
        var currentCount = 0
        for line in body.split(separator: "\n", omittingEmptySubsequences: false) {
            let cost = line.count + 1
            if currentCount + cost > maxUnheadedTurnChars, current.isEmpty == false {
                chunks.append(current.joined(separator: "\n"))
                current = []
                currentCount = 0
            }
            current.append(String(line))
            currentCount += cost
        }
        if current.isEmpty == false {
            chunks.append(current.joined(separator: "\n"))
        }
        return chunks.filter { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false }
    }
}

/// One transcript message the extractor reasons over and the worker later cites. The
/// `body` is the canonical text the citation's `contentHash` will be computed from.
struct ChatTranscriptMessage: Sendable, Equatable {
    let id: String
    let role: String
    let body: String
    let authoredAt: Date
}
