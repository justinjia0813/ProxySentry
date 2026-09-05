import Foundation

/// Outcome of a single probe. Never carries payloads.
enum ProbeOutcome: Equatable, Sendable {
    case success
    case failure
    case timeout
    case unavailable
}

/// One sanitized piece of evidence: category, outcome, duration, user-facing note.
/// Raw configs, responses, secrets and subscription URLs must never be stored here.
struct ProbeEvidence: Equatable, Sendable {
    enum Category: String, Equatable, Sendable {
        case direct
        case proxy
        case node
        case alternateNode
        case localPort
        case clashVersion
        case clashConfigs
        case gateway
        case publicIP
        case dns
        case clashTraffic
    }

    let category: Category
    let outcome: ProbeOutcome
    let milliseconds: Int
    let userVisibleDescription: String
}

/// The finite inputs of one classification round. Flags, outcomes and whitelisted mode;
/// no addresses, keys, or raw Clash data.
struct NetworkSnapshot: Equatable, Sendable {
    var systemProxyConfigured = false
    var tunEnabled = false
    /// One outcome per direct probe target.
    var directOutcomes: [ProbeOutcome] = []
    /// One outcome per proxy probe target.
    var proxyOutcomes: [ProbeOutcome] = []
    var clashActiveProxyOutcome: ProbeOutcome?
    /// A fixed macOS proxy endpoint exists and can be checked locally. PAC and
    /// auto-discovery alone do not satisfy this because they are not resolved.
    var localProxyEndpointConfigured = false
    /// The proxy outcomes came through the configured macOS proxy route, rather
    /// than from a standalone Clash node health check.
    var proxyExitVerifiedThroughSystemRoute = false
    /// The proxy outcomes came through Clash's loopback mixed port. This is used
    /// only when PAC/auto-discovery hides the concrete macOS proxy endpoint.
    var proxyExitVerifiedThroughClashRoute = false
    var localProxyPortReachable = false
    var clashVersionOutcome: ProbeOutcome?
    var clashConfigsOutcome: ProbeOutcome?
    /// Configured system proxy port matches a reachable Clash listening port.
    var clashPortsMatchConfiguredProxy = false
    var clashInfoAvailable = false
    var clashMode: String?
    var pacConfigured = false
    var proxyAutoDiscovery = false
    var unrelatedLocalPortsListening = false
    /// Whether direct outcomes can be judged independently of a TUN interface.
    var directIndependentlyDecidable = true

    // MARK: Base-network layer

    /// Interface usable; nil when the path snapshot is unknown.
    var pathSatisfied: Bool? = nil
    /// Default gateway reachability; nil when not probed.
    var gatewayOutcome: ProbeOutcome? = nil
    /// One outcome per fixed public-IP probe (no DNS dependency).
    var publicIPOutcomes: [ProbeOutcome] = []
    /// DNS resolution outcome; nil when DNS was not exercised.
    var dnsOutcome: ProbeOutcome? = nil
    /// True when telemetry observed non-direct traffic through Clash; nil = no
    /// evidence. Absence is never treated as a failure.
    var clashTrafficObserved: Bool? = nil
    /// One outcome per same-provider alternate node probe (read-only latency).
    var alternateNodeOutcomes: [ProbeOutcome] = []
}

