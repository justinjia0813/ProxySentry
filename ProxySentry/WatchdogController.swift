import AppKit
import SwiftUI

/// The diagnostic process only writes its own settings/status. Clash changes belong to the opt-in child.
@MainActor
final class WatchdogController: ObservableObject {
    @Published private(set) var enabled = false
    @Published var entryDomain = ""
    @Published private(set) var status = "未启用"
    @Published private(set) var busy = false
    private let home: URL
    private var process: Process?
    private var statusTask: Task<Void, Never>?
    private var onStopped: (() -> Void)?
    private var launchedAt: Date?
    var onChange: (() -> Void)?

    var settingsURL: URL { root.appendingPathComponent("watchdog-settings.json") }
    private var root: URL { home.appendingPathComponent("Library/Application Support/ProxySentry", isDirectory: true) }

    init(home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.home = home
        if let data = try? Data(contentsOf: settingsURL), data.count <= 4096,
           let settings = try? JSONDecoder().decode(Settings.self, from: data) {
            enabled = settings.enabled
            entryDomain = settings.entryDomain
            status = enabled ? "等待已确认的故障" : "未启用"
        }
    }

    private struct Settings: Codable { let enabled: Bool; let entryDomain: String }

    func saveSettings(enabled: Bool, domain: String) throws {
        let domain = domain.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !enabled || domain.isEmpty || (domain.utf8.count <= 253 && domain.contains(".") &&
            domain.split(separator: ".", omittingEmptySubsequences: false).allSatisfy({ label in
                !label.isEmpty && label.utf8.count <= 63 && label.first != "-" && label.last != "-" &&
                label.utf8.allSatisfy { (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 }
            })) else { throw CocoaError(.validationMissingMandatoryProperty) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        let data = try JSONEncoder().encode(Settings(enabled: enabled, entryDomain: domain))
        try data.write(to: settingsURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: settingsURL.path)
        self.enabled = enabled
        entryDomain = domain
        status = enabled ? "等待已确认的故障" : "未启用"
        if !enabled { stop() }
        onChange?()
    }

    func changeEnabled(_ value: Bool) {
        if value {
            guard !legacyConflict else { status = Self.statusText(for: "legacy_conflict"); return }
            let alert = NSAlert()
            alert.messageText = "启用独立入口自愈？"
            alert.informativeText = "仅在持续故障且基础网络正常时尝试修复当前 VLESS REALITY 节点。辅助进程会备份并修改 Clash 运行配置和当前订阅的入口地址，重载并验证；失败尝试回滚。不会切换节点或修改系统代理。关闭或退出时停止修复。"
            alert.addButton(withTitle: "启用自愈")
            alert.addButton(withTitle: "取消")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        do { try saveSettings(enabled: value, domain: entryDomain) }
        catch {
            if !value { stop() }
            status = "设置保存失败：请检查入口域名和文件权限"
        }
    }

    func saveDomain() {
        do { try saveSettings(enabled: enabled, domain: entryDomain) }
        catch { status = "域名保存失败：只填写域名，不含协议或路径" }
    }

    static func shouldAttempt(enabled: Bool, kind: DiagnosisState.Kind, checkedAt: Date, now: Date) -> Bool {
        enabled && kind == .red && now.timeIntervalSince(checkedAt) >= 0 && now.timeIntervalSince(checkedAt) < 120
    }

    func consume(kind: DiagnosisState.Kind, checkedAt: Date) {
        guard Self.shouldAttempt(enabled: enabled, kind: kind, checkedAt: checkedAt, now: Date()) else { return }
        launch(checkOnly: false)
    }

    func checkPrerequisites() { launch(checkOnly: true) }

    func recoverPendingTransaction() {
        if enabled && FileManager.default.fileExists(atPath: root.appendingPathComponent("watchdog-journal.json").path) {
            launch(checkOnly: false)
        }
    }

    private var legacyConflict: Bool {
        FileManager.default.fileExists(atPath: home.appendingPathComponent("Library/LaunchAgents/com.justinjia.clash-watchdog.plist").path) ||
        FileManager.default.fileExists(atPath: "/tmp/clash-watchdog.lock")
    }

    static func cleanEnvironment(home: URL) -> [String: String] {
        ["HOME": home.path, "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "en_US.UTF-8"]
    }

    private func launch(checkOnly: Bool) {
        guard process == nil else { return }
        guard !legacyConflict else { status = Self.statusText(for: "legacy_conflict"); onChange?(); return }
        guard let script = Bundle.main.url(forResource: "watchdog", withExtension: "rb"),
              let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "io.github.clash-verge-rev.clash-verge-rev"),
              let socket = ClashReader.socketCandidatePaths().first(where: { ClashReader.validateSocketCandidate(path: $0) }),
              FileManager.default.isExecutableFile(atPath: "/usr/bin/ruby") else {
            status = "辅助进程或 Clash Verge Rev 不可用"; onChange?(); return
        }
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/usr/bin/ruby")
        child.arguments = ["--disable-gems", script.path, checkOnly ? "--check" : "--once",
                           "--home", home.path, "--core", app.appendingPathComponent("Contents/MacOS/verge-mihomo").path,
                           "--socket", socket, "--parent-pid", String(ProcessInfo.processInfo.processIdentifier)]
        child.environment = Self.cleanEnvironment(home: home)
        child.standardInput = FileHandle.nullDevice
        child.standardOutput = FileHandle.nullDevice
        child.standardError = FileHandle.nullDevice
        start(child, checkOnly: checkOnly)
    }

    // Keep native Process lifecycle together; tests exercise the same cancellation path with a harmless child.
    func start(_ child: Process, checkOnly: Bool) {
        guard process == nil else { return }
        child.terminationHandler = { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.statusTask?.cancel()
                self.process = nil
                self.busy = false
                self.readStatus()
                self.onChange?()
                let completion = self.onStopped
                self.onStopped = nil
                completion?()
            }
        }
        do {
            launchedAt = Date()
            try child.run()
            process = child
            busy = true
            status = checkOnly ? "检查运行条件…" : "检查故障与候选入口…"
            onChange?()
            statusTask = Task { [weak self] in
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(1)) } catch { return }
                    self?.readStatus()
                }
            }
        } catch { status = "辅助进程启动失败"; onChange?() }
    }

    private func readStatus() {
        guard let data = try? Data(contentsOf: root.appendingPathComponent("watchdog-status.json")), data.count <= 4096,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              json["schemaVersion"] as? Int == 1,
              let code = json["state"] as? String,
              let checked = json["checkedAt"] as? String,
              let expiry = json["expiresAt"] as? String else { status = "状态不可用"; return }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let date = formatter.date(from: expiry) ?? ISO8601DateFormatter().date(from: expiry)
        let checkedDate = formatter.date(from: checked) ?? ISO8601DateFormatter().date(from: checked)
        guard let checkedDate, checkedDate <= Date(),
              checkedDate >= (launchedAt ?? .distantPast),
              let date, date.timeIntervalSince(checkedDate) <= 300 else {
            status = busy ? "等待本轮辅助进程状态" : "辅助进程未返回本轮状态"; onChange?(); return
        }
        if !busy && ["checking", "repairing"].contains(code) {
            status = "辅助进程意外结束；请检查未完成事务"; onChange?(); return
        }
        status = date > Date() ? Self.statusText(for: code) : "状态已过期，等待下轮检测"
        onChange?()
    }

    func refreshStatus() {
        if enabled && !busy && FileManager.default.fileExists(atPath: root.appendingPathComponent("watchdog-status.json").path) {
            readStatus()
        }
    }

    func stop(completion: (() -> Void)? = nil) {
        guard let process else { completion?(); return }
        if let completion { onStopped = completion }
        status = "正在停止；如已写入，等待安全回滚…"
        if process.isRunning { process.terminate() }
        onChange?()
    }

    static func statusText(for code: String) -> String {
        switch code {
        case "disabled": return "未启用"
        case "ready": return "运行条件就绪（未执行修复）"
        case "legacy_conflict": return "检测到旧看门狗；请先停用并移走其登录项，再启用新版"
        case "unsupported": return "当前配置不支持安全自愈；仅支持全局模式的 VLESS REALITY 节点"
        case "needs_domain": return "入口已固定为地址，请填写原始入口域名"
        case "waiting": return "等待已确认的故障"
        case "cooldown": return "冷却中（每 3 分钟最多尝试一次）"
        case "checking": return "正在隔离验证候选入口"
        case "repairing": return "正在备份、更新并验证真实流量"
        case "repaired": return "入口已修复，真实流量验证通过"
        case "no_candidate": return "未找到通过真实连接验证的入口；配置未修改"
        case "rolled_back": return "修复验证失败，已恢复原配置"
        case "manual_recovery": return "检测到未完成事务或外部修改，已停止；请检查私有备份和事务记录"
        case "config_changed": return "检测到节点或配置变化，本次未覆盖新配置"
        case "cancelled": return "自愈已停止"
        default: return "状态不可用"
        }
    }
}

