import SwiftUI

extension DashboardUsageViewModel {
    var moodColor: Color {
        switch moodBand {
        case .light: return DesignSystem.Colors.success
        case .onPace: return DesignSystem.Colors.textSecondary
        case .heavy: return DesignSystem.Colors.warning
        case .baseline, .quiet: return DesignSystem.Colors.textMuted
        }
    }
}
