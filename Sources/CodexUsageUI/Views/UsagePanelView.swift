import AppKit
import SwiftUI

public struct UsagePanelView: View {
    @ObservedObject var store: UsageStore
    @AppStorage("display.showUsageSummaryCard") private var storedShowUsageSummary = true
    @AppStorage("display.showRecentTasksCard") private var storedShowRecentTasks = true
    @AppStorage("display.showAPICostCard") private var storedShowAPICost = true
    @State private var isShowingSettings: Bool

    let tuning: GlassTuning
    private let preferencesEnabled: Bool
    private let onHeightChange: ((CGFloat) -> Void)?

    public init(
        store: UsageStore,
        tuning: GlassTuning,
        preferencesEnabled: Bool = true,
        settingsInitiallyPresented: Bool = false,
        onHeightChange: ((CGFloat) -> Void)? = nil
    ) {
        self.store = store
        self.tuning = tuning
        self.preferencesEnabled = preferencesEnabled
        self.onHeightChange = onHeightChange
        _isShowingSettings = State(initialValue: settingsInitiallyPresented)
    }

    private var showUsageSummary: Bool {
        preferencesEnabled ? storedShowUsageSummary : true
    }

    private var showRecentTasks: Bool {
        preferencesEnabled ? storedShowRecentTasks : true
    }

    private var showAPICost: Bool {
        preferencesEnabled ? storedShowAPICost : true
    }

    private var preferredHeight: CGFloat {
        UsagePanelMetrics.preferredHeight(
            showUsageSummary: showUsageSummary,
            showRecentTasks: showRecentTasks,
            showAPICost: showAPICost
        )
    }

    private var displayedHeight: CGFloat {
        isShowingSettings
            ? max(preferredHeight, UsagePanelMetrics.settingsMinimumHeight)
            : preferredHeight
    }

    public var body: some View {
        VStack(spacing: 12) {
            HeaderView(store: store, tuning: tuning, isShowingSettings: $isShowingSettings)
            if showUsageSummary {
                UsageSummaryCard(snapshot: store.snapshot, language: store.language, tuning: tuning)
            }
            if showRecentTasks {
                RecentTasksCard(tasks: store.snapshot.recentTasks, language: store.language, tuning: tuning)
            }
            if showAPICost {
                APICostEstimateCard(
                    estimate: store.snapshot.apiCostEstimate,
                    language: store.language,
                    tuning: tuning
                )
            }
            FooterView(snapshot: store.snapshot, language: store.language)
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 12)
        .frame(width: UsagePanelMetrics.width, height: displayedHeight)
        .background {
            BalancedPanelTint(tuning: tuning)
                .ignoresSafeArea()
        }
        .overlay {
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .stroke(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(0.38),
                            Color.white.opacity(0.08),
                            Color.black.opacity(0.12)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 0.8
                )
                .padding(0.4)
                .allowsHitTesting(false)
        }
        .overlay(alignment: .topTrailing) {
            if isShowingSettings {
                UsageSettingsCard(
                    showUsageSummary: $storedShowUsageSummary,
                    showRecentTasks: $storedShowRecentTasks,
                    showAPICost: $storedShowAPICost,
                    language: Binding(
                        get: { store.language },
                        set: { store.setLanguage($0) }
                    ),
                    tuning: tuning,
                    close: { isShowingSettings = false }
                )
                .padding(.top, 96)
                .padding(.trailing, 16)
                .transition(.move(edge: .top).combined(with: .opacity))
                .zIndex(10)
            }
        }
        .animation(.easeInOut(duration: 0.18), value: isShowingSettings)
        .animation(.easeInOut(duration: 0.18), value: preferredHeight)
        .onAppear {
            onHeightChange?(displayedHeight)
        }
        .onChange(of: displayedHeight) { _, newHeight in
            onHeightChange?(newHeight)
        }
        .task {
            await store.refresh()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                await store.refresh()
            }
        }
    }
}

private struct APICostEstimateCard: View {
    let estimate: APICostEstimateSnapshot?
    let language: AppLanguage
    let tuning: GlassTuning

    private var sevenDayValue: String {
        guard let estimate else { return "—" }
        return Self.currency(estimate.sevenDayUSD)
    }

    private var lifetimeValue: String {
        guard let value = estimate?.lifetimeUSD else { return "—" }
        return Self.currency(value)
    }

