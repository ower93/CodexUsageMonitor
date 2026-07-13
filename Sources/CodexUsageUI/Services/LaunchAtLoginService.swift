import ServiceManagement

enum LaunchAtLoginState: Equatable {
    case disabled
    case enabled
    case requiresApproval

    var isOn: Bool {
        self != .disabled
    }
}

@MainActor
enum LaunchAtLoginService {
    static var state: LaunchAtLoginState {
        switch SMAppService.mainApp.status {
        case .enabled:
            return .enabled
        case .requiresApproval:
            return .requiresApproval
        default:
            return .disabled
        }
    }

    @discardableResult
    static func setEnabled(_ enabled: Bool) throws -> LaunchAtLoginState {
        let service = SMAppService.mainApp
        if enabled {
            switch service.status {
            case .notRegistered, .notFound:
                try service.register()
            case .enabled, .requiresApproval:
                break
            @unknown default:
                try service.register()
            }
        } else {
            switch service.status {
            case .enabled, .requiresApproval:
                try service.unregister()
            case .notRegistered, .notFound:
                break
            @unknown default:
                try service.unregister()
            }
        }
        return state
    }

    static func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
