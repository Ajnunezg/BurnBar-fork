import SwiftUI

extension ChatBackendID {
    /// Gradient fill for the active backend pill / hero emblem.
    var gradient: any ShapeStyle {
        switch self {
        case .hermes:
            return DesignSystem.Colors.mercuryGradient
        case .piAgent:
            return DesignSystem.Colors.piGradient
        case .codex, .claude, .openclaw, .openClaude, .omp, .droid, .forge, .antigravity, .cursorAgent, .junie, .fx, .grok, .kimi:
            return DesignSystem.Colors.accentGradient
        }
    }

    /// Foreground color rendered over the gradient fill.
    var activeForeground: Color {
        switch self {
        case .hermes: return Color(hex: "151210")
        default:      return .white
        }
    }
}
