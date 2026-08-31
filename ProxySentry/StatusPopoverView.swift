import SwiftUI

@MainActor
final class ProxySentryViewModel: ObservableObject {
    @Published var state = DiagnosisState.gray
    @Published var isChecking = false
    @Published var lastCheckedAt: Date?
    @Published var clashSummary: String?
    @Published var evidence: [ProbeEvidence] = []
    @Published var loginAtLaunch = true
    @Published var loginAvailable = false
    @Published var loginStatusText = "登录启动不可用"
    @Published var notice: String?
    @Published var isExpanded = false
}

struct StatusPopoverView: View {
    @ObservedObject var model: ProxySentryViewModel
    let onRecheck: () -> Void
    let onOpenClash: () -> Void
    let onCopySummary: () -> Void
    let onLoginChanged: (Bool) -> Void
    let onOpenLoginSettings: () -> Void
    let onPresentationChanged: (Bool) -> Void
    let onQuit: () -> Void

    private let terminalBackground = Color(red: 0.035, green: 0.04, blue: 0.05)
    private let terminalSurface = Color(red: 0.07, green: 0.08, blue: 0.095)
    private let terminalLine = Color.white.opacity(0.18)
    private let terminalText = Color(red: 0.86, green: 0.88, blue: 0.9)
    private let terminalMuted = Color(red: 0.48, green: 0.52, blue: 0.56)

    var body: some View {
        Group {
            if model.isExpanded {
                expandedPanel
            } else {
                collapsedPanel
            }
        }
        .background(terminalBackground)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .clipShape(RoundedRectangle(cornerRadius: model.isExpanded ? 12 : 6))
        .overlay(
            RoundedRectangle(cornerRadius: model.isExpanded ? 12 : 6)
                .stroke(terminalLine, lineWidth: 1)
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel(model.isExpanded ? "ProxySentry 诊断面板" : "ProxySentry 状态")
    }

    private var collapsedPanel: some View {
        HStack(spacing: 7) {
            Rectangle()
                .fill(model.state.tint)
                .frame(maxWidth: .infinity, minHeight: 2, maxHeight: 2)
            Text(model.state.compactMarker)
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundStyle(model.state.tint)
                .frame(width: 12, height: 12)
            Text(model.state.compactLabel)
                .font(.system(size: 7, weight: .semibold, design: .monospaced))
                .foregroundStyle(model.state.tint)
            Rectangle()
                .fill(model.state.tint.opacity(0.55))
                .frame(maxWidth: .infinity, minHeight: 1, maxHeight: 1)
        }
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, minHeight: 16, maxHeight: 16, alignment: .bottom)
        .contentShape(Rectangle())
        .onTapGesture { onPresentationChanged(true) }
        .accessibilityValue("\(model.state.title)，点击展开")
        .accessibilityHint("显示详细网络诊断")
        .accessibilityAddTraits(.isButton)
    }

