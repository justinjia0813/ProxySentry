import Foundation

/// Serializes every diagnosis trigger through a single AsyncStream that buffers
/// only the newest pending event. At most one diagnosis round runs at a time;
/// triggers arriving mid-run coalesce into at most one follow-up. Every pending
/// candidate (healthy, anomaly, or recovery) is confirmed by a second round
/// before it can commit. Each round runs under an eight-second budget that
/// cancels unfinished work. Committed results are published on the main actor.
///
/// Injection points are closures only, no protocols:
/// - `sleep` time seam (scheduling tests);
/// - `diagnose` Kind seam (scheduling/debounce tests);
/// - `round` seam (full integration: state + evidence + Clash summary);
/// - `makeRound` assembles a round from fixed snapshots and probe closures.
///
/// Production wiring (real SystemNetwork / NetworkProbes / ClashReader sources)
/// is intentionally left as an injected runner seam: the AppDelegate owns how the
/// path snapshot is obtained and how probe/clash closures are built, so this type
/// stays decoupled from those (still-changing) sources.
final class DiagnosticsController {

    // MARK: - Round model (sanitized, published to the UI)

    /// Optional non-sensitive Clash summary. Never carries the secret,
    /// subscription URLs, node lists, or raw responses.
    struct ClashSummary: Equatable, Sendable {
        var version: String?
        var mode: String?
        var selectedGroup: String?
        var delay: Int?
    }

    /// Sanitized Clash read for one round: booleans plus a whitelisted summary.
    struct ClashRead: Equatable, Sendable {
        var versionOk: Bool
        var configsOk: Bool
        var infoAvailable: Bool
        var localPortMatchesConfiguredProxy: Bool
        var summary: ClashSummary
        var activeProxyProbe: NetworkProbes.ProbeOutput? = nil
        var tunEnabled = false
        /// True when /connections telemetry observed non-direct traffic; nil = no
        /// evidence. Absence is never treated as a failure.
        var trafficObserved: Bool? = nil
        /// Read-only outcome per same-provider alternate node probe.
        var alternateNodeProbes: [NetworkProbes.ProbeOutput] = []
    }

    /// The complete sanitized result of one round: the classified state,
    /// whitelisted evidence, and an optional Clash summary.
    struct DiagnosisRound: Equatable, Sendable {
        var state: DiagnosisState
        var evidence: [ProbeEvidence]
        var clashSummary: ClashSummary?
    }

    private let lock = NSLock()
    private let sleep: @Sendable (Duration) async throws -> Void
    private let round: @Sendable () async -> DiagnosisRound
    private let onUpdate: @MainActor @Sendable () -> Void
    private let onCommit: @MainActor @Sendable (DiagnosisState?, DiagnosisState) -> Void

    private static let recheckDelay = Duration.seconds(2)
    private static let budget = Duration.seconds(8)

    private let triggers: AsyncStream<Void>
    private let triggerContinuation: AsyncStream<Void>.Continuation
    private var consumer: Task<Void, Never>?
    private var debouncer = StateDebouncer()

    // Observable state, guarded by `lock`. Commit writes also hop to the main actor.
    private var _committedKind: DiagnosisState.Kind?
    private var _committedState: DiagnosisState?
    private var _pendingCandidate: DiagnosisState.Kind?
    private var _activeDiagnoses = 0
    private var _maxConcurrentDiagnoses = 0
    private var _diagnoseCallCount = 0
    private var _recheckCount = 0
    private var _lastCheckedAt: Date?
    private var _latestEvidence: [ProbeEvidence] = []
    private var _latestClashSummary: ClashSummary?

