import SwiftUI

public enum UsagePanelMetrics {
    public static let width: CGFloat = 370
    public static let height: CGFloat = 776
    public static let settingsMinimumHeight: CGFloat = 376

    public static func preferredHeight(
        showUsageSummary: Bool,
        showRecentTasks: Bool,
        showAPICost: Bool
    ) -> CGFloat {
        var result: CGFloat = 135
        if showUsageSummary {
            result += 271
        }
        if showRecentTasks {
            result += 223
        }
        if showAPICost {
            result += 147
        }
        return result
    }
}

enum UsageDesign {
    static let blue = Color(red: 0.0, green: 0.43, blue: 0.94)
    static let green = Color(red: 0.05, green: 0.72, blue: 0.34)

    static func font(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        let fontName = weight == .regular
            ? "STHeitiSC-Light"
            : "STHeitiSC-Medium"
        return .custom(fontName, size: size)
    }
}

struct GlassCardBackground: View {
    @Environment(\.colorScheme) private var colorScheme
    let tuning: GlassTuning

    var body: some View {
        RoundedRectangle(cornerRadius: 20, style: .continuous)
            .fill(.ultraThinMaterial)
            .opacity(tuning.cardMaterialPercent / 100)
            .overlay {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(
                        Color.white.opacity(
                            tuning.cardWhiteLayerPercent / 100 * (colorScheme == .dark ? 0.43 : 1)
                        )
                    )
            }
            .overlay {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .stroke(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(
                                    (colorScheme == .dark ? 0.18 : 0.32)
                                        * tuning.cardBorderPercent / 100
                                ),
                                Color.white.opacity(0.05 * tuning.cardBorderPercent / 100),
                                Color.black.opacity(
                                    (colorScheme == .dark ? 0.16 : 0.07)
                                        * tuning.cardBorderPercent / 100
                                )
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 0.7
                    )
            }
            .shadow(color: Color.black.opacity(0.07), radius: 5, y: 2)
    }
}

struct BalancedPanelTint: View {
    @Environment(\.colorScheme) private var colorScheme
    let tuning: GlassTuning

    var body: some View {
        ZStack {
            (colorScheme == .dark ? Color.black : Color.white)
                .opacity(
                    tuning.panelTintPercent / 100 * (colorScheme == .dark ? 1.5 : 1)
                )
            LinearGradient(
                colors: [
                    UsageDesign.blue.opacity(0.03 * tuning.panelGradientPercent / 100),
                    Color.clear,
                    Color.black.opacity(
                        (colorScheme == .dark ? 0.07 : 0.04)
                            * tuning.panelGradientPercent / 100
                    )
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
    }
}