/// Five diagnosis states with symbol/color/title mappings.
struct DiagnosisState: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case green
        case blue
        case yellow
        case red
        case gray
    }

    let kind: Kind
    let symbolName: String
    /// Human-facing title. Never contains secrets or node lists.
    let title: String
    let missingEvidenceExplanation: String

    static let green = DiagnosisState(kind: .green, symbolName: "checkmark.shield.fill", title: "代理工作正常", missingEvidenceExplanation: "")
    static let greenClashExit = DiagnosisState(kind: .green, symbolName: "checkmark.shield.fill", title: "Clash 代理出口正常", missingEvidenceExplanation: "已验证 Clash 出口，系统自动代理规则尚未验证。")
    /// Independent green: telemetry confirms Clash is actually carrying proxy
    /// traffic while the node and kernel are healthy.
    static let greenTrafficActive = DiagnosisState(kind: .green, symbolName: "checkmark.shield.fill", title: "Clash 正在承载代理流量", missingEvidenceExplanation: "")
    static let blue = DiagnosisState(kind: .blue, symbolName: "shield.fill", title: "系统未使用代理，直连网络正常", missingEvidenceExplanation: "")
    static let blueNodeHealthy = DiagnosisState(kind: .blue, symbolName: "shield.fill", title: "代理节点正常，系统路由未确认", missingEvidenceExplanation: "系统代理路由未确认。")
    static let yellow = DiagnosisState(kind: .yellow, symbolName: "exclamationmark.shield.fill", title: "本机代理配置异常", missingEvidenceExplanation: "")
    static let red = DiagnosisState(kind: .red, symbolName: "xmark.shield.fill", title: "疑似机场或节点故障", missingEvidenceExplanation: "")
    static let gray = DiagnosisState(kind: .gray, symbolName: "questionmark.shield", title: "网络不可用或暂时无法定位", missingEvidenceExplanation: "")

    // Base-network conclusions. DNS misconfiguration is a computer-config issue
    // (yellow); local-network and external/ISP issues stay gray.
    static let yellowDnsConfig = DiagnosisState(kind: .yellow, symbolName: "exclamationmark.shield.fill", title: "电脑域名解析配置异常", missingEvidenceExplanation: "公网可达但域名解析失败。")
    static let grayExternal = DiagnosisState(kind: .gray, symbolName: "questionmark.shield", title: "外部网络或运营商异常", missingEvidenceExplanation: "网关可达但两个公网地址均失败。")
    static let grayLocalNetwork = DiagnosisState(kind: .gray, symbolName: "questionmark.shield", title: "本地网络或路由器异常", missingEvidenceExplanation: "网络接口不可用或网关与公网地址同时失败。")

    // Node conclusions (kind red).
    static let redCurrentNode = DiagnosisState(kind: .red, symbolName: "xmark.shield.fill", title: "当前代理节点异常", missingEvidenceExplanation: "当前节点失败但同机场备选节点正常。")
    static let redAirport = DiagnosisState(kind: .red, symbolName: "xmark.shield.fill", title: "疑似机场侧故障", missingEvidenceExplanation: "当前与备选节点均失败且直连和本地 Clash 正常。")
    static let redEntryDial = DiagnosisState(kind: .red, symbolName: "xmark.shield.fill", title: "节点假绿：疑似入口拨号失败", missingEvidenceExplanation: "节点延迟正常，但经 Clash 的两个真实外站探测均失败；可能是入口域名解析到失效地址。建议运行外部入口诊断脚本或联系机场；ProxySentry 未修改配置。")

    /// Short user-visible summary. Sanitized by construction.
    var summary: String {
        switch kind {
        case .green: return missingEvidenceExplanation.isEmpty ? "代理出口工作正常。" : missingEvidenceExplanation
        case .blue:
            return missingEvidenceExplanation.isEmpty
                ? "未使用代理，直连工作正常。"
                : "代理节点可用，但系统代理路由尚未确认。"
        case .yellow:
            return missingEvidenceExplanation.isEmpty
                ? "本地代理端口不可达或与 Clash 不匹配。"
                : missingEvidenceExplanation
        case .red:
            return missingEvidenceExplanation.isEmpty
                ? "Clash 运行正常但代理目标连续失败。"
                : missingEvidenceExplanation
        case .gray: return "证据不足：" + missingEvidenceExplanation
        }
    }

    static func == (lhs: DiagnosisState, rhs: DiagnosisState) -> Bool {
        lhs.kind == rhs.kind
            && lhs.missingEvidenceExplanation == rhs.missingEvidenceExplanation
    }
}

/// Pure classifier. Strict priority: green → blue → yellow → red → gray.
enum DiagnosisClassifier {

