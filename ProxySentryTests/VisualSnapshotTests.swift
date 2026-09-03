import AppKit
import SwiftUI
import Vision
import XCTest
@testable import ProxySentry

@MainActor
final class VisualSnapshotTests: XCTestCase {
    func testRenderLightAndDarkPopovers() throws {
        try render(.light, expanded: true, to: "/tmp/ProxySentry-popover-light.png")
        try render(.dark, expanded: true, to: "/tmp/ProxySentry-popover-dark.png")
    }

    func testRouteLabelsRemainVisibleInLightAppearance() throws {
        let path = "/tmp/ProxySentry-popover-light-route-labels.png"
        let size = NSSize(width: 360, height: 460)
        try render(.light, expanded: true, size: size, to: path)

        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        guard let bitmap = NSBitmapImageRep(data: data) else {
            return XCTFail("Could not read rendered PNG")
        }
        let labelRegion = NSRect(x: 10, y: 195, width: 65, height: 65)
        XCTAssertGreaterThan(brightPixelCount(in: bitmap, viewSize: size, rect: labelRegion), 100)
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

    func testBaseFailureDoesNotPresentDownstreamTimeoutAsProxyFault() throws {
        let model = ProxySentryViewModel()
        model.state = .grayLocalNetwork
        model.isExpanded = true
        model.evidence = [
            ProbeEvidence(category: .gateway, outcome: .failure, milliseconds: 20, userVisibleDescription: "默认网关连接失败"),
            ProbeEvidence(category: .publicIP, outcome: .timeout, milliseconds: 3000, userVisibleDescription: "公网地址检测超时"),
            ProbeEvidence(category: .direct, outcome: .timeout, milliseconds: 3000, userVisibleDescription: "直连检测超时"),
            ProbeEvidence(category: .proxy, outcome: .timeout, milliseconds: 3000, userVisibleDescription: "代理出口检测超时"),
            ProbeEvidence(category: .node, outcome: .timeout, milliseconds: 3000, userVisibleDescription: "当前代理节点检测超时"),
        ]
        let view = StatusPopoverView(
            model: model,
            onRecheck: {}, onOpenClash: {}, onCopySummary: {},
            onLoginChanged: { _ in }, onOpenLoginSettings: {},
            onPresentationChanged: { _ in }, onQuit: {}
        )

        let localPath = "/tmp/ProxySentry-local-network-failure.png"
        try writePNG(view, size: NSSize(width: 360, height: 460), to: localPath, minimumBytes: 4_000)
        let localText = try recognizedText(in: localPath)
        XCTAssertTrue(localText.contains("BASE FAILURE"), localText)
        XCTAssertEqual(localText.components(separatedBy: "BLOCKED").count - 1, 2, localText)
        XCTAssertFalse(localText.contains("UPSTREAM FAILURE"), localText)

        model.state = .grayExternal
        model.evidence = [
            ProbeEvidence(category: .gateway, outcome: .success, milliseconds: 20, userVisibleDescription: "默认网关可用"),
            ProbeEvidence(category: .publicIP, outcome: .failure, milliseconds: 3000, userVisibleDescription: "公网地址连接失败"),
            ProbeEvidence(category: .direct, outcome: .timeout, milliseconds: 3000, userVisibleDescription: "直连检测超时"),
            ProbeEvidence(category: .proxy, outcome: .timeout, milliseconds: 3000, userVisibleDescription: "代理出口检测超时"),
        ]
        let externalPath = "/tmp/ProxySentry-base-network-failure.png"
        try writePNG(view, size: NSSize(width: 360, height: 460), to: externalPath, minimumBytes: 4_000)
        let externalText = try recognizedText(in: externalPath)
        XCTAssertTrue(externalText.split(separator: "\n").contains { $0.hasSuffix("FAIL") && $0 != "BASE FAILURE" }, externalText)
        XCTAssertEqual(externalText.components(separatedBy: "BLOCKED").count - 1, 2, externalText)

        model.state = .red
        let redPath = "/tmp/ProxySentry-red-failure.png"
        try writePNG(view, size: NSSize(width: 360, height: 460), to: redPath, minimumBytes: 4_000)
        let redText = try recognizedText(in: redPath)
        XCTAssertTrue(redText.contains("代理出口"), redText)
        XCTAssertFalse(redText.contains("公网地址"), redText)
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

    private func recognizedText(in path: String) throws -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["zh-Hans", "en-US"]
        try VNImageRequestHandler(url: URL(fileURLWithPath: path)).perform([request])
        return (request.results ?? [])
            .compactMap { $0.topCandidates(1).first?.string }
            .joined(separator: "\n")
    }

    private func brightPixelCount(in bitmap: NSBitmapImageRep, viewSize: NSSize, rect: NSRect) -> Int {
        let scaleX = CGFloat(bitmap.pixelsWide) / viewSize.width
        let scaleY = CGFloat(bitmap.pixelsHigh) / viewSize.height
        let xRange = Int(rect.minX * scaleX)..<Int(rect.maxX * scaleX)
        let yRange = Int(rect.minY * scaleY)..<Int(rect.maxY * scaleY)

        return xRange.reduce(into: 0) { count, x in
            for y in yRange {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                let luminance = 0.2126 * color.redComponent
                    + 0.7152 * color.greenComponent
                    + 0.0722 * color.blueComponent
                if luminance > 0.45 { count += 1 }
            }
        }
    }
}
