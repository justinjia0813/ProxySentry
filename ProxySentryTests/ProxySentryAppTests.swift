import AppKit
import XCTest
@testable import ProxySentry

@MainActor
final class ProxySentryAppTests: XCTestCase {
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
