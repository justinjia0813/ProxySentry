import AppKit
import XCTest
@testable import ProxySentry

@MainActor
final class ProxySentryAppTests: XCTestCase {
    func testClashModeLabelsUseReportedModeNotNetworkHealth() {
        let model = ProxySentryViewModel()
        for (raw, label): (String?, String) in [
            ("rule", "规则模式"), ("global", "全局模式"), ("direct", "直连模式"),
            (nil, "模式未知"), ("unexpected", "模式未知")
        ] {
            model.clashMode = raw
            for state in [DiagnosisState.green, .blue, .red, .gray] {
                model.state = state
                XCTAssertEqual(model.clashModeText, label)
            }
        }
    }

    func testWatchdogStoppingTwicePreservesQuitCompletion() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let watchdog = WatchdogController(home: home)
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sleep")
        child.arguments = ["2"]
        watchdog.start(child, checkOnly: true)
        XCTAssertTrue(watchdog.busy)
        var completed = false
        watchdog.stop { completed = true }
        watchdog.stop()
        for _ in 0..<300 where watchdog.busy { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(watchdog.busy)
        XCTAssertTrue(completed)
    }

    func testWatchdogDoesNotReusePreviousRepairStatusForNewProcess() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let watchdog = WatchdogController(home: home)
        try watchdog.saveSettings(enabled: false, domain: "")
        let formatter = ISO8601DateFormatter()
        let data = try JSONSerialization.data(withJSONObject: [
            "schemaVersion": 1, "state": "repaired", "checkedAt": formatter.string(from: Date().addingTimeInterval(-30)),
            "expiresAt": formatter.string(from: Date().addingTimeInterval(270))
        ])
        try data.write(to: watchdog.settingsURL.deletingLastPathComponent().appendingPathComponent("watchdog-status.json"))
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        watchdog.start(child, checkOnly: true)
        for _ in 0..<100 where watchdog.busy { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(watchdog.status, "辅助进程未返回本轮状态")
    }

