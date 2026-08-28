import Foundation
import SystemConfiguration
import Network
import AppKit
import Darwin

/// One fixed (directly addressable) proxy endpoint from the system proxy settings.
/// No PAC script is ever executed; PAC/auto-discovery are tracked as flags only.
struct FixedProxy: Equatable, Sendable {
    let host: String
    let port: Int
    /// True when the host is a loopback address or "localhost".
    let isLoopback: Bool

    init(host: String, port: Int) {
        self.host = host
        self.port = port
        self.isLoopback = Self.isLoopbackHost(host)
    }

    static func isLoopbackHost(_ host: String) -> Bool {
        if host == "localhost" { return true }
        if host.hasPrefix("127.") { return true } // 127.0.0.0/8
        if host == "::1" || host == "[::1]" { return true }
        return false
    }
}

/// Finite summary of the current system proxy settings.
/// Distinguishes configured fixed endpoints from PAC / auto-discovery.
struct ProxySnapshot: Equatable, Sendable {
    var httpProxy: FixedProxy?
    var httpsProxy: FixedProxy?
    var socksProxy: FixedProxy?
    var pacConfigured = false
    var autoDiscovery = false

    /// Any path that could route traffic through a proxy (fixed endpoint, PAC, or discovery).
    var hasAnyProxyPath: Bool {
        httpProxy != nil || httpsProxy != nil || socksProxy != nil || pacConfigured || autoDiscovery
    }
}

/// Finite summary of the current network path.
/// `satisfied` means the interface is up — it is NOT evidence of Internet access.
struct PathSnapshot: Equatable, Sendable {
    let satisfied: Bool
    /// "wifi", "wired", "cellular", "loopback", "other" or nil (unknown).
    let interfaceType: String?
    let supportsDNS: Bool
}

/// Reads and observes system network / proxy state. Closure seams, no protocols.
enum SystemNetwork {

    /// Parse the dictionary returned by `SCDynamicStoreCopyProxies`.
    /// Enabled entries with a missing host or port are ignored.
    static func parseProxies(_ dict: [String: Any]) -> ProxySnapshot {
        var snap = ProxySnapshot()

        // SCDynamicStore bridges numeric flags as NSNumber or Bool; accept both.
        func intValue(_ v: Any) -> Int? {
            if let b = v as? Bool { return b ? 1 : 0 }
            if let n = v as? NSNumber { return n.intValue }
            return nil
        }
        func isEnabled(_ key: String) -> Bool {
            guard let v = dict[key], let i = intValue(v) else { return false }
            return i == 1
        }
        // Strict valid port: an integral CFNumber in 1...65535. Booleans (Swift
        // Bool or CFBoolean) and floating-point values are rejected — a port is
        // never a flag; 0 is reserved and rejected.
        func port(_ key: String) -> Int? {
            guard let v = dict[key], let n = v as? NSNumber else { return nil }
            if v is Bool { return nil }
            if CFGetTypeID(n) == CFBooleanGetTypeID() { return nil }
            if CFNumberIsFloatType(n as CFNumber) { return nil }
            let i = n.intValue
            guard (1...65535).contains(i) else { return nil }
            return i
        }

        func fixed(enableKey: String, hostKey: String, portKey: String) -> FixedProxy? {
            guard isEnabled(enableKey),
                  let host = dict[hostKey] as? String, !host.isEmpty,
                  let port = port(portKey) else {
                return nil
            }
            return FixedProxy(host: host, port: port)
        }

        snap.httpProxy = fixed(enableKey: "HTTPEnable", hostKey: "HTTPProxy", portKey: "HTTPPort")
        snap.httpsProxy = fixed(enableKey: "HTTPSEnable", hostKey: "HTTPSProxy", portKey: "HTTPSPort")
        snap.socksProxy = fixed(enableKey: "SOCKSEnable", hostKey: "SOCKSProxy", portKey: "SOCKSPort")
        snap.pacConfigured = isEnabled("ProxyAutoConfigEnable")
        snap.autoDiscovery = isEnabled("ProxyAutoDiscoveryEnable")
        return snap
    }

    /// Read the current proxy snapshot directly.
    static func currentProxies() -> ProxySnapshot {
        guard let store = SCDynamicStoreCreate(nil, "ProxySentry.readProxies" as CFString, nil, nil),
              let dict = SCDynamicStoreCopyProxies(store) as? [String: Any] else {
            return ProxySnapshot()
        }
        return parseProxies(dict)
    }

