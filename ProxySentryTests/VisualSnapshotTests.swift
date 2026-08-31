import AppKit
import SwiftUI
import XCTest
@testable import ProxySentry

@MainActor
final class VisualSnapshotTests: XCTestCase {
    func testRenderLightAndDarkPopovers() throws {
        try render(.light, expanded: true, to: "/tmp/ProxySentry-popover-light.png")
        try render(.dark, expanded: true, to: "/tmp/ProxySentry-popover-dark.png")
    }

    func testRenderCollapsedPopover() throws {
        try render(.dark, expanded: false, size: NSSize(width: 185, height: 28), to: "/tmp/ProxySentry-popover-collapsed.png")
    }

    func testRenderEveryCollapsedState() throws {
        for (index, state) in [DiagnosisState.green, .blue, .yellow, .red, .gray].enumerated() {
            let model = sampleModel()
            model.state = state
            try writePNG(
                popover(model, scheme: .dark),
                size: NSSize(width: 185, height: 28),
                to: "/tmp/ProxySentry-collapsed-state-\(index).png",
                minimumBytes: 300
            )
        }
    }

    func testRenderOverflowFailurePopover() throws {
        let model = sampleModel()
        model.isExpanded = true
        model.state = .gray
        model.evidence = [
            ProbeEvidence(category: .direct, outcome: .failure, milliseconds: 0, userVisibleDescription: "域名解析失败"),
            ProbeEvidence(category: .direct, outcome: .timeout, milliseconds: 3000, userVisibleDescription: "直连检测超时"),
            ProbeEvidence(category: .proxy, outcome: .timeout, milliseconds: 3000, userVisibleDescription: "代理出口检测超时"),
            ProbeEvidence(category: .localPort, outcome: .failure, milliseconds: 8, userVisibleDescription: "本地代理端口连接被拒绝"),
            ProbeEvidence(category: .clashVersion, outcome: .success, milliseconds: 0, userVisibleDescription: "Clash 内核运行正常"),
            ProbeEvidence(category: .clashConfigs, outcome: .unavailable, milliseconds: 0, userVisibleDescription: "Clash 配置详情不可用"),
        ]
        try writePNG(
            popover(model, scheme: .dark),
            size: NSSize(width: 360, height: 460),
            to: "/tmp/ProxySentry-popover-overflow.png",
            minimumBytes: 4_000
        )
    }

    private func render(
        _ scheme: ColorScheme,
        expanded: Bool,
        size: NSSize = NSSize(width: 360, height: 460),
        to path: String
    ) throws {
        let model = sampleModel()
        model.isExpanded = expanded
        try writePNG(
            popover(model, scheme: scheme),
            size: size,
            to: path,
            minimumBytes: expanded ? 4_000 : 500
        )
    }

    private func sampleModel() -> ProxySentryViewModel {
        let model = ProxySentryViewModel()
        model.state = .yellow
        model.lastCheckedAt = Date(timeIntervalSince1970: 1_700_000_000)
        model.clashSummary = "1.19.8 · 模式：rule · 当前：自动选择 · 42 ms"
        model.loginAtLaunch = true
        model.loginAvailable = false
        model.loginStatusText = "登录启动不可用（当前构建未签名）"
        model.evidence = [
            ProbeEvidence(category: .localPort, outcome: .failure, milliseconds: 8, userVisibleDescription: "本地代理端口连接被拒绝"),
            ProbeEvidence(category: .proxy, outcome: .timeout, milliseconds: 3000, userVisibleDescription: "代理出口检测超时"),
            ProbeEvidence(category: .node, outcome: .success, milliseconds: 42, userVisibleDescription: "当前代理节点可用"),
            ProbeEvidence(category: .clashTraffic, outcome: .success, milliseconds: 0, userVisibleDescription: "Clash 正在承载代理流量"),
            ProbeEvidence(category: .direct, outcome: .success, milliseconds: 36, userVisibleDescription: "直连可用"),
            ProbeEvidence(category: .clashVersion, outcome: .success, milliseconds: 2, userVisibleDescription: "Clash 内核运行正常"),
        ]
        return model
    }

    private func popover(_ model: ProxySentryViewModel, scheme: ColorScheme) -> some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
            StatusPopoverView(
                model: model,
                onRecheck: {}, onOpenClash: {}, onCopySummary: {},
                onLoginChanged: { _ in }, onOpenLoginSettings: {},
                onPresentationChanged: { model.isExpanded = $0 }, onQuit: {}
            )
        }
        .environment(\.colorScheme, scheme)
    }

    private func writePNG<V: View>(
        _ view: V,
        size: NSSize,
        to path: String,
        minimumBytes: Int
    ) throws {
        let hosting = NSHostingView(rootView: view)
        hosting.frame = NSRect(origin: .zero, size: size)
        hosting.layoutSubtreeIfNeeded()
        guard let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else {
            return XCTFail("Could not create bitmap")
        }
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            return XCTFail("Could not encode PNG")
        }
        try png.write(to: URL(fileURLWithPath: path), options: .atomic)
        XCTAssertGreaterThan(png.count, minimumBytes)
        XCTAssertLessThan(png.count, 500_000)
    }
}