    var committedKind: DiagnosisState.Kind? { lock.withLock { _committedKind } }
    var committedState: DiagnosisState? { lock.withLock { _committedState } }
    var pendingCandidate: DiagnosisState.Kind? { lock.withLock { _pendingCandidate } }
    var isChecking: Bool { lock.withLock { _activeDiagnoses > 0 } }
    var lastCheckedAt: Date? { lock.withLock { _lastCheckedAt } }
    var evidence: [ProbeEvidence] { lock.withLock { _latestEvidence } }
    var clashSummary: ClashSummary? { lock.withLock { _latestClashSummary } }
    var activeDiagnoses: Int { lock.withLock { _activeDiagnoses } }
    var maxConcurrentDiagnoses: Int { lock.withLock { _maxConcurrentDiagnoses } }
    var diagnoseCallCount: Int { lock.withLock { _diagnoseCallCount } }
    var recheckCount: Int { lock.withLock { _recheckCount } }

    /// Scheduling/debounce seam (existing tests): a round that yields only a Kind.
    init(
        sleep: @escaping @Sendable (Duration) async throws -> Void,
        diagnose: @escaping @Sendable () async -> DiagnosisState.Kind,
        onUpdate: @escaping @MainActor @Sendable () -> Void = {},
        onCommit: @escaping @MainActor @Sendable (DiagnosisState?, DiagnosisState) -> Void = { _, _ in }
    ) {
        self.sleep = sleep
        self.round = { DiagnosisRound(state: Self.state(for: await diagnose()), evidence: [], clashSummary: nil) }
        self.onUpdate = onUpdate
        self.onCommit = onCommit
        (triggers, triggerContinuation) = AsyncStream.makeStream(
            of: Void.self,
            bufferingPolicy: .bufferingNewest(1)
        )
    }

    /// Full integration seam: `round` yields the complete sanitized result.
    init(
        sleep: @escaping @Sendable (Duration) async throws -> Void,
        round: @escaping @Sendable () async -> DiagnosisRound,
        onUpdate: @escaping @MainActor @Sendable () -> Void = {},
        onCommit: @escaping @MainActor @Sendable (DiagnosisState?, DiagnosisState) -> Void = { _, _ in }
    ) {
        self.sleep = sleep
        self.round = round
        self.onUpdate = onUpdate
        self.onCommit = onCommit
        (triggers, triggerContinuation) = AsyncStream.makeStream(
            of: Void.self,
            bufferingPolicy: .bufferingNewest(1)
        )
    }

    /// Unified entry point for timer ticks, path/proxy changes, wake, and manual recheck.
    func trigger() {
        triggerContinuation.yield(())
    }

    /// Begin consuming triggers. One-shot lifecycle: call once, before `stop()`.
    /// Calling `start()` again after `stop()` is intentionally a no-op — the
    /// controller is not restartable.
    func start() {
        guard consumer == nil else { return }
        let stream = triggers
        consumer = Task { [weak self] in
            for await _ in stream {
                guard !Task.isCancelled else { break }
                await self?.runRound()
            }
        }
    }

    /// Cancel cleanly: an in-flight diagnosis is cancelled and late results are
    /// not committed. Permanently terminates the stream; triggers yielded after
    /// this are dropped. One-shot lifecycle — there is no restart path.
    func stop() {
        consumer?.cancel()
        triggerContinuation.finish()
    }

    // MARK: - Round assembly (fixed snapshots + concurrent probes)

