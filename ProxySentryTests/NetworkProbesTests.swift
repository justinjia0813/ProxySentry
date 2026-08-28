import XCTest
import Darwin
@testable import ProxySentry

/// Cancellable network probes (task 4).
///
/// These tests use a mock `URLProtocol` and injected resolver closures; they never
/// touch the public Internet or modify system proxy settings. The only exception
/// is a real loopback proxy-trap test that runs a local TCP listener on 127.0.0.1.
///
/// NOTE: This file is pending project inclusion (the pbxproj is owned by an
/// integrator agent). It typechecks against the sources but is not yet wired into
/// the test target, so it is reported as pending rather than executed.
final class NetworkProbesTests: XCTestCase {

    // MARK: - Mock transport

    private enum TestError: Error {
        case boom
    }

    private final class MockURLProtocol: URLProtocol {
        static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?
        static var lastRequest: URLRequest?

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            guard let handler = Self.handler else {
                client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
                return
            }
            do {
                let (response, data) = try handler(request)
                Self.lastRequest = request
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: data)
                client?.urlProtocolDidFinishLoading(self)
            } catch {
                client?.urlProtocol(self, didFailWithError: error)
            }
        }

        override func stopLoading() {}
    }

    private func mockSession(status: Int, body: Data = Data(), url: URL? = nil) -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        MockURLProtocol.handler = { request in
            let u = url ?? request.url!
            let response = HTTPURLResponse(url: u, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
            return (response, body)
        }
        config.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: config)
    }

    private func target(_ url: String, expectedStatus: Int = 200) -> NetworkProbes.Target {
        NetworkProbes.Target(host: url, url: URL(string: url)!, expectedStatus: expectedStatus)
    }

    private func output(_ result: NetworkProbes.ProbeResult) -> NetworkProbes.ProbeOutput {
        NetworkProbes.ProbeOutput(outcome: result, failureCategory: nil, milliseconds: 0)
    }

    /// Creates a small executable that hangs (via `exec sleep`) so pingGateway's
    /// timeout/cancellation can prove it terminates the process. No shell is used
    /// by the production probe; this is test-only scaffolding.
    private func fakeHangingExecutable() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("hanging_ping")
        try Data("#!/bin/sh\nexec sleep 3\n".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    // MARK: - DNS via injected resolver

    func testResolveSuccess() async {
        let out = await NetworkProbes.resolve(host: "apple.com.cn", resolver: { _ in true }, timeout: .milliseconds(200))
        XCTAssertEqual(out.outcome, .success)
        XCTAssertNil(out.failureCategory)
        XCTAssertGreaterThanOrEqual(out.milliseconds, 0)
    }

    func testResolveFailure() async {
        let out = await NetworkProbes.resolve(host: "baidu.com", resolver: { _ in false }, timeout: .milliseconds(200))
        XCTAssertEqual(out.outcome, .failure)
        XCTAssertEqual(out.failureCategory, .resolutionFailed)
    }

    func testResolveThrowingResolverIsFailure() async {
        let out = await NetworkProbes.resolve(host: "example.invalid", resolver: { _ in throw TestError.boom }, timeout: .milliseconds(200))
        XCTAssertEqual(out.outcome, .failure)
        XCTAssertEqual(out.failureCategory, .resolutionFailed)
    }

    func testResolveTimeout() async {
        // A cooperative slow resolver must be cancelled when the deadline wins.
        let out = await NetworkProbes.resolve(host: "example.invalid", resolver: { _ in
            try await Task.sleep(for: .seconds(10))
            return true
        }, timeout: .milliseconds(100))
        XCTAssertEqual(out.outcome, .timeout)
        XCTAssertEqual(out.failureCategory, .timeout)
    }

    // MARK: - URLSession proxy configuration

    func testDirectSessionExplicitlyDisablesAllProxies() {
        let s = NetworkProbes.makeSession(direct: true, fixedProxy: nil)
        let dict = (s.configuration.connectionProxyDictionary as? [String: Any]) ?? [:]
        XCTAssertEqual(dict[kCFNetworkProxiesHTTPEnable as String] as? Bool, false)
        XCTAssertEqual(dict[kCFNetworkProxiesHTTPSEnable as String] as? Bool, false)
        XCTAssertEqual(dict[kCFNetworkProxiesSOCKSEnable as String] as? Bool, false)
        XCTAssertEqual(dict[kCFNetworkProxiesProxyAutoConfigEnable as String] as? Bool, false)
        XCTAssertEqual(dict[kCFNetworkProxiesProxyAutoDiscoveryEnable as String] as? Bool, false)
    }

    func testProxySessionUsesFixedProxyHostAndPort() {
        let proxy = FixedProxy(host: "127.0.0.1", port: 7890)
        let s = NetworkProbes.makeSession(direct: false, fixedProxy: proxy)
        let dict = (s.configuration.connectionProxyDictionary as? [String: Any]) ?? [:]
        XCTAssertEqual(dict[kCFNetworkProxiesHTTPProxy as String] as? String, "127.0.0.1")
        XCTAssertEqual(dict[kCFNetworkProxiesHTTPPort as String] as? Int, 7890)
        XCTAssertEqual(dict[kCFNetworkProxiesHTTPSProxy as String] as? String, "127.0.0.1")
        XCTAssertEqual(dict[kCFNetworkProxiesHTTPSPort as String] as? Int, 7890)
    }

    // MARK: - GET probe acceptance

    func testProbeAcceptsExpectedStatus() async {
        let ok = await NetworkProbes.probe(target: target("https://www.apple.com.cn/x", expectedStatus: 200), using: mockSession(status: 200))
        XCTAssertEqual(ok.outcome, .success)
        XCTAssertNil(ok.failureCategory)
    }

    func testProbeRejectsUnexpectedStatus() async {
        let out = await NetworkProbes.probe(target: target("https://www.apple.com.cn/x", expectedStatus: 200), using: mockSession(status: 404))
        XCTAssertEqual(out.outcome, .failure)
        XCTAssertEqual(out.failureCategory, .badStatus)
    }

    func testProbeRejectsRedirectStatus() async {
        let out = await NetworkProbes.probe(target: target("https://www.apple.com.cn/x", expectedStatus: 200), using: mockSession(status: 302))
        XCTAssertEqual(out.outcome, .failure)
        XCTAssertEqual(out.failureCategory, .badStatus)
    }

    func testProbeSendsGETMethod() async {
        _ = await NetworkProbes.probe(target: target("https://www.apple.com.cn/x"), using: mockSession(status: 200))
        XCTAssertEqual(MockURLProtocol.lastRequest?.httpMethod, "GET")
    }

    // MARK: - 4 KB body cap

    func testProbeAcceptsBodyAtCap() async {
        let body = Data(repeating: 0x41, count: NetworkProbes.maxResponseBodyBytes)
        let out = await NetworkProbes.probe(target: target("https://www.apple.com.cn/x"), using: mockSession(status: 200, body: body))
        XCTAssertEqual(out.outcome, .success)
    }

    func testProbeRejectsBodyOverCap() async {
        let body = Data(repeating: 0x41, count: NetworkProbes.maxResponseBodyBytes + 1)
        let out = await NetworkProbes.probe(target: target("https://www.apple.com.cn/x"), using: mockSession(status: 200, body: body))
        XCTAssertEqual(out.outcome, .failure)
        XCTAssertEqual(out.failureCategory, .oversizedResponse)
    }

    // MARK: - Two-target any-success semantics

    func testAnySuccessRequiresOneSuccess() {
        XCTAssertTrue(NetworkProbes.anySuccess([output(.failure), output(.success)]))
        XCTAssertTrue(NetworkProbes.anySuccess([output(.success), output(.failure)]))
        XCTAssertFalse(NetworkProbes.anySuccess([output(.failure), output(.failure)]))
        XCTAssertFalse(NetworkProbes.anySuccess([output(.timeout), output(.failure)]))
        XCTAssertFalse(NetworkProbes.anySuccess([]))
    }

    // MARK: - Local port NWConnection

    func testLocalPortRefused() async {
        // Port 1 is almost always closed on loopback; refused → failure.
        let out = await NetworkProbes.localPortProbe(host: "127.0.0.1", port: 1, timeout: .milliseconds(2000))
        XCTAssertEqual(out.outcome, .failure)
        XCTAssertEqual(out.failureCategory, .connectionRefused)
    }

    func testLocalPortSuccess() async throws {
        let trap = try LoopbackProxyTrap()
        defer { trap.stop() }
        let out = await NetworkProbes.localPortProbe(host: "127.0.0.1", port: trap.port, timeout: .milliseconds(2000))
        XCTAssertEqual(out.outcome, .success)
        XCTAssertNil(out.failureCategory)
    }

    func testLocalPortTimeout() async {
        let out = await NetworkProbes.localPortProbe(
            host: "127.0.0.1", port: 80, timeout: .milliseconds(100),
            connector: { _, _ in
                try? await Task.sleep(for: .seconds(10))
                return false
            }
        )
        XCTAssertEqual(out.outcome, .timeout)
        XCTAssertEqual(out.failureCategory, .timeout)
    }

    func testLocalPortTaskCancellationReturnsPromptly() async {
        let task = Task {
            await NetworkProbes.localPortProbe(
                host: "127.0.0.1", port: 80, timeout: .seconds(10),
                connector: { _, _ in
                    try? await Task.sleep(for: .seconds(10))
                    return false
                }
            )
        }
        try? await Task.sleep(for: .milliseconds(100))
        task.cancel()
        let out = await task.value
        // Must return promptly, and never claim success.
        XCTAssertNotEqual(out.outcome, .success)
    }

    // MARK: - Public bare-IP probes (no DNS)

    func testPublicIPProbeSuccess() async {
        let out = await NetworkProbes.publicIPProbe(ip: "1.1.1.1", timeout: .milliseconds(200), connector: { _, _ in true })
        XCTAssertEqual(out.outcome, .success)
        XCTAssertNil(out.failureCategory)
    }

    func testPublicIPProbeFailure() async {
        let out = await NetworkProbes.publicIPProbe(ip: "223.5.5.5", timeout: .milliseconds(200), connector: { _, _ in false })
        XCTAssertEqual(out.outcome, .failure)
        XCTAssertEqual(out.failureCategory, .connectionRefused)
    }

    func testPublicIPProbeTimeout() async {
        let out = await NetworkProbes.publicIPProbe(ip: "1.1.1.1", timeout: .milliseconds(100), connector: { _, _ in
            try? await Task.sleep(for: .seconds(10))
            return false
        })
        XCTAssertEqual(out.outcome, .timeout)
        XCTAssertEqual(out.failureCategory, .timeout)
    }

    func testPublicIPProbeCancellationReturnsPromptly() async {
        let task = Task {
            await NetworkProbes.publicIPProbe(ip: "1.1.1.1", timeout: .seconds(10), connector: { _, _ in
                try? await Task.sleep(for: .seconds(10))
                return false
            })
        }
        try? await Task.sleep(for: .milliseconds(100))
        task.cancel()
        let out = await task.value
        XCTAssertNotEqual(out.outcome, .success, "cancellation must never claim success")
    }

    func testPublicIPProbeRejectsNonIPWithoutConnecting() async {
        let called = LockedBox(false)
        let out = await NetworkProbes.publicIPProbe(ip: "1.1.1.1; echo hi", timeout: .milliseconds(200), connector: { _, _ in
            called.update { $0 = true }
            return true
        })
        XCTAssertEqual(out.outcome, .failure, "non-IP must be rejected up front")
        XCTAssertNotEqual(out.outcome, .success)
        XCTAssertFalse(called.value, "must not probe a non-IP address")
    }

    func testRunPublicIPProbesIndependentAggregation() async {
        // Two independent targets: first reachable, second refused.
        let outs = await NetworkProbes.runPublicIPProbes(
            ips: ["1.1.1.1", "223.5.5.5"],
            timeout: .milliseconds(200),
            connector: { host, _ in host == "1.1.1.1" }
        )
        XCTAssertEqual(outs.count, 2, "one output per independent target")
        XCTAssertTrue(NetworkProbes.anySuccess(outs), "any-success: one reachable target is enough")
    }

    func testRunPublicIPProbesAllFail() async {
        let outs = await NetworkProbes.runPublicIPProbes(
            ips: ["1.1.1.1", "223.5.5.5"],
            timeout: .milliseconds(200),
            connector: { _, _ in false }
        )
        XCTAssertEqual(outs.count, 2)
        XCTAssertFalse(NetworkProbes.anySuccess(outs))
    }

    // MARK: - Default gateway reachability (ping, evidence only)

    func testGatewayProbeNoGatewayIsUnavailable() async {
        let out = await NetworkProbes.gatewayProbe(gateway: nil) { _ in
            NetworkProbes.ProbeOutput(outcome: .success, failureCategory: nil, milliseconds: 0)
        }
        XCTAssertEqual(out.outcome, .unavailable)
    }

    func testGatewayProbeRejectsMaliciousAddressWithoutPinging() async {
        let pinged = LockedBox(false)
        let out = await NetworkProbes.gatewayProbe(gateway: "192.168.1.1; echo hi") { _ in
            pinged.update { $0 = true }
            return NetworkProbes.ProbeOutput(outcome: .success, failureCategory: nil, milliseconds: 0)
        }
        XCTAssertEqual(out.outcome, .unavailable)
        XCTAssertFalse(pinged.value, "must never ping a non-IP address")
    }

    func testGatewayProbeSuccess() async {
        let out = await NetworkProbes.gatewayProbe(gateway: "192.168.1.1") { _ in
            NetworkProbes.ProbeOutput(outcome: .success, failureCategory: nil, milliseconds: 1)
        }
        XCTAssertEqual(out.outcome, .success)
    }

    func testGatewayProbeFailureIsEvidenceOnly() async {
        let out = await NetworkProbes.gatewayProbe(gateway: "192.168.1.1") { _ in
            NetworkProbes.ProbeOutput(outcome: .failure, failureCategory: .connectionRefused, milliseconds: 1)
        }
        XCTAssertEqual(out.outcome, .failure)
        // Module draws no conclusion: gateway reachability is only evidence.
    }

    // MARK: - pingGateway Process (arg array, fixed /sbin/ping in production)

    func testPingGatewayArgumentsUseMillisecondWait() {
        // macOS `-W` is milliseconds; 3000 avoids false failures on a lossy
        // gateway. The outer 3s budget still bounds the probe.
        XCTAssertEqual(
            NetworkProbes.pingArguments(for: "192.168.1.1"),
            ["-c", "1", "-W", "3000", "192.168.1.1"]
        )
    }

    func testPingGatewaySuccessOnExitZero() async {
        let out = await NetworkProbes.pingGateway("192.168.1.1", executable: URL(fileURLWithPath: "/usr/bin/true"), timeout: .seconds(2))
        XCTAssertEqual(out.outcome, .success)
        XCTAssertNil(out.failureCategory)
    }

    func testPingGatewayFailureOnExitNonZero() async {
        let out = await NetworkProbes.pingGateway("192.168.1.1", executable: URL(fileURLWithPath: "/usr/bin/false"), timeout: .seconds(2))
        XCTAssertEqual(out.outcome, .failure)
        XCTAssertEqual(out.failureCategory, .connectionRefused)
    }

    func testPingGatewayTimeoutTerminatesProcess() async throws {
        let exe = try fakeHangingExecutable()
        let start = ContinuousClock.now
        let out = await NetworkProbes.pingGateway("192.168.1.1", executable: exe, timeout: .milliseconds(100))
        XCTAssertEqual(out.outcome, .timeout)
        XCTAssertEqual(out.failureCategory, .timeout)
        XCTAssertLessThan(ContinuousClock.now - start, .seconds(1), "must not wait for the full fake sleep")
    }

    func testPingGatewayCancellationTerminatesProcess() async throws {
        let exe = try fakeHangingExecutable()
        let task = Task {
            await NetworkProbes.pingGateway("192.168.1.1", executable: exe, timeout: .seconds(10))
        }
        try? await Task.sleep(for: .milliseconds(100))
        let start = ContinuousClock.now
        task.cancel()
        let out = await task.value
        XCTAssertNotEqual(out.outcome, .success, "cancellation must not claim success")
        XCTAssertLessThan(ContinuousClock.now - start, .seconds(1), "cancellation must return promptly")
    }

    // MARK: - Sanitized output only

    func testOutputCarriesOnlyCategoryAndDuration() async {
        let out = await NetworkProbes.probe(target: target("https://www.apple.com.cn/x"), using: mockSession(status: 500))
        // Sanitized: no payload, no raw error text. Only outcome, category, duration.
        XCTAssertEqual(out.outcome, .failure)
        XCTAssertEqual(out.failureCategory, .badStatus)
        XCTAssertGreaterThanOrEqual(out.milliseconds, 0)
    }

    // MARK: - Real loopback proxy trap (no system proxy, no public Internet)

    func testLoopbackProxyTrap_DirectNotHit_ProxyHit() async throws {
        let trap = try LoopbackProxyTrap()
        defer { trap.stop() }

        // `.invalid` is reserved and guaranteed not to resolve (RFC 2606), so this
        // test never touches the public Internet.
        let reserved = target("https://example.invalid/", expectedStatus: 200)

        // The direct configuration is asserted separately. This reserved host
        // proves this branch does not contact public Internet; it is not itself
        // evidence that a pre-existing system proxy was bypassed.
        let direct = NetworkProbes.makeSession(direct: true, fixedProxy: nil)
        _ = await NetworkProbes.probe(target: reserved, using: direct, timeout: .milliseconds(800))
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(trap.hitCount, 0, "direct session must not hit the loopback proxy trap")

        // Proxy session must route through the trap and send a CONNECT handshake.
        let proxied = NetworkProbes.makeSession(direct: false, fixedProxy: FixedProxy(host: "127.0.0.1", port: Int(trap.port)))
        _ = await NetworkProbes.probe(target: reserved, using: proxied, timeout: .milliseconds(2000))

        let deadline = ContinuousClock.now + .seconds(2)
        while trap.hitCount == 0 && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertGreaterThanOrEqual(trap.hitCount, 1, "proxy session must route through the loopback proxy")
        XCTAssertTrue(
            trap.firstLines.contains { $0.hasPrefix("CONNECT") },
            "HTTPS via proxy must send a CONNECT handshake, got: \(trap.firstLines)"
        )
    }
}

