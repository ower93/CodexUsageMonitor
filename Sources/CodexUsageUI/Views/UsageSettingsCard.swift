import SwiftUI

struct UsageSettingsCard: View {
    @Binding var showUsageSummary: Bool
    @Binding var showRecentTasks: Bool
    @Binding var showAPICost: Bool
    @Binding var language: AppLanguage
    let tuning: GlassTuning
    let close: () -> Void

    @State private var launchAtLoginState = LaunchAtLoginService.state
    @State private var launchAtLoginError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 7) {
                Image(systemName: "gearshape.fill")
                    .foregroundStyle(UsageDesign.blue)
                Text(language.settingsTitle)
                    .font(UsageDesign.font(15, weight: .bold, language: language))
                Spacer()
                Button(language.showAll) {
                    showUsageSummary = true
                    showRecentTasks = true
                    showAPICost = true
                }
                .buttonStyle(.plain)
                .font(UsageDesign.font(10.5, weight: .medium, language: language))
                .foregroundStyle(UsageDesign.blue)

                Button(action: close) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .frame(width: 22, height: 22)
                        .background(Circle().fill(Color.secondary.opacity(0.10)))
                }
                .buttonStyle(.plain)
                .help(language.closeSettings)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text(language.cardsSection)
                    .font(UsageDesign.font(10.5, weight: .medium, language: language))
                    .foregroundStyle(.secondary)

                SettingsToggleRow(
                    title: language.usageSummaryCard,
                    systemImage: "gauge.with.dots.needle.67percent",
                    language: language,
                    isOn: $showUsageSummary
                )
                SettingsToggleRow(
                    title: language.recentTasks,
                    systemImage: "list.bullet.rectangle",
                    language: language,
                    isOn: $showRecentTasks
                )
                SettingsToggleRow(
                    title: language.costCard,
                    systemImage: "dollarsign.circle",
                    language: language,
                    isOn: $showAPICost
                )
            }

            Divider()
                .opacity(0.35)

            VStack(alignment: .leading, spacing: 7) {
                Text(language.generalSection)
                    .font(UsageDesign.font(10.5, weight: .medium, language: language))
                    .foregroundStyle(.secondary)

                LanguageSettingRow(language: $language)

                SettingsToggleRow(
                    title: language.launchAtLogin,
                    systemImage: "power",
                    language: language,
                    isOn: launchAtLoginBinding
                )

                if launchAtLoginState == .requiresApproval {
                    HStack(spacing: 6) {
                        Text(language.approvalRequired)
                        Spacer()
                        Button(language.openSettings) {
                            LaunchAtLoginService.openSystemSettings()
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(UsageDesign.blue)
                    }
                    .font(UsageDesign.font(9.5, weight: .medium, language: language))
                    .foregroundStyle(.secondary)
                }

                if let launchAtLoginError {
                    Text(launchAtLoginError)
                        .font(UsageDesign.font(9.5, language: language))
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(14)
        .frame(width: 306)
        .background {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(.regularMaterial)
            GlassCardBackground(tuning: tuning)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(Color.white.opacity(0.28), lineWidth: 0.8)
        }
        .shadow(color: Color.black.opacity(0.14), radius: 14, y: 8)
        .onAppear {
            launchAtLoginState = LaunchAtLoginService.state
        }
    }

    private var launchAtLoginBinding: Binding<Bool> {
        Binding(
            get: { launchAtLoginState.isOn },
            set: { newValue in
                do {
                    launchAtLoginState = try LaunchAtLoginService.setEnabled(newValue)
                    launchAtLoginError = nil
                } catch {
                    launchAtLoginState = LaunchAtLoginService.state
                    launchAtLoginError = language.settingsFailure(error.localizedDescription)
                }
            }
        )
    }
}

private struct SettingsToggleRow: View {
    let title: String
    let systemImage: String
    let language: AppLanguage
    @Binding var isOn: Bool

    var body: some View {
        Button {
            isOn.toggle()
        } label: {
            HStack(spacing: 8) {
                Label(title, systemImage: systemImage)
                    .font(UsageDesign.font(12.5, weight: .medium, language: language))
                Spacer()
                ZStack {
                    Capsule()
                        .fill(isOn ? UsageDesign.blue : Color.secondary.opacity(0.24))
                        .frame(width: 34, height: 19)
                    Circle()
                        .fill(Color.white)
                        .frame(width: 15, height: 15)
                        .shadow(color: Color.black.opacity(0.16), radius: 1, y: 0.5)
                        .offset(x: isOn ? 7.5 : -7.5)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityValue(
            isOn ? language.enabledAccessibilityValue : language.disabledAccessibilityValue
        )
        .animation(.easeInOut(duration: 0.16), value: isOn)
    }
}

private struct LanguageSettingRow: View {
    @Binding var language: AppLanguage

    var body: some View {
        HStack(spacing: 8) {
            Label(language.languageSetting, systemImage: "globe")
                .font(UsageDesign.font(12.5, weight: .medium, language: language))
            Spacer(minLength: 6)
            HStack(spacing: 3) {
                ForEach(AppLanguage.allCases) { option in
                    Button {
                        language = option
                    } label: {
                        Text(option.displayName)
                            .font(UsageDesign.font(9.5, weight: .medium, language: option))
                            .foregroundStyle(language == option ? Color.white : Color.secondary)
                            .padding(.horizontal, 7)
                            .frame(height: 22)
                            .background {
                                Capsule()
                                    .fill(language == option ? UsageDesign.blue : Color.secondary.opacity(0.10))
                            }
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(language == option ? .isSelected : [])
                }
            }
        }
    }
}
