import Foundation
import OpenBurnBarKernel

// MARK: - Prompt Token Arbiter (G9)
//
// One token-aware budget arbiter over the whole augmented system prompt. Prior to
// this, `augmentedSystem` was a bare concatenation of independently char-capped
// sections with NO aggregate cap, so a future memory-injection section (F-2) would
// silently become an unbounded seventh block and starve the user's own turn / tool
// definitions on small-context backends (ollama, unknown local models).
//
// The arbiter estimates each section via `TokenExtractionUtility.estimatedTokenCount`,
// reserves a hard floor for the conversation history + user turn (subtracted from the
// model's context window before the system-prompt budget is computed), guarantees the
// persona (`.core`) and tool definitions (`.toolDefs`) are never dropped, carves a
// shared retrieval pool for evidence + memory (memory subtracts, it never appends an
// uncapped block), and drops/truncates lowest-priority sections first. A conservative
// floor is applied for `ollama` and unknown local backends.
//
// Priority keep order (G9): user turn > tool defs > focus > evidence > memory > volatile rollups.
// The user turn is reserved out of the context window (not a section here); within the
// system prompt, persona (`.core`) is sacred and `.toolDefs` is never dropped. Memory
// is never concatenated into `.core` (G8) — it is its own section sharing the pool.

/// A labeled, priority-ranked section of the augmented system prompt.
struct PromptTokenSection: Sendable, Equatable {
    /// Section identity. The case order documents keep-priority within the prompt
    /// (earlier cases are retained preferentially when the budget is exhausted); the
    /// arbiter implements that order explicitly in `assemble(_:)`.
    enum ID: String, Sendable, CaseIterable, Equatable {
        /// Trusted persona + identity + index-health. Never dropped; recalled memory
        /// is never concatenated into this region (G8).
        case core
        /// Workspace + desktop-control tool definitions. Never dropped (G9).
        case toolDefs
        /// Pinned focus transcript.
        case focus
        /// Retrieved RAG evidence. Shares a pool with `.memory`.
        case evidence
        /// Recalled memory snippets (F-2). Shares a pool with `.evidence`; subtracts
        /// from the shared pool, capped at `memoryBudget`.
        case memory
        /// Volatile local usage rollups and latest assistant snippet. Lowest priority.
        case rollups
    }

    let id: ID
    let content: String
}

/// Token-aware budget arbiter for the augmented system prompt (G9). Pure value type
/// — fully testable without a DataStore or live backend.
struct PromptTokenArbiter {
    /// Conservative full context-window assumption per model family. Deliberately
    /// conservative (not vendor maxima) so the system prompt never crowds the user
    /// turn + history on small / local backends.
    static func assumedContextWindow(for model: HermesModelID?) -> Int {
        switch model {
        case .ollama:   return 8_192    // local; user-configurable, assume the small default
        case nil:       return 8_192    // unknown / local backend — conservative floor
        default:        return 128_000  // cloud families (codex/claude/zai/kimi/minimax)
        }
    }

    /// Hard ceiling on the augmented system prompt so even huge-context cloud models
    /// do not assemble a runaway prompt.
    static func systemPromptCeiling(for model: HermesModelID?) -> Int {
        switch model {
        case .ollama, nil: return 3_072   // ~37% of an 8k window; leaves room for history+turn+output
        default:           return 24_576  // cloud; generous but bounded
        }
    }

    /// Minimum floor for the augmented system prompt budget (core persona + tool defs
    /// must always fit). Prevents pathological under-allocation when history is huge.
    private static func systemPromptFloor(for model: HermesModelID?) -> Int {
        switch model {
        case .ollama, nil: return 1_536
        default:           return 8_192
        }
    }

    /// Fraction of the shared evidence+memory pool reserved for memory. Memory
    /// subtracts from the shared pool (it never appends an uncapped block).
    static let memoryPoolFraction: Double = 0.25

    /// Fraction of the context window reserved for model output (completion).
    private static let outputReserveFraction: Double = 0.25
    private static let minOutputReserve: Int = 1_024

    /// Tokens reserved for join separators + truncation markers so the assembled
    /// prompt stays within the budget after the final join.
    private static let assemblyOverheadTokens: Int = 64

    /// Truncation marker appended to any section trimmed to fit.
    private static let truncationMarker = "\n…[section truncated to respect prompt token budget]"

    let augmentedSystemBudget: Int
    let memoryBudget: Int
    let charsPerTokenProse: Double
    let charsPerTokenCode: Double

    private init(
        augmentedSystemBudget: Int,
        memoryBudget: Int,
        charsPerTokenProse: Double,
        charsPerTokenCode: Double
    ) {
        self.augmentedSystemBudget = augmentedSystemBudget
        self.memoryBudget = memoryBudget
        self.charsPerTokenProse = charsPerTokenProse
        self.charsPerTokenCode = charsPerTokenCode
    }