    /// Assemble one diagnosis round from fixed snapshots and injected probe reads.
    ///
    /// The system snapshots are read FIRST and synchronously, then pinned for the
    /// whole round: a proxy/path change mid-round cannot mix endpoints because
    /// `runLocal`/`runProxy`/`readClash` all receive the same pinned `FixedProxy`.
    /// The necessary probes run concurrently. Classification stays entirely in
    /// `DiagnosisClassifier`, so its strict red threshold and green/blue priority
    /// apply unchanged.
    static func makeRound(
        pathSnapshot: @escaping @Sendable () -> PathSnapshot,
        proxySnapshot: @escaping @Sendable () -> ProxySnapshot,
        dnsResolves: @escaping @Sendable (String) async -> Bool,
        runDirect: @escaping @Sendable () async -> [NetworkProbes.ProbeOutput],
        runLocal: @escaping @Sendable (FixedProxy?) async -> NetworkProbes.ProbeOutput,
        runProxy: @escaping @Sendable (FixedProxy) async -> [NetworkProbes.ProbeOutput],
        readClash: @escaping @Sendable (FixedProxy?) async -> ClashRead,
        gatewayProbe: @escaping @Sendable () async -> NetworkProbes.ProbeOutput = {
            NetworkProbes.ProbeOutput(outcome: .unavailable, failureCategory: nil, milliseconds: 0)
        },
        publicIPProbes: @escaping @Sendable () async -> [NetworkProbes.ProbeOutput] = { [] }
    ) async -> DiagnosisRound {
        // 1. Pin system state before any probe so the round never mixes endpoints.
        let path = pathSnapshot()
        let proxy = proxySnapshot()
        let webProxy = proxy.httpsProxy ?? proxy.httpProxy
        let localProxy = webProxy ?? proxy.socksProxy

        // 2. Run the necessary probes concurrently.
        async let dnsOK: Bool = path.supportsDNS ? dnsResolves("apple.com.cn") : false
        async let directOut: [NetworkProbes.ProbeOutput] = runDirect()
        async let localOut: NetworkProbes.ProbeOutput = runLocal(localProxy)
        async let clashRead: ClashRead = readClash(localProxy)
        async let proxyExit: [NetworkProbes.ProbeOutput] = {
            guard let fp = webProxy else { return [] }
            return await runProxy(fp)
        }()
        async let gatewayOut: NetworkProbes.ProbeOutput = gatewayProbe()
        async let publicOut: [NetworkProbes.ProbeOutput] = publicIPProbes()

        let clash = await clashRead
        let (dns, direct, local, fixedProxyOut, gateway, publics) =
            await (dnsOK, directOut, localOut, proxyExit, gatewayOut, publicOut)
        let proxyOut = fixedProxyOut

        // 3. Whitelisted evidence only (existing categories; no raw payloads).
        var evidence: [ProbeEvidence] = []
        if !clash.tunEnabled {
            for p in direct {
                evidence.append(ProbeEvidence(
                    category: .direct, outcome: Self.outcome(from: p),
                    milliseconds: p.milliseconds,
                    userVisibleDescription: Self.description(for: p, path: "直连")))
            }
        }
        for p in proxyOut {
            evidence.append(ProbeEvidence(
                category: .proxy, outcome: Self.outcome(from: p),
                milliseconds: p.milliseconds,
                userVisibleDescription: Self.description(for: p, path: "代理出口")))
        }
        if let node = clash.activeProxyProbe {
            evidence.append(ProbeEvidence(
                category: .node, outcome: Self.outcome(from: node),
                milliseconds: node.milliseconds,
                userVisibleDescription: Self.description(for: node, path: "当前代理节点")))
        }
        if localProxy != nil {
            evidence.append(ProbeEvidence(
                category: .localPort, outcome: Self.outcome(from: local),
                milliseconds: local.milliseconds,
                userVisibleDescription: Self.description(for: local, path: "本地代理端口")))
        }
        if proxy.hasAnyProxyPath || clash.infoAvailable {
            evidence.append(ProbeEvidence(
                category: .clashVersion, outcome: clash.versionOk ? .success : .unavailable,
                milliseconds: 0,
                userVisibleDescription: clash.versionOk ? "Clash 内核运行正常" : "Clash 内核详情不可用"))
            evidence.append(ProbeEvidence(
                category: .clashConfigs, outcome: clash.configsOk ? .success : .unavailable,
                milliseconds: 0,
                userVisibleDescription: clash.configsOk ? "Clash 配置读取正常" : "Clash 配置详情不可用"))
        }
        if path.supportsDNS && !dns && !clash.tunEnabled {
            evidence.append(ProbeEvidence(
                category: .dns, outcome: .failure,
                milliseconds: 0, userVisibleDescription: "域名解析失败"))
        }
        if gateway.outcome != .unavailable {
            evidence.append(ProbeEvidence(
                category: .gateway, outcome: Self.outcome(from: gateway),
                milliseconds: gateway.milliseconds,
                userVisibleDescription: Self.description(for: gateway, path: "默认网关")))
        }
        for p in publics {
            evidence.append(ProbeEvidence(
                category: .publicIP, outcome: Self.outcome(from: p),
                milliseconds: p.milliseconds,
                userVisibleDescription: Self.description(for: p, path: "公网地址")))
        }
        if clash.trafficObserved == true {
            evidence.append(ProbeEvidence(
                category: .clashTraffic, outcome: .success,
                milliseconds: 0, userVisibleDescription: "Clash 正在承载代理流量"))
        }
        for p in clash.alternateNodeProbes {
            evidence.append(ProbeEvidence(
                category: .alternateNode, outcome: Self.outcome(from: p),
                milliseconds: p.milliseconds,
                userVisibleDescription: Self.description(for: p, path: "备选节点")))
        }

        // 4. Finite snapshot for the pure classifier.
        var snap = NetworkSnapshot()
        snap.systemProxyConfigured = proxy.hasAnyProxyPath
        snap.tunEnabled = clash.tunEnabled
        snap.directOutcomes = clash.tunEnabled ? [] : direct.map { Self.outcome(from: $0) }
        snap.proxyOutcomes = proxyOut.map { Self.outcome(from: $0) }
        snap.clashActiveProxyOutcome = clash.activeProxyProbe.map { Self.outcome(from: $0) }
        snap.localProxyEndpointConfigured = localProxy != nil
        snap.proxyExitVerifiedThroughSystemRoute = webProxy != nil
        snap.localProxyPortReachable = local.outcome == .success
        snap.clashVersionOutcome = clash.versionOk ? .success : .failure
        snap.clashConfigsOutcome = clash.configsOk ? .success : .failure
        snap.clashPortsMatchConfiguredProxy = clash.localPortMatchesConfiguredProxy
        snap.clashInfoAvailable = clash.infoAvailable
        snap.pacConfigured = proxy.pacConfigured
        snap.proxyAutoDiscovery = proxy.autoDiscovery
        snap.directIndependentlyDecidable = !clash.tunEnabled
        // Base-network layer.
        snap.pathSatisfied = path.satisfied
        snap.gatewayOutcome = gateway.outcome != .unavailable ? Self.outcome(from: gateway) : nil
        snap.publicIPOutcomes = publics.map { Self.outcome(from: $0) }
        snap.dnsOutcome = path.supportsDNS ? (dns ? .success : .failure) : nil
        snap.clashTrafficObserved = clash.trafficObserved
        snap.alternateNodeOutcomes = clash.alternateNodeProbes.map { Self.outcome(from: $0) }

        let state = DiagnosisClassifier.classify(snap)
        return DiagnosisRound(
            state: state,
            evidence: evidence,
            clashSummary: clash.infoAvailable ? clash.summary : nil
        )
    }

