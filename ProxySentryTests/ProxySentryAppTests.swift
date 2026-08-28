import AppKit
import XCTest
@testable import ProxySentry

@MainActor
final class ProxySentryAppTests: XCTestCase {
    func testHostedTestsDoNotInstallStatusItem() {
        let delegate = AppDelegate()
        delegate.applicationDidFinishLaunching(
            Notification(name: NSApplication.didFinishLaunchingNotification)
        )
        defer {
            delegate.applicationWillTerminate(
                Notification(name: NSApplication.willTerminateNotification)
            )
        }

        let statusItem = Mirror(reflecting: delegate).descendant("statusItem") as? NSStatusItem
        XCTAssertNil(statusItem)
    }
}