    private var modelText: String {
        guard let names = estimate?.modelNames, !names.isEmpty else { return language.noPricedModel }
        return names.joined(separator: " · ")
    }

    var body: some View {
        VStack(spacing: 9) {
            HStack(spacing: 7) {
                Image(systemName: "dollarsign.circle")
                    .font(.system(size: 15, weight: .semibold))
                Text(language.apiCostTitle)
                    .font(UsageDesign.font(15, weight: .bold, language: language))
                Spacer()
                Text(language.standardAPIRates)
                    .font(UsageDesign.font(10.5, weight: .medium, language: language))
                    .foregroundStyle(.secondary)
            }

            HStack(alignment: .firstTextBaseline) {
                Text(sevenDayValue)
                    .font(UsageDesign.font(25, weight: .bold, language: language))
                    .foregroundStyle(UsageDesign.blue)
                    .monospacedDigit()
                Text(language.metricSevenDays)
                    .font(UsageDesign.font(11.5, weight: .medium, language: language))
                    .foregroundStyle(.secondary)

                Spacer()

                VStack(alignment: .trailing, spacing: 2) {
                    Text(lifetimeValue)
                        .font(UsageDesign.font(15, weight: .bold, language: language))
                        .monospacedDigit()
                    Text(language.lifetimeCost)
                        .font(UsageDesign.font(10.5, language: language))
                        .foregroundStyle(.secondary)
                }
            }

            Divider()
                .opacity(0.32)

            HStack(spacing: 6) {
                Image(systemName: "cpu")
                    .font(.system(size: 11, weight: .medium))
                Text(modelText)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text(language.pricedCoverage(estimate?.coveragePercent ?? 0))
                    .monospacedDigit()
            }
            .font(UsageDesign.font(10.5, weight: .medium, language: language))
            .foregroundStyle(.secondary)

            Text(language.costDisclaimer)
                .font(UsageDesign.font(9.5, language: language))
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .lineLimit(2)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(GlassCardBackground(tuning: tuning))
    }

    private static func currency(_ value: Double) -> String {
        if value >= 1_000_000 {
            return String(format: "$%.2fM", value / 1_000_000)
        }
        if value >= 1_000 {
            return String(format: "$%.2fK", value / 1_000)
        }
        return String(format: "$%.2f", value)
    }
}

private struct HeaderView: View {
    @ObservedObject var store: UsageStore
    let tuning: GlassTuning
    @Binding var isShowingSettings: Bool

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(UsageDesign.blue.opacity(0.15))
                    .frame(width: 36, height: 36)
                Image(systemName: "gauge.with.dots.needle.67percent")
                    .font(.system(size: 21, weight: .semibold))
                    .foregroundStyle(UsageDesign.blue)
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 9) {
                    Text(store.language.appTitle)
                        .font(UsageDesign.font(20, weight: .bold, language: store.language))
                        .lineLimit(1)
                    Text(store.snapshot.planLabel)
                        .font(UsageDesign.font(11, weight: .bold, language: store.language))
                        .tracking(1.0)
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 6) {
                    Circle()
                        .fill(store.lastError == nil ? UsageDesign.green : Color.orange)
                        .frame(width: 8, height: 8)
                    Text(store.statusText)
                        .font(UsageDesign.font(13, language: store.language))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.78)
                }
            }

            Spacer(minLength: 8)

            HStack(spacing: 4) {
                Button {
                    Task { await store.refresh() }
                } label: {
                    ZStack {
                        Circle()
                            .fill(Color.white.opacity(0.14))
                            .frame(width: 34, height: 34)
                        if store.isRefreshing {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 16, weight: .medium))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .buttonStyle(.plain)
                .help(store.language.refreshUsage)
                .accessibilityHint(store.lastError ?? store.language.refreshFromAccountHint)

                Button {
                    isShowingSettings.toggle()
                } label: {
                    ZStack {
                        Circle()
                            .fill(Color.white.opacity(isShowingSettings ? 0.25 : 0.14))
                            .frame(width: 30, height: 30)
                        Image(systemName: isShowingSettings ? "gearshape.fill" : "gearshape")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(isShowingSettings ? UsageDesign.blue : Color.secondary)
                    }
                }
                .buttonStyle(.plain)
                .help(store.language.showSettings)
                .accessibilityLabel(store.language.showSettings)
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 70)
        .background(GlassCardBackground(tuning: tuning))
    }
}

