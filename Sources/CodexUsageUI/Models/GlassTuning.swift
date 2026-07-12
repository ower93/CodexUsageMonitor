public struct GlassTuning: Sendable {
    public static let final = GlassTuning(
        backgroundBlurPercent: 44,
        panelTintPercent: 51,
        panelGradientPercent: 100,
        cardMaterialPercent: 59,
        cardWhiteLayerPercent: 36,
        cardBorderPercent: 100
    )

    public let backgroundBlurPercent: Double
    public let panelTintPercent: Double
    public let panelGradientPercent: Double
    public let cardMaterialPercent: Double
    public let cardWhiteLayerPercent: Double
    public let cardBorderPercent: Double

    private init(
        backgroundBlurPercent: Double,
        panelTintPercent: Double,
        panelGradientPercent: Double,
        cardMaterialPercent: Double,
        cardWhiteLayerPercent: Double,
        cardBorderPercent: Double
    ) {
        self.backgroundBlurPercent = backgroundBlurPercent
        self.panelTintPercent = panelTintPercent
        self.panelGradientPercent = panelGradientPercent
        self.cardMaterialPercent = cardMaterialPercent
        self.cardWhiteLayerPercent = cardWhiteLayerPercent
        self.cardBorderPercent = cardBorderPercent
    }
}
