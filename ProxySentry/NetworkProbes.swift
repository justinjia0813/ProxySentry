import Foundation
import Network

/// Cancellable network probes for one diagnosis round.
///
/// Every probe returns a sanitized `ProbeOutput`: outcome, a coarse failure
/// category, and duration in milliseconds. Raw errors, response bodies, secrets
/// and proxy payloads never cross this boundary.
///
/// Injection seams (closures only, no protocols):
/// - DNS: `resolve(host:resolver:)` takes a resolver closure.
/// - HTTP: `probe(target:using:)` takes an already-configured `URLSession`.
///
/// Production calls `makeSession` to build the real direct / proxied session;
/// tests supply a `URLSession` backed by a mock `URLProtocol`. No real
/// public Internet or system-proxy settings are ever required.
enum NetworkProbes {

    /// Single-probe timeout.
    static let timeout = Duration.seconds(3)
    /// Maximum accepted HTTP response body in bytes (4 KB).
    static let maxResponseBodyBytes = 4096

    // MARK: - Target definitions

    /// One fixed probe target. `expectedStatus` is the only accepted status; a
    /// redirect or any other status is treated as a failure.
    struct Target: Equatable, Sendable {
        let host: String
        let url: URL
        let expectedStatus: Int

        init(host: String, url: URL, expectedStatus: Int) {
            self.host = host
            self.url = url
            self.expectedStatus = expectedStatus
        }
    }

    /// Direct (bypass-proxy) targets. Only HTTP 200 is accepted.
    static let directTargets: [Target] = [
        Target(host: "www.apple.com.cn", url: URL(string: "https://www.apple.com.cn/library/test/success.html")!, expectedStatus: 200),
        Target(host: "www.baidu.com", url: URL(string: "https://www.baidu.com/favicon.ico")!, expectedStatus: 200),
    ]

    /// Proxy (through local proxy) targets. Only HTTP 204 is accepted.
    static let proxyTargets: [Target] = [
        Target(host: "www.gstatic.com", url: URL(string: "https://www.gstatic.com/generate_204")!, expectedStatus: 204),
        Target(host: "cp.cloudflare.com", url: URL(string: "https://cp.cloudflare.com/generate_204")!, expectedStatus: 204),
    ]

    /// Bare domains resolved by the injected resolver.
    static let dnsHosts = ["apple.com.cn", "baidu.com"]

    // MARK: - Sanitized result types

    /// Outcome of a single probe. Mirrors `ProbeOutcome` in Diagnosis.swift so the
    /// task-6 integrator can map it 1:1.
    enum ProbeResult: Equatable, Sendable {
        case success
        case failure
        case timeout
        case unavailable
    }

    /// Coarse, sanitized failure category. Never carries raw error text.
    enum ProbeFailureCategory: String, Equatable, Sendable {
        case resolutionFailed
        case connectionRefused
        case timeout
        case badStatus
        case oversizedResponse
        case transport
    }

    /// Sanitized probe output: outcome, category, duration only.
    struct ProbeOutput: Equatable, Sendable {
        let outcome: ProbeResult
        let failureCategory: ProbeFailureCategory?
        let milliseconds: Int
    }

    // MARK: - Session construction

