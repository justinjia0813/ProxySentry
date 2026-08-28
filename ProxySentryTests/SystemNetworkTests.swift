import XCTest
@testable import ProxySentry

final class SystemNetworkTests: XCTestCase {

    // MARK: - Pure proxy dictionary parsing

    private let httpEnabled: [String: Any] = [
        "HTTPEnable": 1, "HTTPProxy": "127.0.0.1", "HTTPPort": 7890,
    ]
    private let httpsEnabled: [String: Any] = [
        "HTTPSEnable": 1, "HTTPSProxy": "127.0.0.1", "HTTPSPort": 7891,
    ]
    private let socksEnabled: [String: Any] = [
        "SOCKSEnable": 1, "SOCKSProxy": "::1", "SOCKSPort": 7892,
    ]

    func testNoProxyDictionaryYieldsEmptySnapshot() {
        let s = SystemNetwork.parseProxies([:])
        XCTAssertFalse(s.hasAnyProxyPath)
        XCTAssertFalse(s.pacConfigured)
        XCTAssertFalse(s.autoDiscovery)
        XCTAssertNil(s.httpProxy)
        XCTAssertNil(s.httpsProxy)
        XCTAssertNil(s.socksProxy)
    }

    func testDisabledEntriesAreIgnored() {
        var d = httpEnabled
        d["HTTPEnable"] = 0
        let s = SystemNetwork.parseProxies(d)
        XCTAssertNil(s.httpProxy)
        XCTAssertFalse(s.hasAnyProxyPath)
    }

    func testHTTPProxyParsedAsLocalFixedEndpoint() {
        let s = SystemNetwork.parseProxies(httpEnabled)
        XCTAssertEqual(s.httpProxy, FixedProxy(host: "127.0.0.1", port: 7890))
        XCTAssertEqual(s.httpProxy?.isLoopback, true)
        XCTAssertTrue(s.hasAnyProxyPath)
        XCTAssertFalse(s.pacConfigured)
        XCTAssertFalse(s.autoDiscovery)
    }

    func testHTTPSProxyParsed() {
        let s = SystemNetwork.parseProxies(httpsEnabled)
        XCTAssertEqual(s.httpsProxy, FixedProxy(host: "127.0.0.1", port: 7891))
        XCTAssertEqual(s.httpsProxy?.isLoopback, true)
    }

    func testSOCKSProxyParsedWithIPv6Loopback() {
        let s = SystemNetwork.parseProxies(socksEnabled)
        XCTAssertEqual(s.socksProxy, FixedProxy(host: "::1", port: 7892))
        XCTAssertEqual(s.socksProxy?.isLoopback, true)
    }

    func testLocalhostCountsAsLoopback() {
        let s = SystemNetwork.parseProxies([
            "HTTPEnable": 1, "HTTPProxy": "localhost", "HTTPPort": 7890,
        ])
        XCTAssertEqual(s.httpProxy?.isLoopback, true)
    }

    func testNonLocalProxyIsConfiguredButNotLoopback() {
        let s = SystemNetwork.parseProxies([
            "HTTPEnable": 1, "HTTPProxy": "192.168.1.10", "HTTPPort": 8080,
        ])
        XCTAssertEqual(s.httpProxy, FixedProxy(host: "192.168.1.10", port: 8080))
        XCTAssertEqual(s.httpProxy?.isLoopback, false)
        XCTAssertTrue(s.hasAnyProxyPath)
    }

    func testEnabledProxyMissingHostIsIgnored() {
        let s = SystemNetwork.parseProxies(["HTTPEnable": 1, "HTTPPort": 7890])
        XCTAssertNil(s.httpProxy)
        XCTAssertFalse(s.hasAnyProxyPath)
    }

    func testEnabledProxyMissingPortIsIgnored() {
        let s = SystemNetwork.parseProxies(["HTTPEnable": 1, "HTTPProxy": "127.0.0.1"])
        XCTAssertNil(s.httpProxy)
        XCTAssertFalse(s.hasAnyProxyPath)
    }

    // MARK: - Strict port bounds (1...65535)

    func testPortZeroIsRejected() {
        let s = SystemNetwork.parseProxies([
            "HTTPEnable": 1, "HTTPProxy": "127.0.0.1", "HTTPPort": 0,
        ])
        XCTAssertNil(s.httpProxy)
        XCTAssertFalse(s.hasAnyProxyPath)
    }

    func testPortOver65535IsRejected() {
        let s = SystemNetwork.parseProxies([
            "HTTPEnable": 1, "HTTPProxy": "127.0.0.1", "HTTPPort": 65536,
        ])
        XCTAssertNil(s.httpProxy)
        XCTAssertFalse(s.hasAnyProxyPath)
    }

    func testPort65535IsAccepted() {
        let s = SystemNetwork.parseProxies([
            "HTTPEnable": 1, "HTTPProxy": "127.0.0.1", "HTTPPort": 65535,
        ])
        XCTAssertEqual(s.httpProxy, FixedProxy(host: "127.0.0.1", port: 65535))
        XCTAssertTrue(s.hasAnyProxyPath)
    }