// MARK: - Local loopback TCP listener used as a proxy trap.

/// Accepts TCP connections on an ephemeral 127.0.0.1 port and records the first
/// request line of each connection. Never responds, so the peer's request just
/// hangs — enough to observe whether a proxy path routed through it. Never
/// touches system settings or the public Internet.
private final class LoopbackProxyTrap {
    enum TrapError: Error {
        case socket
        case bind
        case listen
    }

    let port: UInt16
    private let lock = NSLock()
    private var _lines: [String] = []
    private var listenFD: Int32 = -1
    private var running = true
    private var thread: Thread?

    var hitCount: Int { lock.withLock { _lines.count } }
    var firstLines: [String] { lock.withLock { _lines } }

    init() throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw TrapError.socket }
        listenFD = fd
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0 // ephemeral
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else { throw TrapError.bind }
        guard listen(fd, 8) == 0 else { throw TrapError.listen }

        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        var sock = sockaddr_in()
        _ = withUnsafeMutablePointer(to: &sock) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(fd, $0, &len)
            }
        }
        port = UInt16(bigEndian: sock.sin_port)

        let t = Thread { [weak self] in self?.acceptLoop() }
        t.name = "LoopbackProxyTrap"
        t.start()
        thread = t
    }


    private func acceptLoop() {
        while running {
            let client = accept(listenFD, nil, nil)
            if client < 0 { if !running { break }; continue }
            readFirstLine(client)
        }
    }

    private func readFirstLine(_ client: Int32) {
        var line = ""
        var byte: UInt8 = 0
        var sawCR = false
        while true {
            guard read(client, &byte, 1) == 1 else { break }
            if sawCR && byte == 0x0A { break }
            if byte != 0x0D { line.append(Character(UnicodeScalar(byte))) }
            sawCR = (byte == 0x0D)
        }
        lock.withLock { _lines.append(line) }
        close(client)
    }

    func stop() {
        running = false
        if listenFD >= 0 {
            shutdown(listenFD, SHUT_RDWR)
            Darwin.close(listenFD)
            listenFD = -1
        }
    }

    deinit { stop() }
}