    /// Build an arbiter for the given model family, after reserving tokens for the
    /// conversation history + user turn and a slice for model output.
    static func make(
        model: HermesModelID?,
        historyAndUserTurnTokens: Int,
        systemWrapperTokens: Int = 0,
        memoryPoolFraction: Double = PromptTokenArbiter.memoryPoolFraction
    ) -> PromptTokenArbiter {
        let window = assumedContextWindow(for: model)
        let outputReserve = max(Self.minOutputReserve, Int(Double(window) * Self.outputReserveFraction))
        let availableForSystem = max(
            0,
            window - outputReserve - max(0, historyAndUserTurnTokens) - max(0, systemWrapperTokens)
        )
        let ceiling = systemPromptCeiling(for: model)
        let floor = systemPromptFloor(for: model)
        let capped = min(ceiling, availableForSystem)
        let augmentedSystemBudget = availableForSystem >= floor ? max(floor, capped) : capped
        let clampedFraction = min(1.0, max(0.0, memoryPoolFraction))
        let memoryBudget = Int(Double(augmentedSystemBudget) * clampedFraction)
        return PromptTokenArbiter(
            augmentedSystemBudget: augmentedSystemBudget,
            memoryBudget: memoryBudget,
            charsPerTokenProse: 3.5,
            charsPerTokenCode: 2.8
        )
    }

    struct AssembledPrompt: Sendable, Equatable {
        /// The budget-compliant system prompt.
        let systemPrompt: String
        /// Estimated token count of `systemPrompt` (sum of per-section estimates +
        /// join separators), using prose/code ratios per section kind.
        let estimatedTokens: Int
        /// Sections dropped entirely (empty content or zero remaining budget).
        let droppedSections: [PromptTokenSection.ID]
        /// Sections truncated to fit the budget.
        let truncatedSections: [PromptTokenSection.ID]
        /// Tokens reserved for memory within the shared evidence+memory pool.
        let memoryBudget: Int
        /// The per-model augmented-system budget the arbiter enforced.
        let augmentedSystemBudget: Int
    }