    // MARK: - Strict port typing (reject Bool / non-integral)

    func testBoolPortIsRejected() {
        let s = SystemNetwork.parseProxies([
            "HTTPEnable": 1, "HTTPProxy": "127.0.0.1", "HTTPPort": true,
        ])
        XCTAssertNil(s.httpProxy)
        XCTAssertFalse(s.hasAnyProxyPath)
    }

    func testCFBooleanPortIsRejected() {
        let s = SystemNetwork.parseProxies([
            "HTTPEnable": 1, "HTTPProxy": "127.0.0.1", "HTTPPort": NSNumber(value: true),
        ])
        XCTAssertNil(s.httpProxy)
    }

    func testFloatPortIsRejected() {
        let s = SystemNetwork.parseProxies([
            "HTTPEnable": 1, "HTTPProxy": "127.0.0.1", "HTTPPort": NSNumber(value: 7890.5),
        ])
        XCTAssertNil(s.httpProxy)
    }

    func testIntegralNSNumberPortIsAccepted() {
        let s = SystemNetwork.parseProxies([
            "HTTPEnable": 1, "HTTPProxy": "127.0.0.1", "HTTPPort": NSNumber(value: 7890),
        ])
        XCTAssertEqual(s.httpProxy, FixedProxy(host: "127.0.0.1", port: 7890))
    }

    // MARK: - NSNumber / Bool bridging

    func testBoolEnableFlagEnablesProxy() {
        let s = SystemNetwork.parseProxies([
            "HTTPEnable": true, "HTTPProxy": "127.0.0.1", "HTTPPort": 7890,
        ])
        XCTAssertEqual(s.httpProxy, FixedProxy(host: "127.0.0.1", port: 7890))
    }

    func testBoolFalseDisablesProxy() {
        let s = SystemNetwork.parseProxies([
            "HTTPEnable": false, "HTTPProxy": "127.0.0.1", "HTTPPort": 7890,
        ])
        XCTAssertNil(s.httpProxy)
        XCTAssertFalse(s.hasAnyProxyPath)
    }

    func testNSNumberEnableFlagAndPortAreParsed() {
        let s = SystemNetwork.parseProxies([
            "HTTPEnable": NSNumber(value: 1),
            "HTTPProxy": "127.0.0.1",
            "HTTPPort": NSNumber(value: 7890),
        ])
        XCTAssertEqual(s.httpProxy, FixedProxy(host: "127.0.0.1", port: 7890))
    }

    func testPACAndAutoDiscoveryAcceptBoolAndNSNumberFlags() {
        XCTAssertTrue(SystemNetwork.parseProxies(["ProxyAutoConfigEnable": true]).pacConfigured)
        XCTAssertTrue(SystemNetwork.parseProxies(["ProxyAutoConfigEnable": NSNumber(value: 1)]).pacConfigured)
        XCTAssertTrue(SystemNetwork.parseProxies(["ProxyAutoDiscoveryEnable": true]).autoDiscovery)
        XCTAssertTrue(SystemNetwork.parseProxies(["ProxyAutoDiscoveryEnable": NSNumber(value: 1)]).autoDiscovery)
    }

    func testPACConfiguredWithoutFixedEndpoint() {
        let s = SystemNetwork.parseProxies([
            "ProxyAutoConfigEnable": 1,
            "ProxyAutoConfigURLString": "file:///dev/null", // must never be executed
        ])
        XCTAssertTrue(s.pacConfigured)
        XCTAssertTrue(s.hasAnyProxyPath)
        XCTAssertNil(s.httpProxy)
    }

    func testAutoDiscoveryConfigured() {
        let s = SystemNetwork.parseProxies(["ProxyAutoDiscoveryEnable": 1])
        XCTAssertTrue(s.autoDiscovery)
        XCTAssertTrue(s.hasAnyProxyPath)
    }

    func testAllTogether() {
        var d = httpEnabled
        d.merge(httpsEnabled) { a, _ in a }
        d["ProxyAutoConfigEnable"] = 0
        let s = SystemNetwork.parseProxies(d)
        XCTAssertEqual(s.httpProxy?.port, 7890)
        XCTAssertEqual(s.httpsProxy?.port, 7891)
        XCTAssertFalse(s.pacConfigured)
    }

    // MARK: - PathSnapshot

    func testPathSnapshotEqualityAndDefaults() {
        let p = PathSnapshot(satisfied: true, interfaceType: "wifi", supportsDNS: true)
        XCTAssertTrue(p.satisfied)
        XCTAssertEqual(p.interfaceType, "wifi")
        XCTAssertTrue(p.supportsDNS)
        XCTAssertEqual(p, PathSnapshot(satisfied: true, interfaceType: "wifi", supportsDNS: true))
        XCTAssertNotEqual(p, PathSnapshot(satisfied: false, interfaceType: "wifi", supportsDNS: true))
    }