    func testWatchdogDefaultsOffAndPersistsOnlyExplicitChoice() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let watchdog = WatchdogController(home: home)
        XCTAssertFalse(watchdog.enabled)
        XCTAssertFalse(FileManager.default.fileExists(atPath: watchdog.settingsURL.path))
        try watchdog.saveSettings(enabled: true, domain: "entry.example.com")
        XCTAssertTrue(WatchdogController(home: home).enabled)
        XCTAssertEqual(WatchdogController(home: home).entryDomain, "entry.example.com")
        XCTAssertThrowsError(try watchdog.saveSettings(enabled: true, domain: "https://bad.example/path"))
        try watchdog.saveSettings(enabled: false, domain: "")
        XCTAssertFalse(WatchdogController(home: home).enabled)
        let permissions = try FileManager.default.attributesOfItem(atPath: watchdog.settingsURL.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.intValue, 0o600)
    }

    func testWatchdogOnlyConsumesFreshConfirmedRedAndNeverInheritsEnvironment() {
        let now = Date()
        XCTAssertTrue(WatchdogController.shouldAttempt(enabled: true, kind: .red, checkedAt: now, now: now))
        XCTAssertFalse(WatchdogController.shouldAttempt(enabled: false, kind: .red, checkedAt: now, now: now))
        XCTAssertFalse(WatchdogController.shouldAttempt(enabled: true, kind: .green, checkedAt: now, now: now))
        XCTAssertFalse(WatchdogController.shouldAttempt(enabled: true, kind: .red, checkedAt: now.addingTimeInterval(-121), now: now))
        XCTAssertFalse(WatchdogController.shouldAttempt(enabled: true, kind: .red, checkedAt: now.addingTimeInterval(1), now: now))
        XCTAssertEqual(Set(WatchdogController.cleanEnvironment(home: URL(fileURLWithPath: "/tmp/test")).keys), ["HOME", "PATH", "LANG"])
        XCTAssertEqual(WatchdogController.statusText(for: "secret arbitrary error"), "状态不可用")
    }

    func testPanelRevealsOnceOnlyAfterThreeMinutesOfContinuousFault() {
        var policy = SustainedFaultRevealPolicy()

        XCTAssertFalse(policy.shouldReveal(kind: .red, at: 1_000))
        XCTAssertFalse(policy.shouldReveal(kind: .gray, at: 1_179))
        XCTAssertTrue(policy.shouldReveal(kind: .yellow, at: 1_180))
        XCTAssertFalse(policy.shouldReveal(kind: .red, at: 1_600))

        XCTAssertFalse(policy.shouldReveal(kind: .green, at: 1_601))
        XCTAssertFalse(policy.shouldReveal(kind: .red, at: 1_602))
        XCTAssertTrue(policy.shouldReveal(kind: .red, at: 1_782))
    }

    func testHostedTestsDoNotInstallGlobalUI() {
        let delegate = AppDelegate()
        delegate.applicationDidFinishLaunching(
            Notification(name: NSApplication.didFinishLaunchingNotification)
        )
        defer {
            delegate.applicationWillTerminate(
                Notification(name: NSApplication.willTerminateNotification)
            )
        }

        let panelController = Mirror(reflecting: delegate).descendant("panelController") as? NotchPanelController
        XCTAssertNil(panelController)
    }

    func testPhysicalNotchScreenWinsWhenPointerIsOnExternalDisplay() {
        let result = NotchPanelLayout.preferredScreenIndex(in: [
            (containsMouse: false, isBuiltInNotch: true),
            (containsMouse: true, isBuiltInNotch: false),
        ])

        XCTAssertEqual(result, 0)
    }

    func testNotchLayoutUsesPhysicalNotchCenterAndCollapsedSize() {
        let frame = NSRect(x: 0, y: 0, width: 1512, height: 982)
        let visible = NSRect(x: 0, y: 61, width: 1512, height: 888)
        let left = NSRect(x: 0, y: 950, width: 663, height: 32)
        let right = NSRect(x: 848, y: 950, width: 664, height: 32)

        let collapsed = NotchPanelLayout.frame(
            screenFrame: frame, visibleFrame: visible, safeTop: 32,
            auxiliaryTopLeftArea: left, auxiliaryTopRightArea: right, expanded: false
        )
        XCTAssertEqual(collapsed.size.width, 185, accuracy: 0.01)
        XCTAssertEqual(collapsed.size.height, 48, accuracy: 0.01)
        XCTAssertEqual(collapsed.midX, 755.5, accuracy: 0.01)
        XCTAssertEqual(collapsed.maxY, 982, accuracy: 0.01)

        let expanded = NotchPanelLayout.frame(
            screenFrame: frame, visibleFrame: visible, safeTop: 32,
            auxiliaryTopLeftArea: left, auxiliaryTopRightArea: right, expanded: true
        )
        XCTAssertEqual(expanded.size.width, 360, accuracy: 0.01)
        XCTAssertEqual(expanded.size.height, 460, accuracy: 0.01)
        XCTAssertEqual(expanded.midX, 755.5, accuracy: 0.01)
        XCTAssertEqual(expanded.maxY, 982, accuracy: 0.01)
    }

    func testNotchLayoutFallsBackToVisibleFrameWithoutNotch() {
        let result = NotchPanelLayout.frame(
            screenFrame: NSRect(x: 0, y: 0, width: 1440, height: 900),
            visibleFrame: NSRect(x: 0, y: 24, width: 1440, height: 852),
            safeTop: 0, auxiliaryTopLeftArea: nil, auxiliaryTopRightArea: nil, expanded: false
        )
        XCTAssertEqual(result.size.height, 28, accuracy: 0.01)
        XCTAssertEqual(result.maxX, 1428, accuracy: 0.01)
        XCTAssertEqual(result.maxY, 876, accuracy: 0.01)
    }

    func testNotchLayoutSupportsNegativeCoordinatesAndClampsSize() {
        let negative = NotchPanelLayout.frame(
            screenFrame: NSRect(x: -1920, y: -100, width: 900, height: 700),
            visibleFrame: NSRect(x: -1920, y: -40, width: 900, height: 600),
            safeTop: 0, auxiliaryTopLeftArea: nil, auxiliaryTopRightArea: nil, expanded: true
        )
        XCTAssertEqual(negative.maxX, -1032, accuracy: 0.01)
        XCTAssertEqual(negative.maxY, 560, accuracy: 0.01)

        let narrow = NotchPanelLayout.frame(
            screenFrame: NSRect(x: 10, y: 20, width: 100, height: 80),
            visibleFrame: NSRect(x: 10, y: 20, width: 100, height: 60),
            safeTop: 0, auxiliaryTopLeftArea: nil, auxiliaryTopRightArea: nil, expanded: true
        )
        XCTAssertEqual(narrow.size.width, 100, accuracy: 0.01)
        XCTAssertEqual(narrow.size.height, 80, accuracy: 0.01)
        XCTAssertEqual(narrow.minX, 10, accuracy: 0.01)
        XCTAssertEqual(narrow.minY, 20, accuracy: 0.01)

        let fallback = NotchPanelLayout.frame(
            screenFrame: NSRect(x: 0, y: 0, width: 800, height: 600),
            visibleFrame: .zero,
            safeTop: .nan, auxiliaryTopLeftArea: nil, auxiliaryTopRightArea: nil,
            expanded: false
        )
        XCTAssertEqual(fallback.maxX, 788, accuracy: 0.01)
        XCTAssertEqual(fallback.maxY, 600, accuracy: 0.01)
        XCTAssertEqual(NotchPanelLayout.frame(
            screenFrame: .zero, visibleFrame: .zero, safeTop: 0,
            auxiliaryTopLeftArea: nil, auxiliaryTopRightArea: nil, expanded: false
        ), .zero)
    }
}
