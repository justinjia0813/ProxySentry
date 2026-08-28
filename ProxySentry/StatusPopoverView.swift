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
}

struct StatusPopoverView: View {
    @ObservedObject var model: ProxySentryViewModel
    let onRecheck: () -> Void
    let onOpenClash: () -> Void
    let onCopySummary: () -> Void
    let onLoginChanged: (Bool) -> Void
    let onOpenLoginSettings: () -> Void
    let onQuit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("PROXY SENTRY")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .tracking(1.1)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(checkTimeText)
                    .font(.system(size: 10, design: .monospaced).monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            HStack(alignment: .top, spacing: 9) {
                Image(systemName: model.state.terminalSymbol)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(model.state.tint)
                    .frame(width: 14, height: 18)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.state.title)
                        .font(.system(size: 15, weight: .semibold))
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(model.state.terminalLabel)
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .tracking(0.7)
                        .foregroundStyle(model.state.tint)
                }
                Spacer()
                if model.isChecking {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel("正在检测")
                }
            }

            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Text("CLASH")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.secondary)
                Text(model.clashSummary ?? "详情不可用")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(model.clashSummary == nil ? .secondary : .primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(model.clashSummary ?? "Clash 详情不可用")
            }

            Divider()
            routeMatrix

            if !failedEvidence.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(Array(visibleFailedEvidence.enumerated()), id: \.offset) { _, item in
                        HStack(alignment: .firstTextBaseline, spacing: 7) {
                            Text("!")
                                .font(.system(size: 11, weight: .bold, design: .monospaced))
                                .foregroundStyle(model.state.tint)
                            Text(item.userVisibleDescription)
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                            Spacer(minLength: 4)
                        }
                    }
                    if failedEvidence.count > visibleFailedEvidence.count {
                        Text("+ 还有 \(failedEvidence.count - visibleFailedEvidence.count) 条异常，复制摘要查看")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                    }
                }
            }

            HStack(spacing: 8) {
                actionButton("复检", systemImage: "arrow.clockwise", action: onRecheck)
                    .disabled(model.isChecking)
                actionButton("打开 Clash", systemImage: "app.badge", action: onOpenClash)
                actionButton("复制", systemImage: "doc.on.doc", action: onCopySummary)
            }

            if let notice = model.notice {
                Text(notice)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }

            Divider()

            Toggle(isOn: Binding(
                get: { model.loginAtLaunch },
                set: {
                    model.loginAtLaunch = $0
                    onLoginChanged($0)
                }
            )) {
                Text("登录时启动")
                    .font(.system(size: 12))
            }
            .toggleStyle(.switch)
            .controlSize(.mini)
            .disabled(!model.loginAvailable)
            .accessibilityHint(model.loginStatusText)

            Text(model.loginStatusText)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            if model.loginStatusText.contains("批准") {
                Button("打开登录项设置", action: onOpenLoginSettings)
                    .buttonStyle(.link)
            }

            Button("退出 ProxySentry", action: onQuit)
                .buttonStyle(.plain)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(width: 320)
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(model.state.title)
    }

    private var routeMatrix: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                columnLabel("CHECK", width: 58, alignment: .leading)
                columnLabel("STATE", width: 82, alignment: .leading)
                Spacer(minLength: 0)
                columnLabel("LATENCY", width: 58, alignment: .trailing)
            }
            ForEach(routeRows) { row in
                HStack(spacing: 8) {
                    Text(row.name)
                        .frame(width: 58, alignment: .leading)
                    HStack(spacing: 5) {
                        Image(systemName: row.symbol)
                            .font(.system(size: 7, weight: .bold))
                            .foregroundStyle(row.color)
                            .accessibilityHidden(true)
                        Text(row.status)
                            .foregroundStyle(row.color)
                    }
                    .frame(width: 82, alignment: .leading)
                    Spacer(minLength: 0)
                    Text(row.latency)
                        .foregroundStyle(.secondary)
                        .frame(width: 58, alignment: .trailing)
                }
                .font(.system(size: 11, weight: .medium, design: .monospaced).monospacedDigit())
            }
        }
    }

    private func columnLabel(_ text: String, width: CGFloat, alignment: Alignment) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .semibold, design: .monospaced))
            .tracking(0.5)
            .foregroundStyle(.tertiary)
            .frame(width: width, alignment: alignment)
    }

    private func actionButton(
        _ title: String,
        systemImage: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.system(size: 11))
                .lineLimit(1)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .frame(maxWidth: .infinity)
        .accessibilityLabel(title)
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
        let hasTrafficEvidence = model.evidence.contains { $0.category == .clashTraffic }
        let hasProxyExitEvidence = model.evidence.contains { $0.category == .proxy }
        return [
            routeRow(id: "base", name: "base", categories: [.direct, .publicIP]),
            routeRow(
                id: "traffic",
                name: "traffic",
                categories: hasTrafficEvidence ? [.clashTraffic] : (hasProxyExitEvidence ? [.proxy] : [.localPort]),
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
            symbol: outcome?.terminalSymbol ?? "circle",
            color: outcome?.terminalColor(state: model.state) ?? .secondary
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
        case .success: "circle.fill"
        case .failure: "xmark"
        case .timeout: "diamond.fill"
        case .unavailable: "circle"
        }
    }

    func terminalColor(state: DiagnosisState) -> Color {
        switch self {
        case .success: .green
        case .failure, .timeout: state.kind == .red ? .red : .orange
        case .unavailable: .secondary
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
        case .green: "circle.fill"
        case .blue: "circle"
        case .yellow: "diamond.fill"
        case .red: "xmark"
        case .gray: "questionmark"
        }
    }
}