    /// Reduce an NWPath to the finite PathSnapshot. `satisfied` is only
    /// "interface usable", never "Internet reachable".
    static func pathSnapshot(from path: NWPath) -> PathSnapshot {
        let type: String?
        if path.usesInterfaceType(.wifi) { type = "wifi" }
        else if path.usesInterfaceType(.wiredEthernet) { type = "wired" }
        else if path.usesInterfaceType(.cellular) { type = "cellular" }
        else if path.usesInterfaceType(.loopback) { type = "loopback" }
        else { type = "other" }
        return PathSnapshot(
            satisfied: path.status == .satisfied,
            interfaceType: type,
            supportsDNS: path.supportsDNS
        )
    }

    // MARK: - Default gateway (read-only)

    /// Read the current default gateway address (read-only). Returns a sanitized
    /// bare IP string, or nil when there is no default route or the stored value
    /// is empty / not an IP address. Only the address is exposed — no interface
    /// names or other details. Uses SystemConfiguration (system framework).
    static func defaultGateway() -> String? {
        guard let store = SCDynamicStoreCreate(nil, "ProxySentry.readGateway" as CFString, nil, nil) else {
            return nil
        }
        let ipv4 = SCDynamicStoreCopyValue(store, "State:/Network/Global/IPv4" as CFString) as? [String: Any]
        let ipv6 = SCDynamicStoreCopyValue(store, "State:/Network/Global/IPv6" as CFString) as? [String: Any]
        let router = (ipv4?["Router"] as? String) ?? (ipv6?["Router"] as? String)
        guard let router, isIPAddress(router) else { return nil }
        return router
    }

    /// Strict validation that `s` is a bare IPv4 or IPv6 address. Rejects empty
    /// strings, hostnames, partial/out-of-range octets, CIDR, and any shell
    /// metacharacters. Uses `inet_pton` (strict dotted-quad / full IPv6), unlike
    /// `IPv4Address`, which leniently accepts partial forms like "192.168.1".
    static func isIPAddress(_ s: String) -> Bool {
        var v4 = in_addr()
        if inet_pton(AF_INET, s, &v4) == 1 { return true }
        var v6 = in6_addr()
        return inet_pton(AF_INET6, s, &v6) == 1
    }
}

/// One-shot `NWPathMonitor` wrapper. It reports interface state only; Internet
/// reachability is still decided by the explicit probes.
final class PathObserver: @unchecked Sendable {
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "com.justinjia.ProxySentry.pathobserver")
    private let lock = NSLock()
    private let onChange: () -> Void
    private var running = false
    private var snapshot = PathSnapshot(satisfied: false, interfaceType: nil, supportsDNS: false)

    init(onChange: @escaping () -> Void) {
        self.onChange = onChange
    }

    var current: PathSnapshot {
        lock.lock(); defer { lock.unlock() }
        return snapshot
    }

    func start() {
        lock.lock()
        guard !running else { lock.unlock(); return }
        running = true
        lock.unlock()
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            self.lock.lock()
            guard self.running else { self.lock.unlock(); return }
            self.snapshot = SystemNetwork.pathSnapshot(from: path)
            self.lock.unlock()
            self.onChange()
        }
        monitor.start(queue: queue)
    }

    func stop() {
        lock.lock()
        guard running else { lock.unlock(); return }
        running = false
        lock.unlock()
        monitor.cancel()
    }

    deinit { monitor.cancel() }
}

/// Heap-allocated context retained by the SCDynamicStore session (via the
/// retain/release callbacks). Holds only a weak reference to the observer, so a
/// callback queued before/around teardown can never dereference a deallocated
/// observer — no use-after-free regardless of stop()/deinit ordering.
final class ProxyObserverContext {
    weak var observer: ProxyObserver?
    init(observer: ProxyObserver) {
        self.observer = observer
    }
}

/// Observes system proxy changes (SCDynamicStore) and wake / session-active
/// (NSWorkspace) and forwards each event as exactly one recheck callback.
/// Never reads or writes any system setting beyond proxy notifications.
final class ProxyObserver {

    private let onRecheck: () -> Void
    private let queue = DispatchQueue(label: "com.justinjia.ProxySentry.proxyobserver")
    private var store: SCDynamicStore?
    private var workspaceObservers: [NSObjectProtocol] = []

    /// Live state; also the seam tests use to drive emission semantics.
    /// Guarded by `stateLock`, not `queue`, because `emitChange` can run on
    /// `queue` (via the SCDynamicStore callback) — a `queue.sync` there would
    /// self-deadlock.
    private let stateLock = NSLock()
    private var _isRunning = false
    private(set) var isRunning: Bool {
        get { stateLock.lock(); defer { stateLock.unlock() }; return _isRunning }
        set { stateLock.lock(); defer { stateLock.unlock() }; _isRunning = newValue }
    }

