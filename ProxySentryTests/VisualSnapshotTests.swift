import AppKit
import SwiftUI
import XCTest
@testable import ProxySentry

@MainActor
final class VisualSnapshotTests: XCTestCase {
    func testRenderLightAndDarkPopovers() throws {
        try render(.light, to: "/tmp/ProxySentry-popover-light.png")
        try render(.dark, to: "/tmp/ProxySentry-popover-dark.png")
    }

    func testRenderLightAndDarkStatusItemLogos() throws {
        try renderLogos(.light, to: "/tmp/ProxySentry-logos-light.png")
        try renderLogos(.dark, to: "/tmp/ProxySentry-logos-dark.png")
    }

    func testRenderOverflowFailurePopover() throws {
        let model = sampleModel()
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
            size: NSSize(width: 320, height: 408),
            to: "/tmp/ProxySentry-popover-overflow.png",
            minimumBytes: 10_000
        )
    }

    private func render(_ scheme: ColorScheme, to path: String) throws {
        try writePNG(
            popover(sampleModel(), scheme: scheme),
            size: NSSize(width: 320, height: 408),
            to: path,
            minimumBytes: 10_000
        )
    }

    private func sampleModel() -> ProxySentryViewModel {
        let model = ProxySentryViewModel()
        model.state = .yellow
        model.lastCheckedAt = Date()
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
                onLoginChanged: { _ in }, onOpenLoginSettings: {}, onQuit: {}
            )
        }
        .environment(\.colorScheme, scheme)
    }

    private func renderLogos(_ scheme: ColorScheme, to path: String) throws {
        let entries: [(String, DiagnosisState.Kind)] = [
            ("代理", .green), ("直连", .blue), ("本机", .yellow),
            ("上游", .red), ("未知", .gray),
        ]
        let view = HStack(spacing: 18) {
            ForEach(Array(entries.enumerated()), id: \.offset) { _, entry in
                VStack(spacing: 6) {
                    Image(nsImage: StatusItemLogo.image(for: entry.1))
                        .frame(width: 16, height: 16)
                    Text(entry.0)
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(14)
        .frame(width: 260, height: 64)
        .background(Color(nsColor: .windowBackgroundColor))
        .environment(\.colorScheme, scheme)

        try writePNG(view, size: NSSize(width: 260, height: 64), to: path, minimumBytes: 1_000)
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
    }
}