    /// Assemble the sections into a single budget-compliant system prompt.
    ///
    /// `.core` (persona) and `.toolDefs` are always included in full. `.focus` is kept
    /// in full if it fits, else truncated, else dropped. `.evidence` and `.memory` share
    /// the remaining pool; evidence has keep-priority over memory, and memory is capped
    /// at `memoryBudget`. If `.core` + `.toolDefs` alone exceed the budget they are
    /// still included (identity and tools are sacred) — the breach is reported via the
    /// returned diagnostics rather than silently dropping them.
    func assemble(_ sections: [PromptTokenSection]) -> AssembledPrompt {
        let sectionMap = Dictionary(sections.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let core = sectionMap[.core]?.content ?? ""
        let toolDefs = sectionMap[.toolDefs]?.content ?? ""
        let focus = sectionMap[.focus]?.content ?? ""
        let evidence = sectionMap[.evidence]?.content ?? ""
        let memory = sectionMap[.memory]?.content ?? ""
        let rollups = sectionMap[.rollups]?.content ?? ""

        var dropped: [PromptTokenSection.ID] = []
        var truncated: [PromptTokenSection.ID] = []

        let effectiveBudget = max(0, augmentedSystemBudget - Self.assemblyOverheadTokens)

        let coreTokens = estimate(core, .prose)
        let toolDefsTokens = estimate(toolDefs, .code)
        let guaranteed = coreTokens + toolDefsTokens

        // `.focus` is kept before the shared evidence+memory pool (priority order).
        var remaining = max(0, effectiveBudget - guaranteed)
        let focusResult = fit(content: focus, kind: .prose, budget: remaining)
        let focusUsed = focusResult.kept
        remaining -= estimate(focusUsed, .prose)
        recordOutcome(focusResult.outcome, .focus, truncated: &truncated, dropped: &dropped)

        // Shared pool: evidence has keep-priority over memory, then volatile
        // rollups. Lower-priority sections subtract instead of appending uncapped.
        let sharedPool = remaining
        let evidenceResult = fit(content: evidence, kind: .prose, budget: sharedPool)
        let evidenceUsed = evidenceResult.kept
        let evidenceUsedTokens = estimate(evidenceUsed, .prose)
        recordOutcome(evidenceResult.outcome, .evidence, truncated: &truncated, dropped: &dropped)

        let memoryRemaining = max(0, sharedPool - evidenceUsedTokens)
        let memoryCap = min(memoryBudget, memoryRemaining)
        let memoryResult = fit(content: memory, kind: .prose, budget: memoryCap)
        let memoryUsed = memoryResult.kept
        recordOutcome(memoryResult.outcome, .memory, truncated: &truncated, dropped: &dropped)

        let rollupRemaining = max(0, memoryRemaining - estimate(memoryUsed, .prose))
        let rollupResult = fit(content: rollups, kind: .prose, budget: rollupRemaining)
        let rollupsUsed = rollupResult.kept
        recordOutcome(rollupResult.outcome, .rollups, truncated: &truncated, dropped: &dropped)

        // Stable assembly order: persona, evidence, memory, volatile rollups,
        // focus, tool definitions.
        var parts: [String] = []
        var tokenSum = 0
        func appendPart(_ content: String, _ kind: ContentKind) {
            guard !content.isEmpty else { return }
            parts.append(content)
            tokenSum += estimate(content, kind)
        }
        appendPart(core, .prose)
        appendPart(evidenceUsed, .prose)
        appendPart(memoryUsed, .prose)
        appendPart(rollupsUsed, .prose)
        appendPart(focusUsed, .prose)
        appendPart(toolDefs, .code)

        let separatorCount = max(0, parts.count - 1)
        tokenSum += estimate(String(repeating: "\n\n", count: separatorCount), .prose)
        let systemPrompt = parts.joined(separator: "\n\n")

        return AssembledPrompt(
            systemPrompt: systemPrompt,
            estimatedTokens: tokenSum,
            droppedSections: dropped,
            truncatedSections: truncated,
            memoryBudget: memoryBudget,
            augmentedSystemBudget: augmentedSystemBudget
        )
    }

    // MARK: - Fitting helpers

    private enum FitOutcome: Equatable {
        case keptWhole
        case truncated
        case dropped
    }

    private struct FitResult: Equatable {
        let kept: String
        let outcome: FitOutcome
    }

    private enum ContentKind {
        case prose
        case code
    }

    private func ratioFor(_ kind: ContentKind) -> Double {
        switch kind {
        case .prose: return charsPerTokenProse
        case .code:  return charsPerTokenCode
        }
    }

    static func estimateProseTokens(_ content: String) -> Int {
        TokenExtractionUtility.estimatedTokenCount(for: content.count, charsPerToken: 3.5)
    }

    static func estimateCodeTokens(_ content: String) -> Int {
        TokenExtractionUtility.estimatedTokenCount(for: content.count, charsPerToken: 2.8)
    }

    private func estimate(_ content: String, _ kind: ContentKind) -> Int {
        TokenExtractionUtility.estimatedTokenCount(for: content.count, charsPerToken: ratioFor(kind))
    }

    private func recordOutcome(
        _ outcome: FitOutcome,
        _ id: PromptTokenSection.ID,
        truncated: inout [PromptTokenSection.ID],
        dropped: inout [PromptTokenSection.ID]
    ) {
        switch outcome {
        case .keptWhole:
            break
        case .truncated:
            truncated.append(id)
        case .dropped:
            dropped.append(id)
        }
    }

    /// Fit `content` into `budget` tokens. Kept whole if it fits; truncated if the
    /// budget is non-trivial; dropped (empty) if the budget is too small to be useful.
    private func fit(content: String, kind: ContentKind, budget: Int) -> FitResult {
        if content.isEmpty {
            return FitResult(kept: "", outcome: .keptWhole)
        }
        let tokens = estimate(content, kind)
        if tokens <= budget {
            return FitResult(kept: content, outcome: .keptWhole)
        }
        let minUsefulTokens = 32
        if budget <= minUsefulTokens {
            return FitResult(kept: "", outcome: .dropped)
        }
        return FitResult(kept: truncate(content: content, kind: kind, toTokens: budget), outcome: .truncated)
    }

    /// Truncate `content` so its estimate is ≤ `tokens` tokens, appending a marker.
    /// `totalMaxChars = floor(tokens * ratio)` keeps the post-truncation estimate at
    /// or below the token budget (ceil(floor(tokens*ratio)/ratio) ≤ tokens).
    private func truncate(content: String, kind: ContentKind, toTokens tokens: Int) -> String {
        let marker = Self.truncationMarker
        let totalMaxChars = max(0, Int((Double(tokens) * ratioFor(kind)).rounded(.down)))
        if content.count <= totalMaxChars {
            return content
        }
        // Reserve room for the truncation marker AND the worst-case reseal footer (close
        // tag + CRITICAL RULE) when this section carries wrapped untrusted blocks, so the
        // re-sealed + marked result still honors `tokens`. A prefix cut can leave at most
        // the final block unterminated, so one footer is the worst case. Non-wrapped
        // sections reserve only the marker.
        let resealReserve = content.contains(LLMSafeContent.untrustedOpenMarker)
            ? "\n\(LLMSafeContent.untrustedCloseMarker)\n\(LLMSafeContent.criticalRule)".count
            : 0
        let bodyMax = max(0, totalMaxChars - marker.count - resealReserve)
        // Re-seal any `<UNTRUSTED_CONTENT>` block whose close tag was severed by the raw
        // prefix cut, so budget-driven truncation cannot break the G8 wrap invariant: an
        // unterminated untrusted block would otherwise absorb the trusted sections
        // assembled after `.memory`/`.evidence` (tool defs, persona). No-op when the cut
        // landed on a balanced boundary or on a section with no wrappers.
        let sealedBody = LLMSafeContent.resealTruncatedUntrusted(String(content.prefix(bodyMax)))
        return sealedBody + marker
    }
}
