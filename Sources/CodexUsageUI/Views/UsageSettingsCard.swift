import SwiftUI

struct UsageSettingsCard: View {
    @Binding var showUsageSummary: Bool
    @Binding var showRecentTasks: Bool
    @Binding var showAPICost: Bool
    let tuning: GlassTuning
    let close: () -> Void

    @State private var launchAtLoginState = LaunchAtLoginService.state
    @State private var launchAtLoginError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 7) {
                Image(systemName: "gearshape.fill")
                    .foregroundStyle(UsageDesign.blue)
                Text("显示设置")
                    .font(UsageDesign.font(15, weight: .bold))
                Spacer()
                Button("全部显示") {
                    showUsageSummary = true
                    showRecentTasks = true
                    showAPICost = true
                }
                .buttonStyle(.plain)
                .font(UsageDesign.font(10.5, weight: .medium))
                .foregroundStyle(UsageDesign.blue)

                Button(action: close) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .frame(width: 22, height: 22)
                        .background(Circle().fill(Color.secondary.opacity(0.10)))
                }
                .buttonStyle(.plain)
                .help("关闭设置")
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("显示卡片")
                    .font(UsageDesign.font(10.5, weight: .medium))
                    .foregroundStyle(.secondary)

                SettingsToggleRow(
                    title: "额度与 Token 概览",
                    systemImage: "gauge.with.dots.needle.67percent",
                    isOn: $showUsageSummary
                )
                SettingsToggleRow(
                    title: "最近任务",
                    systemImage: "list.bullet.rectangle",
                    isOn: $showRecentTasks
                )
                SettingsToggleRow(
                    title: "Token 价值估算",
                    systemImage: "dollarsign.circle",
                    isOn: $showAPICost
                )
            }

            Divider()
                .opacity(0.35)

            VStack(alignment: .leading, spacing: 7) {
                Text("通用")
                    .font(UsageDesign.font(10.5, weight: .medium))
                    .foregroundStyle(.secondary)

                SettingsToggleRow(
                    title: "开机时启动",
                    systemImage: "power",
                    isOn: launchAtLoginBinding
                )

                if launchAtLoginState == .requiresApproval {
                    HStack(spacing: 6) {
                        Text("需要在系统设置中允许")
                        Spacer()
                        Button("前往设置") {
                            LaunchAtLoginService.openSystemSettings()
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(UsageDesign.blue)
                    }
                    .font(UsageDesign.font(9.5, weight: .medium))
                    .foregroundStyle(.secondary)
                }

                if let launchAtLoginError {
                    Text(launchAtLoginError)
                        .font(UsageDesign.font(9.5))
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
                    launchAtLoginError = "设置失败：\(error.localizedDescription)"
                }
            }
        )
    }
}

private struct SettingsToggleRow: View {
    let title: String
    let systemImage: String
    @Binding var isOn: Bool

    var body: some View {
        Button {
            isOn.toggle()
        } label: {
            HStack(spacing: 8) {
                Label(title, systemImage: systemImage)
                    .font(UsageDesign.font(12.5, weight: .medium))
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
        .accessibilityValue(isOn ? "已开启" : "已关闭")
        .animation(.easeInOut(duration: 0.16), value: isOn)
    }
}