    static func classify(_ s: NetworkSnapshot) -> DiagnosisState {
        let hasProxyRoute = s.systemProxyConfigured || s.tunEnabled
        let directOK = s.directOutcomes.contains(.success)
        let publicOK = s.publicIPOutcomes.contains(.success)
        let proxyAllDown = s.proxyOutcomes.count >= 2
            && s.proxyOutcomes.allSatisfy { $0 == .failure || $0 == .timeout }
        let verifiedProxyRoute = (s.proxyExitVerifiedThroughSystemRoute && !s.pacConfigured)
            || s.proxyExitVerifiedThroughClashRoute

        // 1. Green first: a verified, working proxy exit is the strongest signal.
        if hasProxyRoute,
           s.proxyExitVerifiedThroughSystemRoute,
           s.proxyOutcomes.contains(.success) {
            return .green
        }

        // A real request through Clash also verifies its exit in rule mode.
        // Keep the unresolved macOS automatic route explicit in the result.
        if hasProxyRoute,
           s.proxyExitVerifiedThroughClashRoute,
           s.clashMode == "rule" || s.clashMode == "global",
           s.proxyOutcomes.contains(.success) {
            return .greenClashExit
        }

        // 1b. Independent green: telemetry observed non-direct traffic through
        //     Clash while the node and kernel are healthy. traffic=false/nil is
        //     never treated as a failure (it simply doesn't reach this branch).
        if s.clashTrafficObserved == true,
           !(verifiedProxyRoute && proxyAllDown),
           s.clashActiveProxyOutcome == .success,
           s.clashVersionOutcome == .success,
           s.clashConfigsOutcome == .success,
           s.clashInfoAvailable {
            return .greenTrafficActive
        }

        // 2. Base-network layer (PLAN §B/§C). Fires only on real base evidence;
        //    a single weak signal (e.g. one public-IP failure, gateway alone)
        //    is never enough to attribute.
        if let path = s.pathSatisfied, !path {
            return .grayLocalNetwork // interface unavailable
        }
        if publicOK, s.dnsOutcome == .failure || s.dnsOutcome == .timeout {
            return .yellowDnsConfig // public reachable but DNS fails → computer config issue
        }
        let publicAllDown = s.publicIPOutcomes.count >= 2
            && s.publicIPOutcomes.allSatisfy { $0 == .failure || $0 == .timeout }
        if !directOK, s.gatewayOutcome == .success, publicAllDown {
            return .grayExternal // gateway ok, both public targets fail
        }
        if !directOK,
           (s.gatewayOutcome == .failure || s.gatewayOutcome == .timeout), publicAllDown {
            return .grayLocalNetwork // gateway and public both down
        }

        // 3. Node anomaly conclusions. Only attribute when the current node probe
        //    actually failed AND there is alternate-node evidence.
        if s.clashActiveProxyOutcome == .failure || s.clashActiveProxyOutcome == .timeout {
            if s.alternateNodeOutcomes.contains(.success) {
                return .redCurrentNode
            }
            let alternatesAllDown = s.alternateNodeOutcomes.count >= 2
                && s.alternateNodeOutcomes.allSatisfy { $0 == .failure || $0 == .timeout }
            if alternatesAllDown,
               directOK,
               s.clashInfoAvailable,
               s.clashVersionOutcome == .success,
               s.clashConfigsOutcome == .success {
                return .redAirport
            }
        }

        // 4. A healthy node is independent from the macOS route. Report both facts
        //    without turning an unresolved PAC/auto-discovery route into an error.
        if !s.localProxyEndpointConfigured,
           !s.tunEnabled,
           s.directOutcomes.contains(.success),
           s.clashActiveProxyOutcome == .success {
            return .blueNodeHealthy
        }

        // 5. Blue: no proxy route at all, direct works.
        if !hasProxyRoute, s.directOutcomes.contains(.success) {
            return .blue
        }

        // 6. If direct can't be judged independently (e.g. active TUN), stop.
        //    The minimal-gap explanation below still accounts for a missing direct
        //    round, so no empty-direct short-circuit is needed here.
        guard s.directIndependentlyDecidable else {
            return grayState("虚拟网卡启用，无法独立判断直连。")
        }

        // The node delay API and a real request through Clash answer different
        // questions. A healthy delay with two failed real targets is a false
        // green: suspect entry-domain resolution/dialing, not local proxy setup.
        if hasProxyRoute,
           directOK,
           s.localProxyEndpointConfigured,
           s.localProxyPortReachable,
           s.clashPortsMatchConfiguredProxy,
           s.clashVersionOutcome == .success,
           s.clashConfigsOutcome == .success,
           s.clashInfoAvailable,
           verifiedProxyRoute,
           s.clashActiveProxyOutcome == .success,
           proxyAllDown {
            return .redEntryDial
        }

        // 7. Yellow: base network works but the configured local proxy is
        //    unreachable or local Clash/port mismatch.
        if hasProxyRoute, directOK, s.localProxyEndpointConfigured {
            if !s.localProxyPortReachable {
                return .yellow
            }
            if s.clashInfoAvailable && !s.clashPortsMatchConfiguredProxy {
                return .yellow
            }
            if s.proxyExitVerifiedThroughSystemRoute,
               s.clashActiveProxyOutcome == .success,
               !s.proxyOutcomes.contains(.success) {
                return .yellow
            }
        }

        // 8. Red: strict conjunction. Requires at least two proxy outcomes (one
        //    per probe target, all failing); the two-round confirmation itself is
        //    the controller's job, not the classifier's.
        if hasProxyRoute,
           s.directIndependentlyDecidable,
           directOK,
           s.localProxyPortReachable,
           s.clashPortsMatchConfiguredProxy,
           s.clashVersionOutcome == .success,
           s.clashConfigsOutcome == .success,
           s.clashInfoAvailable,
           verifiedProxyRoute,
           s.clashActiveProxyOutcome == .failure || s.clashActiveProxyOutcome == .timeout,
           proxyAllDown {
            return .red
        }

        // Gray: evidence insufficient. Explain the minimal gap.
        var gaps: [String] = []
        if !s.directOutcomes.contains(.success) && s.proxyOutcomes.isEmpty {
            gaps.append("直连与代理均无成功样本")
        } else if !s.directOutcomes.contains(.success) {
            gaps.append("直连全部失败")
        }
        if hasProxyRoute {
            if s.proxyOutcomes.isEmpty {
                gaps.append("缺少代理探测结果")
            } else if !s.proxyOutcomes.contains(.success),
                      !(s.clashVersionOutcome == .success && s.clashConfigsOutcome == .success) {
                gaps.append("Clash 信息不完整")
            }
            if !s.clashInfoAvailable {
                gaps.append("Clash 信息不可用")
            }
            if s.pacConfigured {
                gaps.append("PAC 未解析")
            }
        }
        if gaps.isEmpty {
            gaps.append("证据不足")
        }
        return grayState(gaps.prefix(2).joined(separator: "，") + "。")
    }

