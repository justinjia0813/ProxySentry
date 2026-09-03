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

struct SustainedFaultRevealPolicy {
    private static let revealDelay: TimeInterval = 180
    private var faultStartedAt: TimeInterval?
    private var hasRevealed = false

    mutating func shouldReveal(kind: DiagnosisState.Kind, at uptime: TimeInterval) -> Bool {
        switch kind {
        case .green, .blue:
            faultStartedAt = nil
            hasRevealed = false
            return false
        case .yellow, .red, .gray:
            guard let faultStartedAt, uptime >= faultStartedAt else {
                self.faultStartedAt = uptime
                hasRevealed = false
                return false
            }
            guard !hasRevealed, uptime - faultStartedAt >= Self.revealDelay else { return false }
            hasRevealed = true
            return true
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let model = ProxySentryViewModel()
    private var panelController: NotchPanelController?
    private var controller: DiagnosticsController?
    private var pathObserver: PathObserver?
    private var proxyObserver: ProxyObserver?
    private var timerTask: Task<Void, Never>?
    private var sustainedFaultRevealPolicy = SustainedFaultRevealPolicy()
    private var lastAgentStatusDate: Date?

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

        configurePanel()
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
        panelController?.stop()
    }

    func applicationDidResignActive(_ notification: Notification) {
        panelController?.collapse()
    }

    private func configurePanel() {
        let content = NSHostingController(rootView: StatusPopoverView(
            model: model,
            onRecheck: { [weak self] in self?.controller?.trigger() },
            onOpenClash: { [weak self] in self?.openClash() },
            onCopySummary: { [weak self] in self?.copySummary() },
            onLoginChanged: { [weak self] in self?.setLoginAtLaunch($0) },
            onOpenLoginSettings: { SMAppService.openSystemSettingsLoginItems() },
            onPresentationChanged: { [weak self] in self?.panelController?.setExpanded($0) },
            onQuit: { NSApplication.shared.terminate(nil) }
        ))
        let panelController = NotchPanelController(model: model, contentViewController: content)
        self.panelController = panelController
        panelController.start()
    }

    private func refreshFromController() {
        guard let controller else { return }
        let committedState = controller.committedState
        model.state = committedState ?? .gray
        model.isChecking = controller.isChecking
        model.lastCheckedAt = controller.lastCheckedAt
        model.evidence = controller.evidence
        model.clashSummary = Self.clashText(controller.clashSummary)
        if let committedState,
           let checkedAt = controller.lastCheckedAt,
           controller.pendingCandidate == nil,
           !controller.isChecking,
           checkedAt != lastAgentStatusDate {
            do {
                try SystemServices.writeAgentStatus(
                    state: committedState,
                    evidence: controller.evidence,
                    checkedAt: checkedAt
                )
                lastAgentStatusDate = checkedAt
            } catch {
                model.notice = "Agent 状态写入失败"
            }
        }
        if let committedState,
           sustainedFaultRevealPolicy.shouldReveal(
               kind: committedState.kind,
               at: ProcessInfo.processInfo.systemUptime
           ) {
            panelController?.revealForSustainedFault()
        }
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

/// Pure screen geometry so notch placement can be tested without a window server.
enum NotchPanelLayout {
    static let collapsedNotchSize = NSSize(width: 185, height: 48)
    static let collapsedScreenSize = NSSize(width: 185, height: 28)
    static let expandedSize = NSSize(width: 360, height: 460)

    static func preferredScreenIndex(
        in screens: [(containsMouse: Bool, isBuiltInNotch: Bool)]
    ) -> Int? {
        screens.firstIndex { $0.isBuiltInNotch }
            ?? screens.firstIndex { $0.containsMouse }
            ?? screens.indices.first
    }

    static func hasNotch(
        frame: NSRect,
        safeTop: CGFloat,
        auxiliaryTopLeftArea: NSRect?,
        auxiliaryTopRightArea: NSRect?
    ) -> Bool {
        guard isUsable(frame), safeTop.isFinite, safeTop > 0,
              let left = auxiliaryTopLeftArea, isUsable(left),
              let right = auxiliaryTopRightArea, isUsable(right) else {
            return false
        }
        let top = frame.maxY
        return left.maxY >= top - 1 && right.maxY >= top - 1 && right.minX > left.maxX
    }

    static func frame(
        screenFrame: NSRect,
        visibleFrame: NSRect,
        safeTop: CGFloat,
        auxiliaryTopLeftArea: NSRect?,
        auxiliaryTopRightArea: NSRect?,
        expanded: Bool
    ) -> NSRect {
        guard isUsable(screenFrame) else { return .zero }
        let availableFrame = isUsable(visibleFrame) ? visibleFrame : screenFrame
        let safeTop = safeTop.isFinite ? max(0, safeTop) : 0
        let notch = hasNotch(
            frame: screenFrame,
            safeTop: safeTop,
            auxiliaryTopLeftArea: auxiliaryTopLeftArea,
            auxiliaryTopRightArea: auxiliaryTopRightArea
        )
        let size: NSSize
        if expanded {
            size = NSSize(
                width: min(expandedSize.width, screenFrame.width),
                height: min(expandedSize.height, screenFrame.height - safeTop)
            )
        } else {
            let collapsed = notch ? collapsedNotchSize : collapsedScreenSize
            size = NSSize(width: min(collapsed.width, screenFrame.width), height: min(collapsed.height, screenFrame.height))
        }
        let centerX: CGFloat
        if notch, let left = auxiliaryTopLeftArea, let right = auxiliaryTopRightArea {
            centerX = (left.maxX + right.minX) / 2
        } else {
            centerX = availableFrame.maxX - size.width / 2 - 12
        }
        let topY = notch ? screenFrame.maxY : availableFrame.maxY
        let origin = NSPoint(
            x: max(screenFrame.minX, min(centerX - size.width / 2, screenFrame.maxX - size.width)),
            y: max(screenFrame.minY, min(topY - size.height, screenFrame.maxY - size.height))
        )
        return NSRect(origin: origin, size: size)
    }

    private static func isUsable(_ rect: NSRect) -> Bool {
        rect.origin.x.isFinite && rect.origin.y.isFinite
            && rect.width.isFinite && rect.height.isFinite
            && rect.width > 0 && rect.height > 0
    }

    static func frame(for screen: NSScreen, expanded: Bool) -> NSRect {
        frame(
            screenFrame: screen.frame,
            visibleFrame: screen.visibleFrame,
            safeTop: screen.safeAreaInsets.top,
            auxiliaryTopLeftArea: screen.auxiliaryTopLeftArea,
            auxiliaryTopRightArea: screen.auxiliaryTopRightArea,
            expanded: expanded
        )
    }
}

@MainActor
final class NotchPanelController: NSObject, NSWindowDelegate {
    private let model: ProxySentryViewModel
    private let panel: NSPanel
    private let trackingView: NotchTrackingView
    private let contentViewController: NSViewController
    private var localMonitor: Any?
    private var globalMonitor: Any?
    private var screenObserver: NSObjectProtocol?
    private var expandTask: Task<Void, Never>?
    private var collapseTask: Task<Void, Never>?
    private var revealTask: Task<Void, Never>?
    private var started = false

    init(model: ProxySentryViewModel, contentViewController: NSViewController) {
        self.model = model
        self.panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 185, height: 48),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        self.trackingView = NotchTrackingView()
        self.contentViewController = contentViewController
        super.init()

        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.delegate = self

        trackingView.onMouseEntered = { [weak self] in self?.scheduleExpand() }
        trackingView.onMouseExited = { [weak self] in self?.scheduleCollapse() }
        panel.contentView = trackingView
        contentViewController.view.frame = trackingView.bounds
        contentViewController.view.autoresizingMask = [.width, .height]
        trackingView.addSubview(contentViewController.view)
        panel.setAccessibilityLabel("ProxySentry 网络诊断")
    }

    func start() {
        guard !started else { return }
        started = true
        model.isExpanded = false
        installMonitors()
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.reposition() }
        }
        reposition()
        panel.orderFrontRegardless()
    }