    /// Build a URLSession for a probe.
    ///
    /// - `direct`: explicitly disables HTTP/HTTPS/SOCKS/PAC/auto-discovery
    ///   proxies so the request truly bypasses the system proxy.
    /// - `fixedProxy != nil`: routes HTTP and HTTPS through that FixedProxy.
    ///
    /// Every probe session carries a shared delegate that rejects redirects, and
    /// each probe request enforces a 3-second timeout and the 4 KB body cap.
    static func makeSession(direct: Bool, fixedProxy: FixedProxy?) -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeoutSeconds
        config.timeoutIntervalForResource = timeoutSeconds
        if direct {
            config.connectionProxyDictionary = [
                kCFNetworkProxiesHTTPEnable: false,
                kCFNetworkProxiesHTTPSEnable: false,
                kCFNetworkProxiesSOCKSEnable: false,
                kCFNetworkProxiesProxyAutoConfigEnable: false,
                kCFNetworkProxiesProxyAutoDiscoveryEnable: false,
            ]
        } else if let fixedProxy {
            config.connectionProxyDictionary = [
                kCFNetworkProxiesHTTPEnable: true,
                kCFNetworkProxiesHTTPProxy: fixedProxy.host,
                kCFNetworkProxiesHTTPPort: fixedProxy.port,
                kCFNetworkProxiesHTTPSEnable: true,
                kCFNetworkProxiesHTTPSProxy: fixedProxy.host,
                kCFNetworkProxiesHTTPSPort: fixedProxy.port,
            ]
        }
        // A shared, stateless delegate rejects HTTP redirects (completionHandler(nil))
        // so no probe ever follows a 3xx detour. This SDK exposes no
        // httpShouldFollowRedirects configuration flag.
        return URLSession(configuration: config, delegate: RedirectRejectingDelegate.shared, delegateQueue: nil)
    }

    // MARK: - DNS

    /// System resolver for a hostname. Runs the blocking `getaddrinfo` off the
    /// caller's executor so a stuck lookup never blocks the probe task.
    static func systemResolver(_ host: String) async -> Bool {
        await Task.detached(priority: .utility) {
            Self.resolveSync(host)
        }.value
    }

    /// Resolve `host` through an injected resolver with a 3-second timeout.
    static func resolve(
        host: String,
        resolver: @escaping @Sendable (String) async throws -> Bool,
        timeout: Duration = NetworkProbes.timeout
    ) async -> ProbeOutput {
        let start = ContinuousClock.now
        let run = await withTimeout(timeout) { try await resolver(host) }
        let ms = elapsedMs(from: start)
        switch run {
        case .timedOut:
            return ProbeOutput(outcome: .timeout, failureCategory: .timeout, milliseconds: ms)
        case .failed:
            return ProbeOutput(outcome: .failure, failureCategory: .resolutionFailed, milliseconds: ms)
        case .value(let ok):
            return ok
                ? ProbeOutput(outcome: .success, failureCategory: nil, milliseconds: ms)
                : ProbeOutput(outcome: .failure, failureCategory: .resolutionFailed, milliseconds: ms)
        }
    }

    // MARK: - HTTP probes

    /// Run one GET probe against `target` using `session`. `session` is the seam:
    /// production uses `makeSession`, tests use a mock `URLProtocol` session.
    static func probe(
        target: Target,
        using session: URLSession,
        timeout: Duration = NetworkProbes.timeout
    ) async -> ProbeOutput {
        let start = ContinuousClock.now
        let run = await withTimeout(timeout) {
            await performGET(target: target, using: session)
        }
        let ms = elapsedMs(from: start)
        switch run {
        case .timedOut:
            return ProbeOutput(outcome: .timeout, failureCategory: .timeout, milliseconds: ms)
        case .failed:
            return ProbeOutput(outcome: .failure, failureCategory: .transport, milliseconds: ms)
        case .value(let out):
            return ProbeOutput(outcome: out.outcome, failureCategory: out.failureCategory, milliseconds: ms)
        }
    }

    /// Probe every direct target concurrently. One sanitized output per target.
    static func runDirectProbes(_ targets: [Target] = directTargets) async -> [ProbeOutput] {
        await map(targets) { await runDirectProbe(target: $0) }
    }

    /// Probe every proxy target through `fixedProxy` concurrently.
    static func runProxyProbes(_ targets: [Target] = proxyTargets, via fixedProxy: FixedProxy) async -> [ProbeOutput] {
        await map(targets) { await runProxyProbe(target: $0, via: fixedProxy) }
    }

    static func runDirectProbe(target: Target) async -> ProbeOutput {
        await usingSession(direct: true, fixedProxy: nil) { session in
            await probe(target: target, using: session)
        }
    }

    static func runProxyProbe(target: Target, via fixedProxy: FixedProxy) async -> ProbeOutput {
        await usingSession(direct: false, fixedProxy: fixedProxy) { session in
            await probe(target: target, using: session)
        }
    }

    /// Any-success aggregation for a two-target pair: success if any succeeded,
    /// failure only if every target failed (or timed out), else unavailable.
    static func anySuccess(_ outputs: [ProbeOutput]) -> Bool {
        outputs.contains { $0.outcome == .success }
    }

    // MARK: - Local port (NWConnection)

    /// Connection-only check of a TCP endpoint. Sends no business data; just
    /// verifies a connection can be established, then cancels.
    ///
    /// The endpoint's host may be a hostname that needs resolution, so the check
    /// is wrapped in the same 3-second timeout.
    typealias Connector = @Sendable (String, UInt16) async -> Bool

    static func localPortProbe(
        host: String,
        port: UInt16,
        timeout: Duration = NetworkProbes.timeout,
        connector: Connector? = nil
    ) async -> ProbeOutput {
        let start = ContinuousClock.now
        let connect = connector ?? { host, port in
            await connectOnly(host: host, port: port)
        }
        let run = await withTimeout(timeout) {
            await connect(host, port)
        }
        let ms = elapsedMs(from: start)
        switch run {
        case .timedOut:
            return ProbeOutput(outcome: .timeout, failureCategory: .timeout, milliseconds: ms)
        case .failed:
            return ProbeOutput(outcome: .failure, failureCategory: .connectionRefused, milliseconds: ms)
        case .value(let ok):
            return ok
                ? ProbeOutput(outcome: .success, failureCategory: nil, milliseconds: ms)
                : ProbeOutput(outcome: .failure, failureCategory: .connectionRefused, milliseconds: ms)
        }
    }

    // MARK: - Public bare-IP probes (no DNS)

    /// Two independent public IPs probed on TCP 443 without any DNS lookup.
    /// 1.1.1.1 (Cloudflare) and 223.5.5.5 (AliDNS) — both reachable from CN without
    /// relying on 8.8.8.8, which network environments may block (false positives).
    static let publicIPAddresses: [String] = ["1.1.1.1", "223.5.5.5"]
    static let publicIPPort: UInt16 = 443

    /// TCP-connect probe to a public IP (no DNS). Reuses the standard timeout and
    /// sanitized ProbeOutput. Non-IP addresses are rejected up front.
    static func publicIPProbe(
        ip: String,
        port: UInt16 = NetworkProbes.publicIPPort,
        timeout: Duration = NetworkProbes.timeout,
        connector: Connector? = nil
    ) async -> ProbeOutput {
        guard SystemNetwork.isIPAddress(ip) else {
            return ProbeOutput(outcome: .failure, failureCategory: .transport, milliseconds: 0)
        }
        return await localPortProbe(host: ip, port: port, timeout: timeout, connector: connector)
    }

    /// Probe every public IP concurrently; one sanitized output per address.
    static func runPublicIPProbes(
        ips: [String] = NetworkProbes.publicIPAddresses,
        port: UInt16 = NetworkProbes.publicIPPort,
        timeout: Duration = NetworkProbes.timeout,
        connector: Connector? = nil
    ) async -> [ProbeOutput] {
        await withTaskGroup(of: (Int, ProbeOutput).self) { group in
            for (index, ip) in ips.enumerated() {
                group.addTask {
                    (index, await publicIPProbe(ip: ip, port: port, timeout: timeout, connector: connector))
                }
            }
            var results = [ProbeOutput?](repeating: nil, count: ips.count)
            for await (index, value) in group { results[index] = value }
            return results.compactMap { $0 }
        }
    }

    // MARK: - Default gateway reachability (ping, evidence only)

    /// Probe default-gateway reachability. `gateway` is the validated IP (nil when
    /// there is no default route / invalid value). `ping` is the injection seam;
    /// production uses `pingGateway`. A gateway failure is only evidence here —
    /// this module draws no conclusion.
    static func gatewayProbe(
        gateway: String?,
        ping: @escaping @Sendable (String) async -> ProbeOutput
    ) async -> ProbeOutput {
        guard let gateway, SystemNetwork.isIPAddress(gateway) else {
            return ProbeOutput(outcome: .unavailable, failureCategory: nil, milliseconds: 0)
        }
        return await ping(gateway)
    }

    /// Build the `/sbin/ping` argument array for one gateway probe. On macOS
    /// `-W` is in milliseconds (3000 ms per-packet wait), so a slow/lossy gateway
    /// is not a false failure; the outer 3-second budget still bounds the whole
    /// probe. Argument array only — never a shell.
    static func pingArguments(for gateway: String) -> [String] {
        ["-c", "1", "-W", "3000", gateway]
    }

    /// Production gateway ping: fixed `/sbin/ping`, argument array (never a shell).
    /// `executable` is injectable for tests. Cancellation terminates the process so
    /// it can never outlive the budget.
    static func pingGateway(
        _ gateway: String,
        executable: URL = URL(fileURLWithPath: "/sbin/ping"),
        timeout: Duration = NetworkProbes.timeout
    ) async -> ProbeOutput {
        let start = ContinuousClock.now
        let run = await withTimeout(timeout) {
            await runPingProcess(gateway: gateway, executable: executable)
        }
        let ms = elapsedMs(from: start)
        switch run {
        case .timedOut:
            return ProbeOutput(outcome: .timeout, failureCategory: .timeout, milliseconds: ms)
        case .failed:
            return ProbeOutput(outcome: .failure, failureCategory: .transport, milliseconds: ms)
        case .value(let ok):
            return ok
                ? ProbeOutput(outcome: .success, failureCategory: nil, milliseconds: ms)
                : ProbeOutput(outcome: .failure, failureCategory: .connectionRefused, milliseconds: ms)
        }
    }

    // MARK: - Private helpers

    private static let timeoutSeconds: TimeInterval = 3

    /// Lock-protected holder for one ping Process + its continuation, so a timeout
    /// or task-cancel can terminate the process and resume exactly once.
    private final class PingAttempt: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Bool, Never>?
        private var process: Process?
        private var finished = false

        func install(_ c: CheckedContinuation<Bool, Never>) {
            lock.lock()
            if finished { lock.unlock(); c.resume(returning: false); return }
            continuation = c
            lock.unlock()
        }

        func install(_ p: Process) -> Bool {
            lock.lock()
            guard !finished else {
                // Cancelled before launch: nothing to terminate (p not running).
                lock.unlock()
                return false
            }
            process = p
            lock.unlock()
            return true
        }

        func finish(_ ok: Bool) {
            lock.lock()
            guard !finished else { lock.unlock(); return }
            finished = true
            let c = continuation; continuation = nil
            let p = process; process = nil
            lock.unlock()
            // Only terminate a launched process; terminating an unlaunched or
            // already-exited one throws.
            if let p, p.isRunning { p.terminate() }
            c?.resume(returning: ok)
        }
    }

    private static func runPingProcess(gateway: String, executable: URL) async -> Bool {
        let attempt = PingAttempt()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
                attempt.install(c)
                let process = Process()
                process.executableURL = executable
                process.arguments = Self.pingArguments(for: gateway)
                process.standardOutput = Pipe()
                process.standardError = Pipe()
                process.terminationHandler = { p in attempt.finish(p.terminationStatus == 0) }
                guard attempt.install(process) else { return }
                do { try process.run() } catch { attempt.finish(false) }
            }
        } onCancel: {
            attempt.finish(false)
        }
    }

    private static func resolveSync(_ host: String) -> Bool {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        var result: UnsafeMutablePointer<addrinfo>?
        defer { if let result { freeaddrinfo(result) } }
        return getaddrinfo(host, nil, &hints, &result) == 0
    }

    private static func performGET(target: Target, using session: URLSession) async -> ProbeOutput {
        var request = URLRequest(url: target.url)
        request.httpMethod = "GET"
        request.timeoutInterval = timeoutSeconds
        do {
            let (bytes, response) = try await session.bytes(
                for: request,
                delegate: RedirectRejectingDelegate.shared
            )
            guard let http = response as? HTTPURLResponse else {
                bytes.task.cancel()
                return ProbeOutput(outcome: .failure, failureCategory: .transport, milliseconds: 0)
            }
            if http.statusCode != target.expectedStatus {
                bytes.task.cancel()
                return ProbeOutput(outcome: .failure, failureCategory: .badStatus, milliseconds: 0)
            }
            var count = 0
            for try await _ in bytes {
                count += 1
                if count > maxResponseBodyBytes {
                    bytes.task.cancel()
                    return ProbeOutput(outcome: .failure, failureCategory: .oversizedResponse, milliseconds: 0)
                }
            }
            return ProbeOutput(outcome: .success, failureCategory: nil, milliseconds: 0)
        } catch let error as URLError {
            return ProbeOutput(outcome: .failure, failureCategory: category(for: error), milliseconds: 0)
        } catch {
            return ProbeOutput(outcome: .failure, failureCategory: .transport, milliseconds: 0)
        }
    }

    private static func category(for error: URLError) -> ProbeFailureCategory {
        switch error.code {
        case .timedOut:
            return .timeout
        case .cannotConnectToHost, .networkConnectionLost:
            return .connectionRefused
        case .cannotFindHost, .dnsLookupFailed:
            return .resolutionFailed
        case .cancelled:
            return .transport
        default:
            return .transport
        }
    }

    /// Establish (or fail to establish) a TCP connection, then cancel it. No bytes sent.
    /// Registers a cancellation handler so a timeout or task cancel also cancels the
    /// NWConnection instead of leaking it until the OS gives up on the SYN.
    private final class ConnectionAttempt: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Bool, Never>?
        private var connection: NWConnection?
        private var finished = false

        func install(_ continuation: CheckedContinuation<Bool, Never>) {
            lock.lock()
            if finished {
                lock.unlock()
                continuation.resume(returning: false)
                return
            }
            self.continuation = continuation
            lock.unlock()
        }

        func install(_ connection: NWConnection) -> Bool {
            lock.lock()
            guard !finished else {
                lock.unlock()
                connection.cancel()
                return false
            }
            self.connection = connection
            lock.unlock()
            return true
        }

        func finish(_ value: Bool) {
            lock.lock()
            guard !finished else { lock.unlock(); return }
            finished = true
            let continuation = continuation
            self.continuation = nil
            let connection = connection
            self.connection = nil
            lock.unlock()
            connection?.cancel()
            continuation?.resume(returning: value)
        }
    }

    private static func connectOnly(host: String, port: UInt16) async -> Bool {
        let state = ConnectionAttempt()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                state.install(continuation)
                guard !Task.isCancelled else { state.finish(false); return }
                let connection = NWConnection(
                    host: .init(host),
                    port: .init(rawValue: port)!,
                    using: .tcp
                )
                guard state.install(connection) else { return }
                connection.stateUpdateHandler = { newState in
                    switch newState {
                    case .ready:
                        state.finish(true)
                    case .waiting, .failed, .cancelled:
                        state.finish(false)
                    default:
                        break
                    }
                }
                connection.start(queue: .global(qos: .utility))
            }
        } onCancel: {
            state.finish(false)
        }
    }

    private static func usingSession<T>(
        direct: Bool,
        fixedProxy: FixedProxy?,
        _ body: @Sendable (URLSession) async -> T
    ) async -> T {
        let session = makeSession(direct: direct, fixedProxy: fixedProxy)
        defer { session.finishTasksAndInvalidate() }
        return await body(session)
    }

    private static func map<T: Sendable>(_ items: [Target], _ body: @escaping @Sendable (Target) async -> T) async -> [T] {
        await withTaskGroup(of: (Int, T).self) { group in
            for (index, item) in items.enumerated() {
                group.addTask { (index, await body(item)) }
            }
            var results = [T?](repeating: nil, count: items.count)
            for await (index, value) in group { results[index] = value }
            return results.compactMap { $0 }
        }
    }

    /// Rejects HTTP redirects so a probe is never dragged onto a 3xx detour.
    /// Stateless and shared; the session must outlive tasks, which `usingSession`
    /// guarantees by holding the session until the probe completes.
    private final class RedirectRejectingDelegate: NSObject, URLSessionTaskDelegate {
        static let shared = RedirectRejectingDelegate()
        func urlSession(
            _ session: URLSession,
            task: URLSessionTask,
            willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest,
            completionHandler: @escaping (URLRequest?) -> Void
        ) {
            completionHandler(nil)
        }
    }

    /// Run `work` under `timeout`. `.timedOut` when the deadline fires first;
    /// `.failed` when `work` throws; `.value` with the result otherwise.
    private enum ProbeRun<Value> {
        case value(Value)
        case timedOut
        case failed
    }

    private final class TimeoutGate<Value>: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<ProbeRun<Value>, Never>?
        private var pendingResult: ProbeRun<Value>?
        private var tasks: [Task<Void, Never>] = []
        private var resolved = false

        func install(_ continuation: CheckedContinuation<ProbeRun<Value>, Never>) {
            lock.lock()
            if let result = pendingResult {
                pendingResult = nil
                lock.unlock()
                continuation.resume(returning: result)
                return
            }
            self.continuation = continuation
            lock.unlock()
        }

        func install(tasks: [Task<Void, Never>]) {
            lock.lock()
            if resolved {
                lock.unlock()
                tasks.forEach { $0.cancel() }
                return
            }
            self.tasks = tasks
            lock.unlock()
        }

        func resolve(_ result: ProbeRun<Value>) {
            lock.lock()
            guard !resolved else { lock.unlock(); return }
            resolved = true
            let continuation = continuation
            self.continuation = nil
            if continuation == nil { pendingResult = result }
            let tasks = tasks
            self.tasks = []
            lock.unlock()
            tasks.forEach { $0.cancel() }
            continuation?.resume(returning: result)
        }
    }

    private static func withTimeout<Value>(
        _ timeout: Duration,
        _ work: @escaping @Sendable () async throws -> Value
    ) async -> ProbeRun<Value> {
        let gate = TimeoutGate<Value>()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                gate.install(continuation)
                let workTask = Task {
                    do { gate.resolve(.value(try await work())) }
                    catch { gate.resolve(.failed) }
                }
                let timeoutTask = Task {
                    do { try await Task.sleep(for: timeout) }
                    catch { return }
                    gate.resolve(.timedOut)
                }
                gate.install(tasks: [workTask, timeoutTask])
            }
        } onCancel: {
            gate.resolve(.failed)
        }
    }

    private static func elapsedMs(from start: ContinuousClock.Instant) -> Int {
        let d = ContinuousClock.now - start
        let seconds = d.components.seconds
        let attoseconds = d.components.attoseconds
        return Int(seconds) * 1000 + Int(attoseconds / 1_000_000_000_000_000)
    }
}
