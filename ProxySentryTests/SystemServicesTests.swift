import XCTest
@testable import ProxySentry

final class SystemServicesTests: XCTestCase {

    // MARK: - Notification dedup / recovery

    func testShouldNotifyOnlyOnKindChange() {
        XCTAssertTrue(SystemServices.shouldNotify(previous: nil, current: .green))
        XCTAssertTrue(SystemServices.shouldNotify(previous: .yellow, current: .green), "recovery notifies")
        XCTAssertTrue(SystemServices.shouldNotify(previous: .green, current: .yellow))
        XCTAssertFalse(SystemServices.shouldNotify(previous: .green, current: .green), "same kind not re-notified")
        XCTAssertFalse(SystemServices.shouldNotify(previous: .yellow, current: .yellow))
    }

    func testNotifyIfChangedPostsOnlyOnChange() {
        var authCalls = 0
        var postCalls = 0
        // Same kind → nothing posted.
        SystemServices.notifyIfChanged(
            previous: .green, current: .green,
            requestAuthorization: { authCalls += 1 },
            post: { postCalls += 1 }
        )
        XCTAssertEqual(postCalls, 0)
        XCTAssertEqual(authCalls, 0)
        // Change → posted exactly once.
        SystemServices.notifyIfChanged(
            previous: .green, current: .yellow,
            requestAuthorization: { authCalls += 1 },
            post: { postCalls += 1 }
        )
        XCTAssertEqual(postCalls, 1)
        XCTAssertEqual(authCalls, 1)
    }

    func testAuthorizationFailureDoesNotAffectCaller() {
        var postCalls = 0
        // Simulate a denial: requestAuthorization does nothing (never grants).
        SystemServices.notifyIfChanged(
            previous: .yellow, current: .green,
            requestAuthorization: {},
            post: { postCalls += 1 }
        )
        // Function returns normally and the caller flow is unaffected.
        XCTAssertEqual(postCalls, 1)
    }

    // MARK: - Login item four-state mapping

    func testLoginItemStateMapping() {
        XCTAssertEqual(SystemServices.loginItemState(from: .notRegistered), .notRegistered)
        XCTAssertEqual(SystemServices.loginItemState(from: .enabled), .enabled)
        XCTAssertEqual(SystemServices.loginItemState(from: .requiresApproval), .requiresApproval)
        XCTAssertEqual(SystemServices.loginItemState(from: .notFound), .notFound)
    }

    // MARK: - Registration decision / unsigned

    func testUnsignedBuildIsUnavailableAndNeverRegisters() {
        let d = SystemServices.resolveRegistration(
            isSigned: false, hasPreference: false, desired: false, registrationAttempted: false
        )
        XCTAssertEqual(d, .unavailable)
    }

    func testFirstLaunchWithNoPreferenceDefaultsToDisabled() {
        let d = SystemServices.resolveRegistration(
            isSigned: true, hasPreference: false, desired: false, registrationAttempted: false
        )
        XCTAssertEqual(d, .none)
    }

    func testDesiredNotAttemptedRegistersOnce() {
        let d = SystemServices.resolveRegistration(
            isSigned: true, hasPreference: true, desired: true, registrationAttempted: false
        )
        XCTAssertEqual(d, .register)
    }

    func testDesiredAndAlreadyAttemptedIsNoOp() {
        let d = SystemServices.resolveRegistration(
            isSigned: true, hasPreference: true, desired: true, registrationAttempted: true
        )
        XCTAssertEqual(d, .none, "must not re-register/bombard on every launch")
    }

    func testUndesiredUnregisters() {
        let d = SystemServices.resolveRegistration(
            isSigned: true, hasPreference: true, desired: false, registrationAttempted: true
        )
        XCTAssertEqual(d, .unregister)
    }

    // MARK: - UserDefaults two keys only

    func testReadWriteUsesOnlyTheTwoWhitelistedKeys() {
        var store: [String: Any] = [:]
        let write: (String, Any) -> Void = { store[$0] = $1 }
        let read: (String) -> Any? = { store[$0] }

        SystemServices.writeLoginPreference(desired: true, attempted: true, write: write)

        XCTAssertEqual(Set(store.keys), [SystemServices.loginAtLaunchDesiredKey, SystemServices.loginRegistrationAttemptedKey])
        XCTAssertTrue(store[SystemServices.loginAtLaunchDesiredKey] as? Bool == true)
        XCTAssertTrue(store[SystemServices.loginRegistrationAttemptedKey] as? Bool == true)

        let prefs = SystemServices.readLoginPreferences(read: read)
        XCTAssertTrue(prefs.hasPreference)
        XCTAssertTrue(prefs.desired)
        XCTAssertTrue(prefs.attempted)
    }

    func testReadNoPreferenceHasNone() {
        let prefs = SystemServices.readLoginPreferences(read: { _ in nil })
        XCTAssertFalse(prefs.hasPreference)
        XCTAssertFalse(prefs.desired)
        XCTAssertFalse(prefs.attempted)
    }

    // MARK: - Copy summary whitelist

    private func assertSanitized(_ text: String, _ label: String) {
        XCTAssertFalse(text.lowercased().contains("secret"), label)
        XCTAssertFalse(text.lowercased().contains("subscription"), label)
        XCTAssertFalse(text.lowercased().contains("订阅"), label)
        XCTAssertFalse(text.lowercased().contains("token"), label)
        XCTAssertFalse(text.lowercased().contains("http://"), label)
        XCTAssertFalse(text.lowercased().contains("https://"), label)
        XCTAssertFalse(text.lowercased().contains("节点"), label)
    }

    func testCopySummaryUsesOnlyWhitelistFields() {
        let state = DiagnosisState.green
        let evidence = [
            ProbeEvidence(category: .direct, outcome: .success, milliseconds: 12, userVisibleDescription: "直连目标可达"),
            ProbeEvidence(category: .proxy, outcome: .timeout, milliseconds: 3000, userVisibleDescription: "代理目标超时"),
        ]
        let summary = SystemServices.copySummary(state: state, evidence: evidence)
        XCTAssertTrue(summary.contains(state.title))
        XCTAssertTrue(summary.contains("直连：成功（12ms）直连目标可达"))
        XCTAssertTrue(summary.contains("代理：超时（3000ms）代理目标超时"))
        assertSanitized(summary, "copy summary")
    }

    func testCopySummaryGrayIncludesReason() {
        let gray = DiagnosisState(
            kind: .gray, symbolName: "q", title: "网络不可用或暂时无法定位", missingEvidenceExplanation: "直连与代理均无成功样本。"
        )
        let summary = SystemServices.copySummary(state: gray, evidence: [])
        XCTAssertTrue(summary.contains(gray.missingEvidenceExplanation))
        assertSanitized(summary, "gray summary")
    }
}