    // MARK: - Proxy observer emission semantics

    func testObserverEmitsExactlyOncePerChangeWhileRunning() async {
        let first = expectation(description: "first change emitted")
        let second = expectation(description: "second change emitted")
        var count = 0
        let obs = ProxyObserver {
            count += 1
            switch count {
            case 1: first.fulfill()
            case 2: second.fulfill()
            default: break
            }
        }
        obs.start()
        obs.emitChange()   // one proxy change (hops to main async)
        obs.emitChange()   // a second change
        await fulfillment(of: [first, second], timeout: 2)
        XCTAssertEqual(count, 2)
        obs.stop()
        obs.emitChange()   // after stop: must not callback
        try? await Task.sleep(for: .milliseconds(50)) // let any stray main hop run
        XCTAssertEqual(count, 2)
    }

    func testObserverIsIdempotentOnStartStop() async {
        let emitted = expectation(description: "recheck emitted")
        var count = 0
        let obs = ProxyObserver {
            count += 1
            emitted.fulfill()
        }
        obs.start()
        obs.start()  // second start must not double-register or crash
        obs.emitChange()
        await fulfillment(of: [emitted], timeout: 2)
        XCTAssertEqual(count, 1)
        obs.stop()
        obs.stop()  // second stop must be safe
        obs.emitChange()
        try? await Task.sleep(for: .milliseconds(50)) // let any stray main hop run
        XCTAssertEqual(count, 1)
    }

    /// The SCDynamicStore context box must not keep the observer alive; once the
    /// observer deallocates, a queued callback reads a nil observer and no-ops.
    func testContextBoxHoldsWeakObserver() {
        var observer: ProxyObserver? = ProxyObserver(onRecheck: {})
        let box = ProxyObserverContext(observer: observer!)
        XCTAssertTrue(box.observer === observer)
        observer = nil
        XCTAssertNil(box.observer, "context box must not retain the observer (weak ref)")
    }

    /// onRecheck drives controller work that calls stop(); must not self-deadlock.
    func testReentrantStopFromOnRecheckDoesNotDeadlock() async {
        let invoked = expectation(description: "recheck invoked")
        var obsRef: ProxyObserver?
        let obs = ProxyObserver {
            invoked.fulfill()
            obsRef?.stop()
        }
        obsRef = obs
        obs.start()
        obs.emitChange()
        await fulfillment(of: [invoked], timeout: 2)
        XCTAssertFalse(obs.isRunning)
    }

    /// Live start/stop against the real SCDynamicStore: verifies the store can be
    /// created, the notification key registered, and the queue detached without
    /// crashing or leaking callbacks. Cannot drive a real system proxy change from
    /// a unit test without mutating user settings (out of scope).
    func testLiveObserverStartStopRoundTrip() {
        var count = 0
        let obs = ProxyObserver { count += 1 }
        obs.start()
        XCTAssertTrue(obs.isRunning)
        obs.stop()
        XCTAssertFalse(obs.isRunning)
        XCTAssertEqual(count, 0) // no spurious callbacks
    }

    // MARK: - Default gateway & IP validation

    func testIsIPAddressAcceptsIPv4AndIPv6() {
        XCTAssertTrue(SystemNetwork.isIPAddress("192.168.1.1"))
        XCTAssertTrue(SystemNetwork.isIPAddress("8.8.8.8"))
        XCTAssertTrue(SystemNetwork.isIPAddress("::1"))
        XCTAssertTrue(SystemNetwork.isIPAddress("fe80::1"))
    }

    func testIsIPAddressRejectsInvalidInput() {
        XCTAssertFalse(SystemNetwork.isIPAddress(""))
        XCTAssertFalse(SystemNetwork.isIPAddress("localhost"))
        XCTAssertFalse(SystemNetwork.isIPAddress("router"))
        XCTAssertFalse(SystemNetwork.isIPAddress("192.168.1"))         // partial
        XCTAssertFalse(SystemNetwork.isIPAddress("999.999.999.999"))   // out of range
        XCTAssertFalse(SystemNetwork.isIPAddress("1.1.1.1/24"))        // CIDR
        XCTAssertFalse(SystemNetwork.isIPAddress("[::1]"))             // bracketed
        XCTAssertFalse(SystemNetwork.isIPAddress("127.0.0.1; echo hi")) // metachar
        XCTAssertFalse(SystemNetwork.isIPAddress("1.1.1.1;rm -rf /"))
    }

    /// Read-only smoke test: the default gateway is either absent (nil) or a
    /// valid bare IP. Never mutates system state.
    func testDefaultGatewayIsValidIPOrNil() {
        if let gw = SystemNetwork.defaultGateway() {
            XCTAssertTrue(SystemNetwork.isIPAddress(gw), "defaultGateway must be a bare IP, got \(gw)")
        }
    }
}