    init(onRecheck: @escaping () -> Void) {
        self.onRecheck = onRecheck
    }

    /// Start observing. Idempotent: a second start is a no-op.
    func start() {
        var alreadyRunning = false
        queue.sync {
            if isRunning { alreadyRunning = true; return }
            isRunning = true

            // Proxy change notifications. The SCDynamicStore callback runs on
            // `queue`; its context is a heap-allocated ProxyObserverContext box
            // that the store retains (via the retain/release callbacks) and that
            // holds only a weak reference to the observer. Even if the observer
            // deallocates before the store is torn down, a queued callback reads a
            // nil observer and no-ops — no use-after-free. The callback forwards to
            // `emitChange()`, which hops to the main queue, so `onRecheck` never
            // runs on `queue` (a reentrant `queue.sync` from `onRecheck` cannot
            // self-deadlock) and re-checks `isRunning` there.
            let callback: SCDynamicStoreCallBack = { _, _, info in
                guard let info else { return }
                let box = Unmanaged<ProxyObserverContext>
                    .fromOpaque(UnsafeMutableRawPointer(mutating: info))
                    .takeUnretainedValue()
                guard let observer = box.observer else { return }
                observer.emitChange()
            }

            let box = ProxyObserverContext(observer: self)
            var context = SCDynamicStoreContext(
                version: 0,
                info: Unmanaged.passRetained(box).toOpaque(),
                retain: { info in
                    UnsafeRawPointer(
                        Unmanaged<ProxyObserverContext>
                            .fromOpaque(UnsafeMutableRawPointer(mutating: info))
                            .retain()
                            .toOpaque()
                    )
                },
                release: { info in
                    Unmanaged<ProxyObserverContext>
                        .fromOpaque(UnsafeMutableRawPointer(mutating: info))
                        .release()
                },
                copyDescription: nil
            )
            if let store = SCDynamicStoreCreate(
                nil,
                "ProxySentry.proxyObserver" as CFString,
                callback,
                &context
            ) {
                let key = SCDynamicStoreKeyCreateProxies(nil) as CFString
                SCDynamicStoreSetNotificationKeys(store, [key] as CFArray, nil)
                SCDynamicStoreSetDispatchQueue(store, queue)
                // Strongly retained until stop(). The session copied the context
                // and retained the box; balance the passRetained we created.
                Unmanaged<ProxyObserverContext>.fromOpaque(context.info!).release()
                self.store = store
            } else {
                // Creation failed: the session never retained the box; balance it.
                Unmanaged<ProxyObserverContext>.fromOpaque(context.info!).release()
            }
        }
        guard !alreadyRunning else { return }

        // Wake / session resume only trigger a recheck; nothing is modified.
        let center = NSWorkspace.shared.notificationCenter
        let wake = center.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.emitChange() }
        let session = center.addObserver(
            forName: NSWorkspace.sessionDidBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.emitChange() }
        queue.sync { workspaceObservers = [wake, session] }
    }

    /// One proxy change → exactly one recheck callback. Safe to call from any
    /// thread: the callback runs on the main queue and re-checks `isRunning`, so
    /// it never fires after `stop()` returns and never executes on the observer's
    /// serial `queue` (no reentrant `queue.sync` deadlock when `onRecheck` drives
    /// controller work that calls `stop()`).
    func emitChange() {
        DispatchQueue.main.async { [weak self] in
            self?.emitOnMain()
        }
    }

    private func emitOnMain() {
        guard isRunning else { return }
        onRecheck()
    }

    /// Stop observing and detach the dynamic-store queue. Idempotent.
    func stop() {
        let observers = queue.sync {
            guard isRunning else { return [NSObjectProtocol]() }
            isRunning = false
            if let store = store {
                SCDynamicStoreSetDispatchQueue(store, nil)
            }
            let result = workspaceObservers
            workspaceObservers = []
            store = nil
            return result
        }
        let center = NSWorkspace.shared.notificationCenter
        observers.forEach { center.removeObserver($0) }
    }

    deinit {
        // Normal teardown goes through stop(); this is best-effort detachment.
        // The retained context box itself is safe if a callback already queued:
        // its weak observer is nil once this object finishes deallocation.
        if let store = store {
            SCDynamicStoreSetDispatchQueue(store, nil)
        }
        // Remove wake/session registrations; otherwise they leak when stop() is
        // not called before deallocation.
        let center = NSWorkspace.shared.notificationCenter
        for observer in workspaceObservers {
            center.removeObserver(observer)
        }
    }
}