    private var expandedPanel: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 11) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("$ proxysentry diagnose --verbose")
                        .foregroundStyle(terminalText)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                    Spacer(minLength: 4)
                    Text(model.isChecking ? "RUNNING" : "READY")
                        .foregroundStyle(model.isChecking ? .orange : model.state.tint)
                }
                .font(.system(size: 10, weight: .semibold, design: .monospaced))

                terminalRule

                HStack(alignment: .top, spacing: 9) {
                    Text(model.state.terminalSymbol)
                        .font(.system(size: 16, weight: .bold, design: .monospaced))
                        .foregroundStyle(model.state.tint)
                        .frame(width: 18, height: 22, alignment: .leading)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(model.state.title)
                            .font(.system(size: 15, weight: .semibold, design: .monospaced))
                            .foregroundStyle(terminalText)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(model.state.terminalLabel)
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                            .foregroundStyle(model.state.tint)
                    }
                    Spacer(minLength: 4)
                    Text(checkTimeText)
                        .font(.system(size: 9, design: .monospaced).monospacedDigit())
                        .foregroundStyle(terminalMuted)
                        .multilineTextAlignment(.trailing)
                        .lineLimit(2)
                }

                terminalField(label: "CLASH", value: model.clashSummary ?? "详情不可用")

                terminalRule
                routeMatrix

                if !failedEvidence.isEmpty {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("EXCEPTIONS")
                            .font(.system(size: 9, weight: .semibold, design: .monospaced))
                            .foregroundStyle(terminalMuted)
                        ForEach(Array(visibleFailedEvidence.enumerated()), id: \.offset) { _, item in
                            HStack(alignment: .firstTextBaseline, spacing: 7) {
                                Text("!")
                                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                                    .foregroundStyle(model.state.tint)
                                Text(item.userVisibleDescription)
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(terminalText)
                                    .fixedSize(horizontal: false, vertical: true)
                                Spacer(minLength: 0)
                            }
                            .accessibilityElement(children: .combine)
                        }
                        if failedEvidence.count > visibleFailedEvidence.count {
                            Text("+ 还有 \(failedEvidence.count - visibleFailedEvidence.count) 条异常，复制摘要查看")
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(terminalMuted)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(9)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(terminalSurface)
                    .overlay(RoundedRectangle(cornerRadius: 3).stroke(terminalLine, lineWidth: 1))
                }

                HStack(spacing: 7) {
                    terminalButton("复检", systemImage: "arrow.clockwise", action: onRecheck)
                        .disabled(model.isChecking)
                    terminalButton("打开 Clash", systemImage: "arrow.up.right.square", action: onOpenClash)
                    terminalButton("复制", systemImage: "doc.on.doc", action: onCopySummary)
                }

                if let notice = model.notice {
                    Text("// \(notice)")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(terminalMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }

                terminalRule

                Button(action: toggleLoginAtLaunch) {
                    HStack(spacing: 8) {
                        Text(model.loginAtLaunch ? "[x]" : "[ ]")
                            .foregroundStyle(model.loginAvailable ? model.state.tint : terminalMuted)
                        Text("登录时启动")
                            .foregroundStyle(terminalText)
                        Spacer(minLength: 4)
                        Text(model.loginAvailable ? "CONFIG" : "UNAVAILABLE")
                            .foregroundStyle(terminalMuted)
                    }
                    .font(.system(size: 11, design: .monospaced))
                    .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!model.loginAvailable)
                .accessibilityLabel("登录时启动")
                .accessibilityValue(model.loginAtLaunch ? "已启用" : "未启用")
                .accessibilityHint(model.loginStatusText)
                .accessibilityAddTraits(.isButton)

                Text("// \(model.loginStatusText)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(terminalMuted)
                    .fixedSize(horizontal: false, vertical: true)
                if model.loginStatusText.contains("批准") {
                    terminalButton("打开登录项设置", systemImage: "gear", action: onOpenLoginSettings)
                }

                HStack(spacing: 7) {
                    terminalButton("收起", systemImage: "chevron.up", action: { onPresentationChanged(false) })
                    terminalButton("退出 ProxySentry", systemImage: "power", action: onQuit)
                }
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 14)
            .padding(.top, 38)
        }
        .fontDesign(.monospaced)
        .background(terminalBackground)
        .frame(minWidth: 320, maxWidth: 360, minHeight: 400, maxHeight: 460)
    }

    private var terminalRule: some View {
        Rectangle()
            .fill(terminalLine)
            .frame(maxWidth: .infinity, minHeight: 1, maxHeight: 1)
            .accessibilityHidden(true)
    }

    private func terminalField(label: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .foregroundStyle(terminalMuted)
                .frame(width: 54, alignment: .leading)
            Text(value)
                .foregroundStyle(value == "详情不可用" ? terminalMuted : terminalText)
                .fixedSize(horizontal: false, vertical: true)
                .help(value)
        }
        .font(.system(size: 10, design: .monospaced))
    }

    private var routeMatrix: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 7) {
                columnLabel("CHECK", width: 62, alignment: .leading)
                columnLabel("STATE", width: 82, alignment: .leading)
                Spacer(minLength: 0)
                columnLabel("LATENCY", width: 58, alignment: .trailing)
            }
            ForEach(routeRows) { row in
                HStack(spacing: 7) {
                    Text(row.name)
                        .foregroundStyle(terminalText)
                        .frame(width: 62, alignment: .leading)
                    HStack(spacing: 5) {
                        Text(row.symbol)
                            .foregroundStyle(row.color)
                            .accessibilityHidden(true)
                        Text(row.status)
                            .foregroundStyle(row.color)
                    }
                    .frame(width: 82, alignment: .leading)
                    Spacer(minLength: 0)
                    Text(row.latency)
                        .foregroundStyle(terminalMuted)
                        .frame(width: 58, alignment: .trailing)
                }
                .font(.system(size: 11, weight: .medium, design: .monospaced).monospacedDigit())
                .accessibilityElement(children: .combine)
            }
        }
    }

    private func columnLabel(_ text: String, width: CGFloat, alignment: Alignment) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .semibold, design: .monospaced))
            .foregroundStyle(terminalMuted)
            .frame(width: width, alignment: alignment)
    }

    private func terminalButton(
        _ title: String,
        systemImage: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(maxWidth: .infinity, minHeight: 28)
                .padding(.horizontal, 5)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(terminalText)
        .background(terminalSurface)
        .overlay(RoundedRectangle(cornerRadius: 3).stroke(terminalLine, lineWidth: 1))
        .accessibilityLabel(title)
        .accessibilityAddTraits(.isButton)
    }

    private func toggleLoginAtLaunch() {
        guard model.loginAvailable else { return }
        model.loginAtLaunch.toggle()
        onLoginChanged(model.loginAtLaunch)
    }

    private var checkTimeText: String {
        if model.isChecking { return "正在检测…" }
        guard let lastCheckedAt = model.lastCheckedAt else { return "尚未检测" }
        return lastCheckedAt.formatted(date: .omitted, time: .shortened)
    }

    private var failedEvidence: [ProbeEvidence] {
        var seen = Set<String>()
        return model.evidence.filter {
            $0.outcome != .success
                && $0.outcome != .unavailable
                && $0.category != .gateway
                && $0.category != .publicIP
                && seen.insert($0.userVisibleDescription).inserted
        }
    }

    private var visibleFailedEvidence: [ProbeEvidence] {
        Array(failedEvidence.prefix(2))
    }

    private var routeRows: [RouteRow] {
        return [
            routeRow(id: "base", name: "base", categories: [.direct, .publicIP]),
            routeRow(
                id: "traffic",
                name: "traffic",
                categories: [.clashTraffic],
                successLabel: "ACTIVE"
            ),
            routeRow(id: "proxy", name: "proxy", categories: [.node]),
            routeRow(
                id: "clash",
                name: "clash",
                categories: [.clashVersion, .clashConfigs],
                successRequiresAll: true
            ),
        ]
    }

    private func routeRow(
        id: String,
        name: String,
        categories: [ProbeEvidence.Category],
        successRequiresAll: Bool = false,
        successLabel: String = "PASS"
    ) -> RouteRow {
        let items = model.evidence.filter { categories.contains($0.category) }
        let outcome: ProbeOutcome?
        if !items.isEmpty,
           successRequiresAll,
           items.allSatisfy({ $0.outcome == .success }) {
            outcome = .success
        } else if !successRequiresAll,
                  items.contains(where: { $0.outcome == .success }) {
            outcome = .success
        } else if items.contains(where: { $0.outcome == .failure }) {
            outcome = .failure
        } else if items.contains(where: { $0.outcome == .timeout }) {
            outcome = .timeout
        } else if !items.isEmpty {
            outcome = .unavailable
        } else {
            outcome = nil
        }
        let latency = items.map(\.milliseconds).filter { $0 > 0 }.max().map { "\($0) ms" } ?? "—"
        return RouteRow(
            id: id,
            name: name,
            status: outcome == .success ? successLabel : (outcome?.terminalLabel ?? "WAIT"),
            latency: latency,
            symbol: outcome?.terminalSymbol ?? "·",
            color: outcome?.terminalColor(state: model.state) ?? terminalMuted
        )
    }
}