    func stop() {
        guard started else { return }
        started = false
        expandTask?.cancel()
        collapseTask?.cancel()
        revealTask?.cancel()
        expandTask = nil
        collapseTask = nil
        revealTask = nil
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        localMonitor = nil
        globalMonitor = nil
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        screenObserver = nil
        panel.orderOut(nil)
    }

    func revealForSustainedFault() {
        guard started else { return }
        collapseTask?.cancel()
        collapseTask = nil
        model.isExpanded = true
        reposition()
        revealTask?.cancel()
        revealTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(5)) } catch { return }
            guard let self, self.started else { return }
            guard !self.panel.frame.contains(NSEvent.mouseLocation) else { return }
            self.collapse()
        }
    }

    func setExpanded(_ expanded: Bool) {
        guard started else { return }
        if expanded {
            collapseTask?.cancel()
        } else {
            expandTask?.cancel()
            revealTask?.cancel()
        }
        model.isExpanded = expanded
        reposition()
    }

    func collapse() {
        guard started else { return }
        expandTask?.cancel()
        collapseTask?.cancel()
        revealTask?.cancel()
        expandTask = nil
        collapseTask = nil
        revealTask = nil
        model.isExpanded = false
        reposition()
    }

    private func scheduleExpand() {
        guard started else { return }
        collapseTask?.cancel()
        expandTask?.cancel()
        expandTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .milliseconds(120)) } catch { return }
            guard let self, self.started else { return }
            self.model.isExpanded = true
            self.reposition()
        }
    }

    private func scheduleCollapse() {
        guard started else { return }
        expandTask?.cancel()
        collapseTask?.cancel()
        collapseTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
            self?.collapse()
        }
    }

    private func reposition() {
        guard let screen = targetScreen() else { return }
        panel.setFrame(NotchPanelLayout.frame(for: screen, expanded: model.isExpanded), display: true)
    }

    private func targetScreen() -> NSScreen? {
        let screens = NSScreen.screens
        let mouse = NSEvent.mouseLocation
        let index = NotchPanelLayout.preferredScreenIndex(in: screens.map {
            ($0.frame.contains(mouse), isBuiltIn($0) && hasNotch($0))
        })
        return index.map { screens[$0] } ?? NSScreen.main
    }

    private func hasNotch(_ screen: NSScreen) -> Bool {
        NotchPanelLayout.hasNotch(
            frame: screen.frame,
            safeTop: screen.safeAreaInsets.top,
            auxiliaryTopLeftArea: screen.auxiliaryTopLeftArea,
            auxiliaryTopRightArea: screen.auxiliaryTopRightArea
        )
    }

    private func isBuiltIn(_ screen: NSScreen) -> Bool {
        guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            return false
        }
        return CGDisplayIsBuiltin(CGDirectDisplayID(number.uint32Value)) != 0
    }

    private func installMonitors() {
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown]) { [weak self] event in
            guard let self else { return event }
            if event.type == .keyDown, event.keyCode == 53 {
                self.collapse()
            } else if event.type != .keyDown, !self.panel.frame.contains(self.screenLocation(of: event)) {
                self.collapse()
            }
            return event
        }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                guard self.started, !self.panel.frame.contains(NSEvent.mouseLocation) else { return }
                self.collapse()
            }
        }
    }

    private func screenLocation(of event: NSEvent) -> NSPoint {
        guard let window = event.window else { return NSEvent.mouseLocation }
        return window.convertPoint(toScreen: event.locationInWindow)
    }

    func windowDidChangeScreen(_ notification: Notification) {
        reposition()
    }
}

private final class NotchTrackingView: NSView {
    var onMouseEntered: (() -> Void)?
    var onMouseExited: (() -> Void)?
    private var trackingArea: NSTrackingArea?

    override func updateTrackingAreas() {
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
        super.updateTrackingAreas()
    }

    override func mouseEntered(with event: NSEvent) { onMouseEntered?() }
    override func mouseExited(with event: NSEvent) { onMouseExited?() }
}
