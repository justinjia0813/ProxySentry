import Foundation

/// Pure, testable helpers for system-facing features. Every real system access
/// goes through an injected closure seam, so tests never touch notifications,
/// SMAppService, System Settings, the clipboard, LaunchAgent files, or launch a
/// real app. Unsigned builds are reported `unavailable` and never write a
/// LaunchAgent.
enum SystemServices {

    // MARK: - Notification dedup (pure)

    /// Notify only when the committed kind changes. Identical kinds are never
    /// re-notified; a recovery to green/blue is notified exactly once.
    static func shouldNotify(previous: DiagnosisState.Kind?, current: DiagnosisState.Kind) -> Bool {
        current != previous
    }

    /// Fire the notification seams when the kind changed. Authorization is
    /// fire-and-forget: a denial never throws into or stops the caller.
    static func notifyIfChanged(
        previous: DiagnosisState.Kind?,
        current: DiagnosisState.Kind,
        requestAuthorization: () -> Void,
        post: () -> Void
    ) {
        guard shouldNotify(previous: previous, current: current) else { return }
        requestAuthorization()
        post()
    }

    // MARK: - Login item four-state mapping (pure)

    enum LoginItemState: Equatable {
        case notRegistered
        case enabled
        case requiresApproval
        case notFound
        case unavailable // unsigned build
    }

    /// Mirror of SMAppService.Status, kept local so tests never call SMAppService.
    enum SMStatusMirror: Equatable {
        case notRegistered
        case enabled
        case requiresApproval
        case notFound
    }

    static func loginItemState(from status: SMStatusMirror) -> LoginItemState {
        switch status {
        case .notRegistered: return .notRegistered
        case .enabled: return .enabled
        case .requiresApproval: return .requiresApproval
        case .notFound: return .notFound
        }
    }

    // MARK: - Login registration decision (pure)

    enum RegistrationDecision: Equatable {
        case unavailable // unsigned build: never write a LaunchAgent
        case register
        case unregister
        case none
    }

    /// Decide the login-item action without touching the system.
    /// - `isSigned`: a valid code-signing identity is available.
    /// - `hasPreference`: `loginAtLaunchDesired` (or `loginRegistrationAttempted`)
    ///   has ever been stored.
    /// - `desired`: current `loginAtLaunchDesired`.
    /// - `registrationAttempted`: the `loginRegistrationAttempted` flag.
    static func resolveRegistration(
        isSigned: Bool,
        hasPreference: Bool,
        desired: Bool,
        registrationAttempted: Bool
    ) -> RegistrationDecision {
        guard isSigned else { return .unavailable }
        if !hasPreference {
            // First launch, no stored preference: stay disabled until opted in.
            return .none
        }
        if desired {
            return registrationAttempted ? .none : .register
        }
        return .unregister
    }

    // MARK: - UserDefaults keys (exactly these two)

    static let loginAtLaunchDesiredKey = "loginAtLaunchDesired"
    static let loginRegistrationAttemptedKey = "loginRegistrationAttempted"

    /// Read login preferences through a seam. Only the two whitelisted keys are
    /// touched. `hasPreference` is true when either key has ever been stored.
    static func readLoginPreferences(read: (String) -> Any?) -> (hasPreference: Bool, desired: Bool, attempted: Bool) {
        let desired = read(loginAtLaunchDesiredKey) as? Bool
        let attempted = read(loginRegistrationAttemptedKey) as? Bool
        return (desired != nil || attempted != nil, desired ?? false, attempted ?? false)
    }

    /// Persist login preferences through a seam. Only the two whitelisted keys.
    static func writeLoginPreference(desired: Bool, attempted: Bool, write: (String, Any) -> Void) {
        write(loginAtLaunchDesiredKey, desired)
        write(loginRegistrationAttemptedKey, attempted)
    }

    // MARK: - Copy summary whitelist (pure)

    private static func outcomeLabel(_ o: ProbeOutcome) -> String {
        switch o {
        case .success: return "成功"
        case .failure: return "失败"
        case .timeout: return "超时"
        case .unavailable: return "不可用"
        }
    }

    private static func categoryLabel(_ category: ProbeEvidence.Category) -> String {
        switch category {
        case .direct: return "直连"
        case .proxy: return "代理"
        case .node: return "代理节点"
        case .alternateNode: return "同机场备选节点"
        case .localPort: return "本地代理端口"
        case .clashVersion: return "Clash 内核"
        case .clashConfigs: return "Clash 配置"
        case .gateway: return "默认网关"
        case .publicIP: return "公网连接"
        case .dns: return "域名解析"
        case .clashTraffic: return "代理流量"
        }
    }

    /// Builds a copy-safe summary from whitelisted `DiagnosisState` /
    /// `ProbeEvidence` fields only. Never contains configs, secrets, subscription
    /// URLs, or node lists — the model types guarantee this by construction.
    static func copySummary(state: DiagnosisState, evidence: [ProbeEvidence]) -> String {
        var lines: [String] = [state.title]
        if !state.missingEvidenceExplanation.isEmpty {
            lines.append("原因：" + state.missingEvidenceExplanation)
        }
        for e in evidence {
            lines.append("\(categoryLabel(e.category))：\(outcomeLabel(e.outcome))（\(e.milliseconds)ms）\(e.userVisibleDescription)")
        }
        return lines.joined(separator: "\n")
    }
}