struct WatchdogSettingsView: View {
    @ObservedObject var watchdog: WatchdogController

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("入口自愈 · 独立辅助进程").font(.title2.bold())
            Text("诊断始终只读。自愈默认关闭，只有你启用后才允许辅助进程修改 Clash 配置。")
                .foregroundStyle(.secondary)
            Toggle("启用入口自愈", isOn: Binding(get: { watchdog.enabled }, set: { watchdog.changeEnabled($0) }))
                .disabled(watchdog.busy && !watchdog.enabled)
            TextField("原始入口域名（配置中仍有域名时可留空）", text: $watchdog.entryDomain)
                .textFieldStyle(.roundedBorder).disabled(watchdog.busy)
            Text("仅修复当前全局节点的入口。先验证真实连接，再备份、更新运行配置和当前订阅；失败回滚。不切换节点，不更改系统代理。")
                .font(.callout).foregroundStyle(.secondary)
            Text(watchdog.status).font(.callout).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading).padding(12)
                .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
            HStack {
                Button("保存域名") { watchdog.saveDomain() }.disabled(watchdog.busy)
                Button("检查运行条件") { watchdog.checkPrerequisites() }.disabled(watchdog.busy)
                Spacer()
                if watchdog.busy { ProgressView().controlSize(.small) }
            }
            Text("不会自动接管旧看门狗。退出 ProxySentry 后不再修复；备份位于应用支持目录的 watchdog-backups。")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(24).frame(width: 480).fixedSize(horizontal: false, vertical: true)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}