    private static func state(for kind: DiagnosisState.Kind) -> DiagnosisState {
        switch kind {
        case .green: return .green
        case .blue: return .blue
        case .yellow: return .yellow
        case .red: return .red
        case .gray: return .gray
        }
    }

    private static func outcome(from p: NetworkProbes.ProbeOutput) -> ProbeOutcome {
        switch p.outcome {
        case .success: return .success
        case .failure: return .failure
        case .timeout: return .timeout
        case .unavailable: return .unavailable
        }
    }

    private static func description(for p: NetworkProbes.ProbeOutput, path: String) -> String {
        if p.outcome == .success { return path + "可用" }
        let detail: String
        switch p.failureCategory {
        case .resolutionFailed: detail = "域名解析失败"
        case .connectionRefused: detail = "连接被拒绝"
        case .timeout: detail = "检测超时"
        case .badStatus: detail = "返回状态异常"
        case .oversizedResponse: detail = "响应超过安全上限"
        case .transport: detail = "连接失败"
        case nil: detail = p.outcome == .unavailable ? "暂时无法检测" : "检测失败"
        }
        return path + detail
    }

    // MARK: - Rounds

    private func runRound() async {
        guard !Task.isCancelled else { return }
        await performOneDiagnosis()
        guard !Task.isCancelled else { return }
        // StateDebouncer requires two consecutive identical rounds to commit ANY
        // kind — healthy boot, anomaly, or recovery — so every pending candidate
        // is confirmed once after a short delay. A round that committed leaves no
        // pending candidate and is not rechecked.
        if pendingCandidate != nil {
            do {
                try await sleep(Self.recheckDelay)
                lock.withLock { _recheckCount += 1 }
            } catch {
                return // cancelled during the recheck wait
            }
            guard !Task.isCancelled else { return }
            await performOneDiagnosis()
        }
    }