private struct RouteRow: Identifiable {
    let id: String
    let name: String
    let status: String
    let latency: String
    let symbol: String
    let color: Color
}

private extension ProbeOutcome {
    var terminalLabel: String {
        switch self {
        case .success: "PASS"
        case .failure: "FAIL"
        case .timeout: "TIMEOUT"
        case .unavailable: "N/A"
        }
    }

    var terminalSymbol: String {
        switch self {
        case .success: "●"
        case .failure: "×"
        case .timeout: "◆"
        case .unavailable: "○"
        }
    }

    func terminalColor(state: DiagnosisState) -> Color {
        switch self {
        case .success: .green
        case .failure, .timeout: state.kind == .red ? .red : .orange
        case .unavailable: .gray
        }
    }
}

private extension DiagnosisState {
    var tint: Color {
        switch kind {
        case .green: .green
        case .blue: .blue
        case .yellow: .orange
        case .red: .red
        case .gray: .gray
        }
    }

    var terminalLabel: String {
        switch kind {
        case .green: "PROXY PASS"
        case .blue: "DIRECT PASS"
        case .yellow: "LOCAL PROXY CONFIG"
        case .red: "UPSTREAM FAILURE"
        case .gray: "UNKNOWN"
        }
    }

    var terminalSymbol: String {
        switch kind {
        case .green: "●"
        case .blue: "○"
        case .yellow: "◆"
        case .red: "×"
        case .gray: "?"
        }
    }

    var compactMarker: String {
        terminalSymbol
    }

    var compactLabel: String {
        switch kind {
        case .green: "PROXY"
        case .blue: "DIRECT"
        case .yellow: "LOCAL"
        case .red: "UPSTREAM"
        case .gray: "UNKNOWN"
        }
    }
}
