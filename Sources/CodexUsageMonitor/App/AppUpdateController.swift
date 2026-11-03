import AppKit
import Sparkle

/// No feed or key is invented for local builds. A configured distributable
/// must use HTTPS, a pinned Ed25519 key, and pre-extraction verification.
@MainActor
final class AppUpdateController {
    private var controller: SPUStandardUpdaterController?

    init(bundle: Bundle = .main, enabled: Bool = true) {
        guard enabled,
              let rawURL = bundle.object(forInfoDictionaryKey: "SUFeedURL") as? String,
              let url = URL(string: rawURL), url.scheme == "https", url.host != nil,
              let publicKey = bundle.object(forInfoDictionaryKey: "SUPublicEDKey") as? String,
              Data(base64Encoded: publicKey)?.count == 32,
              bundle.object(forInfoDictionaryKey: "SUVerifyUpdateBeforeExtraction") as? Bool == true,
              bundle.object(forInfoDictionaryKey: "SURequireSignedFeed") as? Bool == true
        else { return }
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
    }

    func menuItem(english: Bool) -> NSMenuItem {
        guard let controller else {
            let item = NSMenuItem(title: english ? "Updates not configured (local build)" : "尚未配置更新（本机构建）", action: nil, keyEquivalent: "")
            item.isEnabled = false
            return item
        }
        let item = NSMenuItem(title: english ? "Check for Updates…" : "检查更新…",
                              action: #selector(SPUStandardUpdaterController.checkForUpdates(_:)), keyEquivalent: "")
        item.target = controller
        return item
    }
}
