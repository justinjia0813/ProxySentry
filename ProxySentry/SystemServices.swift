import Foundation

/// Pure, testable helpers for system-facing features. Every real system access
/// goes through an injected closure seam, so tests never touch notifications,
/// SMAppService, System Settings, the clipboard, LaunchAgent files, or launch a
/// real app. Unsigned builds are reported `unavailable` and never write a
/// LaunchAgent.
enum SystemServices {

    static let agentStatusLifetime: TimeInterval = 120

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

    // MARK: - Agent-readable status snapshot

    private static func stateCode(_ kind: DiagnosisState.Kind) -> String {
        switch kind {
        case .green: return "green"
        case .blue: return "blue"
        case .yellow: return "yellow"
        case .red: return "red"
        case .gray: return "gray"
        }
    }

    private static func outcomeCode(_ outcome: ProbeOutcome) -> String {
        switch outcome {
        case .success: return "success"
        case .failure: return "failure"
        case .timeout: return "timeout"
        case .unavailable: return "unavailable"
        }
    }

    /// Stable, sanitized machine-readable output for a local Agent. The expiry
    /// prevents a stopped app's last result from being mistaken for live state.
    static func agentStatusJSON(
        state: DiagnosisState,
        evidence: [ProbeEvidence],
        checkedAt: Date
    ) throws -> Data {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let object: [String: Any] = [
            "schemaVersion": 1,
            "checkedAt": formatter.string(from: checkedAt),
            "expiresAt": formatter.string(from: checkedAt.addingTimeInterval(agentStatusLifetime)),
            "missingEvidence": "unknown",
            "diagnosis": [
                "state": stateCode(state.kind),
                "title": state.title,
                "summary": state.summary,
            ],
            "evidence": evidence.map {
                [
                    "category": $0.category.rawValue,
                    "outcome": outcomeCode($0.outcome),
                    "milliseconds": $0.milliseconds,
                    "description": $0.userVisibleDescription,
                ] as [String: Any]
            },
        ]
        return try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
    }

    @discardableResult
    static func writeAgentStatus(
        state: DiagnosisState,
        evidence: [ProbeEvidence],
        checkedAt: Date,
        to destination: URL? = nil
    ) throws -> URL {
        let fileManager = FileManager.default
        let url: URL
        if let destination {
            url = destination
        } else {
            guard let applicationSupport = fileManager.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first else {
                throw CocoaError(.fileNoSuchFile)
            }
            url = applicationSupport
                .appendingPathComponent("ProxySentry", isDirectory: true)
                .appendingPathComponent("agent-status.json", isDirectory: false)
        }
        let directory = url.deletingLastPathComponent()
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        try agentStatusJSON(state: state, evidence: evidence, checkedAt: checkedAt)
            .write(to: url, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return url
    }
}