private struct UsageSummaryCard: View {
    let snapshot: UsageSnapshot
    let language: AppLanguage
    let tuning: GlassTuning

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 0) {
                ForEach(Array(snapshot.periods.enumerated()), id: \.element.id) { index, period in
                    QuotaRow(period: period, language: language)
                    if index < snapshot.periods.count - 1 {
                        Divider()
                            .opacity(0.32)
                            .padding(.horizontal, 14)
                    }
                }
            }

            Divider()
                .opacity(0.38)

            HStack(spacing: 0) {
                ForEach(snapshot.metrics) { metric in
                    VStack(spacing: 4) {
                        Text(metric.value)
                            .font(UsageDesign.font(19, weight: .bold, language: language))
                            .monospacedDigit()
                        Text(metric.label)
                            .font(UsageDesign.font(12, weight: .medium, language: language))
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .frame(height: 79)
        }
        .background(GlassCardBackground(tuning: tuning))
    }
}

private struct QuotaRow: View {
    let period: UsagePeriod
    let language: AppLanguage

    var body: some View {
        VStack(spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(period.title)
                    .font(UsageDesign.font(16, weight: .bold, language: language))
                Spacer()
                Text("\(period.remainingPercent)%")
                    .font(UsageDesign.font(20, weight: .bold, language: language))
                    .foregroundStyle(UsageDesign.blue)
                    .monospacedDigit()
            }

            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.secondary.opacity(0.14))
                    Capsule()
                        .fill(UsageDesign.blue)
                        .frame(width: proxy.size.width * CGFloat(period.remainingPercent) / 100)
                }
            }
            .frame(height: 10)

            HStack {
                Text(language.remaining)
                Spacer()
                Text(period.resetText)
            }
            .font(UsageDesign.font(11.5, language: language))
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 13)
    }
}

private struct RecentTasksCard: View {
    let tasks: [RecentTask]
    let language: AppLanguage
    let tuning: GlassTuning

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "list.bullet.rectangle")
                    .font(.system(size: 15, weight: .semibold))
                Text(language.recentTasks)
                    .font(UsageDesign.font(15, weight: .bold, language: language))
                Spacer()
                Text(language.threadTotalTokens)
                    .font(UsageDesign.font(11, language: language))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.top, 13)
            .padding(.bottom, 9)

            ForEach(Array(tasks.enumerated()), id: \.element.id) { index, task in
                RecentTaskRow(task: task, language: language)
                if index < tasks.count - 1 {
                    Divider()
                        .opacity(0.30)
                        .padding(.horizontal, 14)
                }
            }
        }
        .background(GlassCardBackground(tuning: tuning))
    }
}

private struct RecentTaskRow: View {
    let task: RecentTask
    let language: AppLanguage

    var body: some View {
        VStack(spacing: 7) {
            HStack(alignment: .center, spacing: 10) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(task.title)
                        .font(UsageDesign.font(14, weight: .bold, language: language))
                        .lineLimit(1)
                    Text(task.time)
                        .font(UsageDesign.font(10.5, language: language))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Text(task.tokenText)
                    .font(UsageDesign.font(14.5, weight: .bold, language: language))
                    .foregroundStyle(UsageDesign.blue)
                    .monospacedDigit()
            }

            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Rectangle()
                        .fill(Color.secondary.opacity(0.10))
                    if task.progress > 0 {
                        Rectangle()
                            .fill(UsageDesign.blue.opacity(0.72))
                            .frame(width: proxy.size.width * task.progress)
                    }
                }
            }
            .frame(height: 2.5)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }
}

private struct FooterView: View {
    let snapshot: UsageSnapshot
    let language: AppLanguage

    private var updatedTime: String {
        let components = Calendar.current.dateComponents([.hour, .minute], from: snapshot.updatedAt)
        return String(format: "%02d:%02d", components.hour ?? 0, components.minute ?? 0)
    }

    var body: some View {
        HStack {
            Label(language.availableResets(snapshot.availableResets), systemImage: "clock.arrow.circlepath")
            Spacer()
            Text(language.updatedAt(updatedTime))
        }
        .font(UsageDesign.font(11.5, weight: .medium, language: language))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 4)
        .frame(height: 24)
        .contextMenu {
            Button(language.quitApplication) {
                NSApplication.shared.terminate(nil)
            }
        }
    }
}
