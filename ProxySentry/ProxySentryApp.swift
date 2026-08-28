import AppKit
import Security
import ServiceManagement
import SwiftUI
@preconcurrency import UserNotifications

@main
struct ProxySentryApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings { EmptyView() }
    }
}

private final class TriggerRelay: @unchecked Sendable {
    private let lock = NSLock()
    private weak var controller: DiagnosticsController?

    func attach(_ controller: DiagnosticsController) {
        lock.lock(); self.controller = controller; lock.unlock()
    }

    func trigger() {
        lock.lock(); let controller = controller; lock.unlock()
        controller?.trigger()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let model = ProxySentryViewModel()
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private var controller: DiagnosticsController?
    private var pathObserver: PathObserver?
    private var proxyObserver: ProxyObserver?
    private var timerTask: Task<Void, Never>?

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard NSClassFromString("XCTestCase") == nil else { return }

        let relay = TriggerRelay()
        let pathObserver = PathObserver { relay.trigger() }
        let proxyObserver = ProxyObserver { relay.trigger() }

        let controller = DiagnosticsController(
            sleep: { try await Task.sleep(for: $0) },
            round: {
                await DiagnosticsController.makeRound(
                    pathSnapshot: { pathObserver.current },
                    proxySnapshot: { SystemNetwork.currentProxies() },
                    dnsResolves: { await NetworkProbes.systemResolver($0) },
                    runDirect: { await NetworkProbes.runDirectProbes() },
                    runLocal: { proxy in
                        guard let proxy, let port = UInt16(exactly: proxy.port) else {
                            return NetworkProbes.ProbeOutput(
                                outcome: .unavailable,
                                failureCategory: nil,
                                milliseconds: 0
                            )
                        }
                        return await NetworkProbes.localPortProbe(host: proxy.host, port: port)
                    },
                    runProxy: { await NetworkProbes.runProxyProbes(via: $0) },
                    readClash: { await Self.readClash(fixedProxy: $0) },
                    gatewayProbe: {
                        await NetworkProbes.gatewayProbe(gateway: SystemNetwork.defaultGateway()) {
                            await NetworkProbes.pingGateway($0)
                        }
                    },
                    publicIPProbes: { await NetworkProbes.runPublicIPProbes() }
                )
            },
            onUpdate: { [weak self] in self?.refreshFromController() },
            onCommit: { [weak self] previous, current in
                self?.postNotification(previous: previous, current: current)
            }
        )

        self.controller = controller
        self.pathObserver = pathObserver
        self.proxyObserver = proxyObserver
        relay.attach(controller)

        configurePopover()
        configureStatusItem()
        configureLoginItem()

        controller.start()
        pathObserver.start()
        proxyObserver.start()
        controller.trigger()

        timerTask = Task { [weak controller] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(60)) }
                catch { break }
                controller?.trigger()
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        timerTask?.cancel()
        pathObserver?.stop()
        proxyObserver?.stop()
        controller?.stop()
    }

    func applicationDidResignActive(_ notification: Notification) {
        popover?.performClose(nil)
    }

    private func configurePopover() {
        popover = NSPopover()
        popover.contentSize = NSSize(width: 320, height: 408)
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(rootView: StatusPopoverView(
            model: model,
            onRecheck: { [weak self] in self?.controller?.trigger() },
            onOpenClash: { [weak self] in self?.openClash() },
            onCopySummary: { [weak self] in self?.copySummary() },
            onLoginChanged: { [weak self] in self?.setLoginAtLaunch($0) },
            onOpenLoginSettings: { SMAppService.openSystemSettingsLoginItems() },
            onQuit: { NSApplication.shared.terminate(nil) }
        ))
    }

    private func configureStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            button.action = #selector(togglePopover(_:))
            button.target = self
        }
        updateStatusItem()
    }

    @objc private func togglePopover(_ sender: Any?) {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(sender)
        } else {
            NSApplication.shared.activate(ignoringOtherApps: true)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }

    private func refreshFromController() {
        guard let controller else { return }
        model.state = controller.committedState ?? .gray
        model.isChecking = controller.isChecking
        model.lastCheckedAt = controller.lastCheckedAt
        model.evidence = controller.evidence
        model.clashSummary = Self.clashText(controller.clashSummary)
        updateStatusItem()
    }

    private func updateStatusItem() {
        guard let button = statusItem?.button else { return }
        let state = model.state
        button.image = StatusItemLogo.image(for: state.kind)
        button.contentTintColor = nil
        button.toolTip = state.title
        button.setAccessibilityLabel("ProxySentry：\(state.title)")
        button.setAccessibilityValue(model.isChecking ? "正在检测" : "检测完成")
    }

    private func postNotification(previous: DiagnosisState?, current: DiagnosisState) {
        guard SystemServices.shouldNotify(previous: previous?.kind, current: current.kind) else { return }
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = current.title
            content.body = current.summary
            center.add(UNNotificationRequest(
                identifier: "ProxySentry.state.\(String(describing: current.kind))",
                content: content,
                trigger: nil
            ))
        }
    }

    private func copySummary() {
        let text = SystemServices.copySummary(state: model.state, evidence: model.evidence)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        model.notice = "诊断摘要已复制"
    }

    private func openClash() {
        let bundleIdentifier = "io.github.clash-verge-rev.clash-verge-rev"
        guard let applicationURL = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: bundleIdentifier
        ) else {
            model.notice = "未找到 Clash Verge Rev"
            return
        }
        NSWorkspace.shared.openApplication(
            at: applicationURL,
            configuration: NSWorkspace.OpenConfiguration()
        ) { [weak self] _, error in
            if error != nil {
                Task { @MainActor in self?.model.notice = "Clash 启动失败" }
            }
        }
    }

    // MARK: - Login item

    private func configureLoginItem() {
        let signed = Self.hasValidSignature
        let defaults = UserDefaults.standard
        let prefs = SystemServices.readLoginPreferences { defaults.object(forKey: $0) }
        model.loginAtLaunch = prefs.hasPreference ? prefs.desired : false
        model.loginAvailable = signed
        guard signed else {
            model.loginStatusText = "登录启动不可用（当前构建未签名）"
            return
        }
        applyLoginDecision(SystemServices.resolveRegistration(
            isSigned: true,
            hasPreference: prefs.hasPreference,
            desired: model.loginAtLaunch,
            registrationAttempted: prefs.attempted
        ))
    }

    private func setLoginAtLaunch(_ desired: Bool) {
        guard model.loginAvailable else { return }
        let defaults = UserDefaults.standard
        SystemServices.writeLoginPreference(desired: desired, attempted: false) {
            defaults.set($1, forKey: $0)
        }
        applyLoginDecision(desired ? .register : .unregister)
    }

    private func applyLoginDecision(_ decision: SystemServices.RegistrationDecision) {
        let defaults = UserDefaults.standard
        do {
            switch decision {
            case .register:
                try SMAppService.mainApp.register()
                SystemServices.writeLoginPreference(desired: true, attempted: true) {
                    defaults.set($1, forKey: $0)
                }
            case .unregister:
                try SMAppService.mainApp.unregister()
                SystemServices.writeLoginPreference(desired: false, attempted: true) {
                    defaults.set($1, forKey: $0)
                }
            case .none, .unavailable:
                break
            }
        } catch {
            SystemServices.writeLoginPreference(desired: model.loginAtLaunch, attempted: true) {
                defaults.set($1, forKey: $0)
            }
            model.notice = "登录启动设置失败"
        }
        refreshLoginStatus()
    }

    private func refreshLoginStatus() {
        switch SMAppService.mainApp.status {
        case .enabled:
            model.loginStatusText = "已启用"
            model.loginAtLaunch = true
        case .requiresApproval:
            model.loginStatusText = "需要在系统设置中批准"
        case .notRegistered:
            model.loginStatusText = "未启用"
            model.loginAtLaunch = false
        case .notFound:
            model.loginStatusText = "登录项不可用"
        @unknown default:
            model.loginStatusText = "登录项状态未知"
        }
    }

    private nonisolated static var hasValidSignature: Bool {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(Bundle.main.bundleURL as CFURL, [], &code) == errSecSuccess,
              let code else { return false }
        return SecStaticCodeCheckValidity(code, [], nil) == errSecSuccess
    }

    // MARK: - Clash read-only enhancement

    private nonisolated static func readClash(fixedProxy: FixedProxy?) async -> DiagnosticsController.ClashRead {
        guard let socketPath = ClashReader.socketCandidatePaths().first(where: {
            ClashReader.validateSocketCandidate(path: $0)
        }) else {
            return DiagnosticsController.ClashRead(
                versionOk: false, configsOk: false, infoAvailable: false,
                localPortMatchesConfiguredProxy: false,
                summary: DiagnosticsController.ClashSummary(),
                tunEnabled: false
            )
        }

        async let versionResult = ClashReader.fetchVersion(socketPath: socketPath, secret: nil)
        async let configsResult = ClashReader.fetchConfigs(socketPath: socketPath, secret: nil)
        async let proxiesResult = ClashReader.fetchProxies(socketPath: socketPath, secret: nil)
        async let connectionsResult = ClashReader.fetchConnections(socketPath: socketPath, secret: nil)
        let (versionRead, configsRead, proxiesRead, connectionsRead) =
            await (versionResult, configsResult, proxiesResult, connectionsResult)

        let version: ClashReader.ClashVersion?
        if case .success(let value) = versionRead { version = value } else { version = nil }
        let configs: ClashReader.ClashInfo?
        if case .success(let value) = configsRead { configs = value } else { configs = nil }
        let selection: ClashReader.ClashProxySelection?
        if case .success(let value) = proxiesRead { selection = value } else { selection = nil }

        let delayResult: Result<Int, ClashReader.ReadError>?
        if configs?.mode == "global", let selected = selection?.selected,
           ClashReader.proxyDelayPath(proxyName: selected) != nil {
            delayResult = await ClashReader.fetchProxyDelay(
                socketPath: socketPath, proxyName: selected, secret: nil)
        } else {
            delayResult = nil
        }
        let activeProxyProbe: NetworkProbes.ProbeOutput?
        let shouldSamplePeers: Bool
        switch delayResult {
        case .success(let delay):
            activeProxyProbe = NetworkProbes.ProbeOutput(
                outcome: .success, failureCategory: nil, milliseconds: delay)
            shouldSamplePeers = false
        case .failure(.timeout):
            activeProxyProbe = NetworkProbes.ProbeOutput(
                outcome: .timeout, failureCategory: .timeout, milliseconds: 3000)
            shouldSamplePeers = true
        case .failure(.non2xxStatus):
            activeProxyProbe = NetworkProbes.ProbeOutput(
                outcome: .failure, failureCategory: .badStatus, milliseconds: 0)
            shouldSamplePeers = true
        case .failure:
            activeProxyProbe = NetworkProbes.ProbeOutput(
                outcome: .unavailable, failureCategory: nil, milliseconds: 0)
            shouldSamplePeers = false
        case nil:
            activeProxyProbe = nil
            shouldSamplePeers = false
        }

        let alternateNodeProbes: [NetworkProbes.ProbeOutput]
        let peerRead = shouldSamplePeers
            ? await Self.peerSampleWithinRoundBudget {
                await ClashReader.samplePeerNodeHealth(socketPath: socketPath, secret: nil)
            }
            : nil
        if case .success(let sample) = peerRead, !sample.unavailable {
            alternateNodeProbes =
                Array(repeating: NetworkProbes.ProbeOutput(
                    outcome: .success, failureCategory: nil, milliseconds: 0
                ), count: sample.succeeded)
                + Array(repeating: NetworkProbes.ProbeOutput(
                    outcome: .failure, failureCategory: .transport, milliseconds: 0
                ), count: sample.failed)
        } else {
            alternateNodeProbes = []
        }

        let available = version != nil && configs != nil
        let trafficObserved: Bool?
        if case .success(let summary) = connectionsRead {
            trafficObserved = summary.proxyTrafficObserved
        } else {
            trafficObserved = nil
        }
        return DiagnosticsController.ClashRead(
            versionOk: version != nil,
            configsOk: configs != nil,
            infoAvailable: available,
            localPortMatchesConfiguredProxy: fixedProxy != nil && configs?.mixedPort == fixedProxy?.port,
            summary: DiagnosticsController.ClashSummary(
                version: version?.version,
                mode: configs?.mode,
                selectedGroup: configs?.mode == "global" ? selection?.selected : nil,
                delay: activeProxyProbe?.outcome == .success ? activeProxyProbe?.milliseconds : nil
            ),
            activeProxyProbe: activeProxyProbe,
            tunEnabled: configs?.tunEnabled == true,
            trafficObserved: trafficObserved,
            alternateNodeProbes: alternateNodeProbes
        )
    }

    /// The initial Clash reads and selected-node delay can consume six of the
    /// controller's eight seconds. Keep optional peer attribution from dropping
    /// the otherwise useful round.
    nonisolated static func peerSampleWithinRoundBudget(
        wait: @escaping @Sendable () async -> Void = {
            try? await Task.sleep(for: .seconds(1))
        },
        sample: @escaping @Sendable () async -> Result<ClashReader.ProxyHealthSample, ClashReader.ReadError>
    ) async -> Result<ClashReader.ProxyHealthSample, ClashReader.ReadError>? {
        await withTaskGroup(
            of: Result<ClashReader.ProxyHealthSample, ClashReader.ReadError>?.self
        ) { group in
            group.addTask { await sample() }
            group.addTask { await wait(); return nil }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    private nonisolated static func clashText(_ summary: DiagnosticsController.ClashSummary?) -> String? {
        guard let summary else { return nil }
        var parts: [String] = []
        if let version = summary.version { parts.append(version) }
        if let mode = summary.mode { parts.append("模式：\(mode)") }
        if let selected = summary.selectedGroup { parts.append("当前：\(selected)") }
        if let delay = summary.delay { parts.append("\(delay) ms") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

}

enum StatusItemLogo {
    static func image(for kind: DiagnosisState.Kind) -> NSImage {
        let color = color(for: kind)
        let image = NSImage(size: NSSize(width: 16, height: 16), flipped: false) { _ in
            color.setStroke()
            color.setFill()

            let routes = NSBezierPath()
            routes.lineWidth = 1.35
            routes.lineCapStyle = .round
            routes.lineJoinStyle = .round
            routes.move(to: NSPoint(x: 1.5, y: 12))
            routes.line(to: NSPoint(x: 5.5, y: 12))
            routes.line(to: NSPoint(x: 9.6, y: 8))
            routes.move(to: NSPoint(x: 1.5, y: 8))
            routes.line(to: NSPoint(x: 9.6, y: 8))
            routes.move(to: NSPoint(x: 1.5, y: 4))
            routes.line(to: NSPoint(x: 5.5, y: 4))
            routes.line(to: NSPoint(x: 9.6, y: 8))
            routes.stroke()

            drawEndpoint(kind, center: NSPoint(x: 13, y: 8))
            return true
        }
        image.isTemplate = false
        return image
    }

    private static func drawEndpoint(_ kind: DiagnosisState.Kind, center: NSPoint) {
        switch kind {
        case .green:
            NSBezierPath(ovalIn: NSRect(x: center.x - 2, y: center.y - 2, width: 4, height: 4)).fill()
        case .blue:
            let ring = NSBezierPath(ovalIn: NSRect(x: center.x - 2, y: center.y - 2, width: 4, height: 4))
            ring.lineWidth = 1.35
            ring.stroke()
        case .yellow:
            let diamond = NSBezierPath()
            diamond.move(to: NSPoint(x: center.x, y: center.y + 2.4))
            diamond.line(to: NSPoint(x: center.x + 2.4, y: center.y))
            diamond.line(to: NSPoint(x: center.x, y: center.y - 2.4))
            diamond.line(to: NSPoint(x: center.x - 2.4, y: center.y))
            diamond.close()
            diamond.fill()
        case .red:
            let cross = NSBezierPath()
            cross.lineWidth = 1.6
            cross.lineCapStyle = .round
            cross.move(to: NSPoint(x: center.x - 1.8, y: center.y - 1.8))
            cross.line(to: NSPoint(x: center.x + 1.8, y: center.y + 1.8))
            cross.move(to: NSPoint(x: center.x - 1.8, y: center.y + 1.8))
            cross.line(to: NSPoint(x: center.x + 1.8, y: center.y - 1.8))
            cross.stroke()
        case .gray:
            let ring = NSBezierPath(ovalIn: NSRect(x: center.x - 2, y: center.y - 2, width: 4, height: 4))
            ring.lineWidth = 1.1
            ring.stroke()
            NSBezierPath(ovalIn: NSRect(x: center.x - 0.6, y: center.y - 0.6, width: 1.2, height: 1.2)).fill()
        }
    }

    private static func color(for kind: DiagnosisState.Kind) -> NSColor {
        switch kind {
        case .green: .systemGreen
        case .blue: .systemBlue
        case .yellow: .systemOrange
        case .red: .systemRed
        case .gray: .systemGray
        }
    }
}