    private static func grayState(_ explanation: String) -> DiagnosisState {
        DiagnosisState(kind: .gray, symbolName: "questionmark.shield", title: "网络不可用或暂时无法定位", missingEvidenceExplanation: explanation)
    }
}

/// Buffers a single candidate diagnosis state and commits only after two
/// consecutive identical rounds (including recovery). A kind already committed is
/// not re-notified. Pure state machine: no clock injection.
struct StateDebouncer: Sendable {
    private(set) var pendingState: DiagnosisState?
    private(set) var pendingCount = 0
    private(set) var committedState: DiagnosisState?

    var pendingKind: DiagnosisState.Kind? { pendingState?.kind }
    var committedKind: DiagnosisState.Kind? { committedState?.kind }

    /// Feed one fresh round result.
    /// Returns the state to commit and notify now, or nil when nothing is confirmed.
    mutating func accept(_ state: DiagnosisState) -> DiagnosisState? {
        guard state != committedState else {
            pendingState = nil
            pendingCount = 0
            return nil
        }
        if state == pendingState {
            pendingCount += 1
        } else {
            pendingState = state
            pendingCount = 1
        }
        guard pendingCount >= 2 else { return nil }
        let shouldNotify = committedState != state
        committedState = state
        pendingState = nil
        pendingCount = 0
        return shouldNotify ? state : nil
    }
}