    private func performOneDiagnosis() async {
        lock.withLock {
            _activeDiagnoses += 1
            _maxConcurrentDiagnoses = max(_maxConcurrentDiagnoses, _activeDiagnoses)
            _diagnoseCallCount += 1
        }
        await onUpdate()

        let result = await runWithinBudget(Self.budget) { await self.round() }

        lock.withLock { _activeDiagnoses -= 1 }
        await onUpdate()

        // A cancelled run must never commit a late result.
        guard !Task.isCancelled else { return }
        guard let round = result else { return } // budget elapsed; probes cancelled; no evidence

        // Feed the debouncer. It commits only on the second consecutive round.
        let kind = round.state.kind
        let changedState = debouncer.accept(round.state)
        let committed = debouncer.pendingKind == nil // commit resets pending to nil

        var previousState: DiagnosisState?
        if committed {
            previousState = await MainActor.run {
                self.lock.withLock {
                    let previous = self._committedState
                    self._committedKind = kind
                    self._committedState = round.state
                    return previous
                }
            }
        }
        // Publish latest round evidence/summary/timestamp regardless of commit.
        lock.withLock {
            _pendingCandidate = debouncer.pendingKind
            _latestEvidence = round.evidence
            _latestClashSummary = round.clashSummary
            _lastCheckedAt = Date()
        }
        if changedState != nil {
            await onCommit(previousState, round.state)
        }
        await onUpdate()
    }

    // MARK: - Budget race

    private enum BudgetOutcome<Value> {
        case value(Value)
        case exceeded
    }

    /// Runs `work` under a wall-clock budget, returning its value if it finishes
    /// first and `nil` (treated as timeout) if the budget wins.
    ///
    /// Tie-break policy: the budget task and the work task race on
    /// `group.next()`, which returns whichever finishes first. When the budget
    /// result is observed first, the round is a timeout and `work` is cancelled
    /// — even if `work` happened to complete at the same instant. Exact-deadline
    /// ties deliberately resolve to timeout; we never favor a borderline result
    /// over the budget.
    ///
    /// IMPORTANT INVARIANT: the budget bounds the round only when `work` (and
    /// therefore the diagnose/probes closures) honors `Task.isCancelled`.
    /// `withTaskGroup` does not return until every child settles, so a probe
    /// that ignores cancellation blocks the consumer loop beyond the budget.
    private func runWithinBudget<Value>(
        _ budget: Duration,
        _ work: @escaping @Sendable () async -> Value
    ) async -> Value? {
        let outcome: BudgetOutcome<Value> = await withTaskGroup(
            of: BudgetOutcome<Value>.self
        ) { group in
            group.addTask { .value(await work()) }
            group.addTask {
                do {
                    try await self.sleep(budget)
                } catch {
                    // Cancelled wait (work finished first): not a timeout.
                }
                return .exceeded
            }
            guard let first = await group.next() else { return .exceeded }
            group.cancelAll()
            return first
        }
        if case .value(let value) = outcome {
            return value
        }
        return nil
    }
}

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T {
        lock()
        defer { unlock() }
        return body()
    }
}
