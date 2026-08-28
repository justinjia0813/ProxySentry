import Foundation
import Network

/// Minimal pure parser for a raw Clash HTTP response (first step only).
/// No socket handling, no YAML, no JSON — bytes in, structured body out.
enum ClashReader {

    static let maxBodyBytes = 1_048_576 // 1 MB

    enum ReadError: Error, Equatable {
        /// Headers were not terminated within the received bytes.
        case incomplete
        /// Chunked body failed to parse.
        case malformedChunk
        /// Body (declared or accumulated) exceeds 1 MB.
        case exceededBodyLimit
        /// Status line could not be read.
        case malformedStatusLine
        /// A known YAML field held a malformed value.
        case malformedValue(field: String)
        /// A known YAML key appeared twice at top level.
        case duplicateKey(field: String)
        /// Content-Length was present but negative or not a plain non-negative integer.
        case malformedContentLength
        /// JSON body could not be decoded, or a whitelisted field had the wrong type.
        case malformedJSON(field: String)
        /// HTTP status was outside 2xx.
        case non2xxStatus(Int)
        /// Transport-level failure (no payload details are carried).
        case transport
        /// Connect or read deadline expired.
        case timeout
    }

    struct Response: Equatable {
        let statusCode: Int
        /// Header names lowercased.
        let headers: [String: String]
        let body: Data
    }

    /// Whitelisted Clash status/config fields shared by YAML and JSON paths.
    /// Only these fields are ever extracted; everything else is ignored.
    struct ClashInfo: Equatable {
        var mode: String?
        var mixedPort: Int?
        var externalController: String?
        var allowLan: Bool?
        var tunEnabled: Bool? = nil
    }

    /// Whitelisted fields from Clash /version.
    struct ClashVersion: Equatable {
        var version: String
        var meta: Bool?
    }

    /// Whitelisted fields from Clash /proxies: one group's selection state.
    /// Only the group name, the currently selected name and a numeric delay
    /// are ever extracted — never the full `all` arrays or histories.
    struct ClashProxySelection: Equatable {
        var group: String
        var selected: String
        var delay: Int?
    }

    /// Whitelisted summary of Clash /connections. Only aggregate counts and byte
    /// totals are carried — host, IP, process, rule and chain names never leave
    /// the parsing layer.
    struct ConnectionsSummary: Equatable {
        var activeConnectionCount: Int
        var proxiedConnectionCount: Int
        var uploadTotal: Int64
        var downloadTotal: Int64
        var proxyTrafficObserved: Bool
    }

    /// Aggregate of a same-provider peer-node health sample. Only counts are
    /// carried — never node names. `unavailable` when the provider or a distinct
    /// same-provider candidate cannot be reliably identified.
    struct ProxyHealthSample: Equatable {
        var tested: Int
        var succeeded: Int
        var failed: Int
        var unavailable: Bool
    }

    /// Parse a complete raw HTTP response.
    static func parseResponse(_ data: Data) -> Result<Response, ReadError> {
        // Find header terminator \r\n\r\n
        guard let headerEnd = findHeaderEnd(in: data) else {
            return .failure(.incomplete)
        }

        let headerData = data.subdata(in: 0..<headerEnd)
        // Bounds the header block so the response cap cannot be bypassed by
        // sending an oversized header section with a tiny declared body.
        if headerData.count > maxBodyBytes { return .failure(.exceededBodyLimit) }
        guard let headerText = String(data: headerData, encoding: .utf8) else {
            return .failure(.incomplete)
        }
        let bodyStart = headerEnd + 4

        let lines = headerText.components(separatedBy: "\r\n")
        guard let statusLine = lines.first else {
            return .failure(.malformedStatusLine)
        }
        let statusParts = statusLine.split(separator: " ", maxSplits: 2)
        guard statusParts.count >= 2, let code = Int(statusParts[1]) else {
            return .failure(.malformedStatusLine)
        }

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[name] = value
        }

        // Content-Length: if present it must be a plain non-negative integer.
        var declaredLength: Int?
        if let lenStr = headers["content-length"] {
            guard let len = Int(lenStr), len >= 0 else {
                return .failure(.malformedContentLength)
            }
            if len > maxBodyBytes { return .failure(.exceededBodyLimit) }
            declaredLength = len
        }

        let bodyData = bodyStart <= data.count ? data.subdata(in: bodyStart..<data.count) : Data()

        if isChunked(headers) {
            return decodeChunked(bodyData).map { body in
                Response(statusCode: code, headers: headers, body: body)
            }
        }

        if let len = declaredLength {
            guard bodyData.count >= len else { return .failure(.incomplete) }
            let body = bodyData.prefix(len)
            if body.count > maxBodyBytes { return .failure(.exceededBodyLimit) }
            return .success(Response(statusCode: code, headers: headers, body: Data(body)))
        }

        // Connection-close (or no length info): body is everything after headers.
        if bodyData.count > maxBodyBytes { return .failure(.exceededBodyLimit) }
        return .success(Response(statusCode: code, headers: headers, body: bodyData))
    }

    // MARK: - YAML scalar extraction

    private static let knownYAMLFields: Set<String> = [
        "mode", "mixed-port", "external-controller", "allow-lan"
    ]

    /// Extract ONLY top-level scalar values for the known fields listed above.
    /// Nested keys (indented), comments, list items and unknown fields are ignored.
    /// A known key that is duplicated, or holds a complex/absent value, is an error.
    static func extractYAMLScalars(_ text: String) -> Result<ClashInfo, ReadError> {
        var info = ClashInfo(mode: nil, mixedPort: nil, externalController: nil, allowLan: nil)
        var seenKnownKeys: Set<String> = []

        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)

            // Skip blank lines and comment-only lines.
            if line.isEmpty || line.hasPrefix("#") { continue }
            // Skip list items and nested keys (any leading whitespace was stripped
            // only for the checks above; nested means the original had indentation).
            if rawLine.first == " " || rawLine.first == "\t" { continue }
            if line.hasPrefix("-") { continue }

            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
            guard knownYAMLFields.contains(key) else { continue }

            // A known key appearing twice at top level is ambiguous — refuse.
            guard seenKnownKeys.insert(key).inserted else {
                return .failure(.duplicateKey(field: key))
            }

            var value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)

            // Strip inline comment (" # " separator, as YAML requires whitespace before #).
            if let hash = value.range(of: " #") {
                value = String(value[..<hash.lowerBound]).trimmingCharacters(in: .whitespaces)
            }

            // A known key must hold a plain scalar. Empty, anchored, aliased,
            // tagged, block-scalar or flow-collection values are not acceptable.
            if value.isEmpty
                || value.hasPrefix("&") || value.hasPrefix("*") || value.hasPrefix("!")
                || value.hasPrefix("|") || value.hasPrefix(">")
                || value.hasPrefix("[") || value.hasPrefix("{") {
                return .failure(.malformedValue(field: key))
            }

            // Strip surrounding quotes.
            if value.count >= 2,
               let first = value.first, let last = value.last,
               (first == "\"" && last == "\"") || (first == "'" && last == "'") {
                value = String(value.dropFirst().dropLast())
            }

            switch key {
            case "mode":
                guard ["rule", "global", "direct"].contains(value) else {
                    return .failure(.malformedValue(field: key))
                }
                info.mode = value
            case "mixed-port":
                guard let port = Int(value), (0...65535).contains(port) else {
                    return .failure(.malformedValue(field: key))
                }
                info.mixedPort = port
            case "external-controller":
                info.externalController = value
            case "allow-lan":
                switch value.lowercased() {
                case "true": info.allowLan = true
                case "false": info.allowLan = false
                default: return .failure(.malformedValue(field: key))
                }
            default:
                continue
            }
        }
        return .success(info)
    }

    // MARK: - JSON decoding (whitelisted)

    /// Decode a Clash /version body. Only `version` (string) and `meta` (bool)
    /// are extracted; unknown keys are ignored. Wrong types are rejected.
    static func decodeVersion(_ data: Data) -> Result<ClashVersion, ReadError> {
        guard data.count <= maxBodyBytes else { return .failure(.exceededBodyLimit) }
        guard let obj = jsonObject(data), let dict = obj as? [String: Any] else {
            return .failure(.malformedJSON(field: "<root>"))
        }
        guard let version = dict["version"] as? String, !version.isEmpty else {
            return .failure(.malformedJSON(field: "version"))
        }
        var meta: Bool?
        if let rawMeta = dict["meta"] {
            guard isJSONBoolean(rawMeta), let m = rawMeta as? Bool else {
                return .failure(.malformedJSON(field: "meta"))
            }
            meta = m
        }
        return .success(ClashVersion(version: version, meta: meta))
    }

    /// Decode a Clash /configs body. Only mode, mixed-port, external-controller
    /// and allow-lan are extracted; unknown keys are ignored, wrong types rejected.
    static func decodeConfigs(_ data: Data) -> Result<ClashInfo, ReadError> {
        guard data.count <= maxBodyBytes else { return .failure(.exceededBodyLimit) }
        guard let obj = jsonObject(data), let dict = obj as? [String: Any] else {
            return .failure(.malformedJSON(field: "<root>"))
        }
        var info = ClashInfo(mode: nil, mixedPort: nil, externalController: nil, allowLan: nil)

        if let rawMode = dict["mode"] {
            guard let mode = rawMode as? String, ["rule", "global", "direct"].contains(mode) else {
                return .failure(.malformedJSON(field: "mode"))
            }
            info.mode = mode
        }
        if let rawPort = dict["mixed-port"] {
            guard let port = rawPort as? Int, !isJSONBoolean(rawPort),
                  (0...65535).contains(port) else {
                return .failure(.malformedJSON(field: "mixed-port"))
            }
            info.mixedPort = port
        }
        if let rawController = dict["external-controller"] {
            guard let controller = rawController as? String else {
                return .failure(.malformedJSON(field: "external-controller"))
            }
            info.externalController = controller
        }
        if let rawAllowLan = dict["allow-lan"] {
            guard isJSONBoolean(rawAllowLan), let allowLan = rawAllowLan as? Bool else {
                return .failure(.malformedJSON(field: "allow-lan"))
            }
            info.allowLan = allowLan
        }
        if let rawTun = dict["tun"] {
            guard let tun = rawTun as? [String: Any] else {
                return .failure(.malformedJSON(field: "tun"))
            }
            if let rawEnable = tun["enable"] {
                guard isJSONBoolean(rawEnable), let enabled = rawEnable as? Bool else {
                    return .failure(.malformedJSON(field: "tun.enable"))
                }
                info.tunEnabled = enabled
            }
        }
        return .success(info)
    }

    /// JSONSerialization with .allowFragments off: root must be object/array.
    private static func jsonObject(_ data: Data) -> Any? {
        guard let obj = try? JSONSerialization.jsonObject(with: data, options: []) else { return nil }
        return obj
    }

    /// True only for a genuine JSON boolean (not 0/1 NSNumber bridging).
    private static func isJSONBoolean(_ value: Any) -> Bool {
        CFGetTypeID(value as CFTypeRef) == CFBooleanGetTypeID()
    }

    /// Decode a Clash /proxies body. Prefer the GLOBAL group; otherwise the
    /// first entry that is a selector with a `now` value. Returns nil when no
    /// suitable group exists. Only name / now / latest numeric delay extracted.
    static func decodeProxies(_ data: Data) -> Result<ClashProxySelection?, ReadError> {
        guard data.count <= maxBodyBytes else { return .failure(.exceededBodyLimit) }
        guard let obj = jsonObject(data), let dict = obj as? [String: Any] else {
            return .failure(.malformedJSON(field: "<root>"))
        }
        guard let proxiesRaw = dict["proxies"] else { return .success(nil) }
        guard let proxies = proxiesRaw as? [String: Any] else {
            return .failure(.malformedJSON(field: "proxies"))
        }

        func selection(named name: String, from entry: [String: Any]) -> Result<ClashProxySelection, ReadError> {
            guard let now = entry["now"] as? String, !now.isEmpty else {
                return .failure(.malformedJSON(field: "now"))
            }
            var selected = now
            var visited: Set<String> = []
            while let selectedEntry = proxies[selected] as? [String: Any],
                  let nested = selectedEntry["now"] as? String,
                  !nested.isEmpty {
                guard visited.insert(selected).inserted else {
                    return .failure(.malformedJSON(field: "now"))
                }
                selected = nested
            }
            var delay: Int?
            if let history = entry["history"] as? [[String: Any]] {
                if let last = history.last, let rawDelay = last["delay"] {
                    // Accept only a genuine JSON number; booleans/others → absent.
                    if let d = rawDelay as? Int, !isJSONBoolean(rawDelay) {
                        delay = d
                    }
                }
            }
            return .success(ClashProxySelection(group: name, selected: selected, delay: delay))
        }

        if let global = proxies["GLOBAL"] as? [String: Any], let nowRaw = global["now"] {
            guard let nowStr = nowRaw as? String, !nowStr.isEmpty else {
                return .failure(.malformedJSON(field: "now"))
            }
            return selection(named: "GLOBAL", from: global).map { $0 as ClashProxySelection? }
        }
        // Iterate keys in sorted order so the "first selector with now" fallback
        // is deterministic; Swift Dictionary order is randomized per process.
        for name in proxies.keys.sorted() {
            guard let entry = proxies[name] as? [String: Any] else { continue }
            guard let type = entry["type"] as? String,
                  type.lowercased() == "selector", entry["now"] != nil else { continue }
            return selection(named: name, from: entry).map { $0 as ClashProxySelection? }
        }
        return .success(nil)
    }

    /// Decode the fresh result of Mihomo's read-only proxy delay probe.
    static func decodeProxyDelay(_ data: Data) -> Result<Int, ReadError> {
        guard data.count <= maxBodyBytes else { return .failure(.exceededBodyLimit) }
        guard let obj = jsonObject(data), let dict = obj as? [String: Any],
              let rawDelay = dict["delay"],
              let delay = rawDelay as? Int, !isJSONBoolean(rawDelay),
              (1...65535).contains(delay) else {
            return .failure(.malformedJSON(field: "delay"))
        }
        return .success(delay)
    }

    // MARK: - /connections decoding (whitelisted, no per-connection leak)

    /// Decode a Clash /connections body into a sanitized summary. Only the
    /// connection count, the count of non-DIRECT (proxied) connections, and the
    /// aggregate byte totals are returned. Host, IP, process, rule and chain
    /// names are used only internally to classify proxied vs direct and are never
    /// part of the result.
    static func decodeConnections(_ data: Data) -> Result<ConnectionsSummary, ReadError> {
        guard data.count <= maxBodyBytes else { return .failure(.exceededBodyLimit) }
        guard let obj = jsonObject(data), let dict = obj as? [String: Any] else {
            return .failure(.malformedJSON(field: "<root>"))
        }
        guard let upload = nonNegativeInt64(dict["uploadTotal"]),
              let download = nonNegativeInt64(dict["downloadTotal"]) else {
            return .failure(.malformedJSON(field: "uploadTotal"))
        }
        let connections: [[String: Any]]
        if let raw = dict["connections"] {
            guard let arr = raw as? [[String: Any]] else {
                return .failure(.malformedJSON(field: "connections"))
            }
            connections = arr
        } else {
            connections = []
        }
        var proxied = 0
        for conn in connections {
            if Self.isProxiedConnection(conn) { proxied += 1 }
        }
        return .success(ConnectionsSummary(
            activeConnectionCount: connections.count,
            proxiedConnectionCount: proxied,
            uploadTotal: upload,
            downloadTotal: download,
            proxyTrafficObserved: proxied > 0
        ))
    }

    /// A connection is proxied when its chain routes through at least one
    /// non-DIRECT proxy. A pure DIRECT chain counts as direct. Unknown/missing
    /// chain data is treated conservatively as not proxied.
    private static func isProxiedConnection(_ conn: [String: Any]) -> Bool {
        let chains: [String]?
        if let c = conn["chains"] as? [String] {
            chains = c
        } else if let meta = conn["metadata"] as? [String: Any],
                  let c = meta["chain"] as? [String] {
            chains = c
        } else {
            chains = nil
        }
        guard let chains else { return false }
        return chains.contains { $0.uppercased() != "DIRECT" }
    }

    /// Plain non-negative integer from a JSON value; rejects booleans and floats.
    private static func nonNegativeInt64(_ value: Any?) -> Int64? {
        guard let value, !isJSONBoolean(value),
              let n = value as? NSNumber,
              !CFNumberIsFloatType(n as CFNumber) else { return nil }
        let v = n.int64Value
        return v >= 0 ? v : nil
    }

    // MARK: - Same-provider peer-node health sampling

    /// Proxy `type` values that are policy groups or special/direct nodes — never
    /// ordinary leaf proxies, so they must not be sampled as same-provider peers.
    private static let nonLeafProxyTypes: Set<String> = [
        "selector", "urltest", "fallback", "loadbalance", "relay",
        "direct", "reject", "rejectdrop", "pass", "compatible",
    ]

    /// Internal helper: identify up to `maxCount` leaf candidates from a
    /// /proxies body that share the current leaf's provider, distinct from it.
    /// Returns nil when the current leaf's provider cannot be reliably identified
    /// or no distinct same-provider leaf exists (caller reports `unavailable`).
    /// Only ordinary leaf proxies are considered — policy groups and special
    /// types (Selector/URLTest/Fallback/LoadBalance/Direct/Reject/...) are
    /// excluded even when they carry the same provider-name. Candidate names are
    /// used only internally to drive read-only delay probes; they are never part
    /// of a public result.
    static func sameProviderCandidates(
        fromProxies data: Data,
        currentLeaf: String,
        maxCount: Int = 2
    ) -> Result<[String]?, ReadError> {
        guard data.count <= maxBodyBytes else { return .failure(.exceededBodyLimit) }
        guard let obj = jsonObject(data), let dict = obj as? [String: Any] else {
            return .failure(.malformedJSON(field: "<root>"))
        }
        guard let proxies = dict["proxies"] as? [String: Any] else {
            return .failure(.malformedJSON(field: "proxies"))
        }
        guard let currentEntry = proxies[currentLeaf] as? [String: Any],
              let provider = currentProvider(from: currentEntry), !provider.isEmpty else {
            return .success(nil) // cannot reliably identify the provider
        }
        var candidates: [String] = []
        for name in proxies.keys.sorted() {
            if name == currentLeaf { continue }
            guard let entry = proxies[name] as? [String: Any] else { continue }
            // Only ordinary leaf proxies qualify as peers.
            guard let type = (entry["type"] as? String)?.lowercased(),
                  !nonLeafProxyTypes.contains(type) else { continue }
            guard let entryProvider = currentProvider(from: entry),
                  entryProvider == provider else { continue }
            candidates.append(name)
            if candidates.count >= maxCount { break }
        }
        return .success(candidates.isEmpty ? nil : candidates)
    }

    /// The provider of a proxy entry. Official Mihomo uses `provider-name`;
    /// the legacy `provider` key is accepted as a fallback only.
    private static func currentProvider(from entry: [String: Any]) -> String? {
        if let name = entry["provider-name"] as? String, !name.isEmpty { return name }
        if let legacy = entry["provider"] as? String, !legacy.isEmpty { return legacy }
        return nil
    }

    // MARK: - Unix socket candidates (fixed, no scanning)

    /// Fixed socket file name used by all three candidate paths.
    static let socketFileName = "verge-mihomo.sock"

    /// Pure, testable candidate generation: exactly three fixed paths.
    static func socketCandidatePaths(tempDir: String, homeDir: String) -> [String] {
        let temp = tempDir.hasSuffix("/") ? tempDir : tempDir + "/"
        let home = homeDir.hasSuffix("/") ? String(homeDir.dropLast()) : homeDir
        return [
            temp + socketFileName,
            "/tmp/verge/" + socketFileName,
            home + "/.config/verge/" + socketFileName,
        ]
    }

    /// The live candidate list for this user.
    static func socketCandidatePaths() -> [String] {
        socketCandidatePaths(tempDir: currentUserTempDir, homeDir: homeDirPath)
    }

    /// A configured path is accepted only when its normalized form is one of
    /// the three fixed candidates. No directory scanning or arbitrary path is allowed.
    static func isAllowedSocketPath(
        _ path: String,
        candidates: [String] = socketCandidatePaths()
    ) -> Bool {
        let normalized = (path as NSString).standardizingPath
        return candidates.contains { ($0 as NSString).standardizingPath == normalized }
    }

    /// Current user's Darwin temp dir (confstr), cached once.
    static let currentUserTempDir: String = {
        var buf = [CChar](repeating: 0, count: 1024)
        let n = confstr(_CS_DARWIN_USER_TEMP_DIR, &buf, buf.count)
        return n > 0 ? String(cString: buf) : "/tmp/"
    }()

    private static var homeDirPath: String {
        FileManager.default.homeDirectoryForCurrentUser.path
    }

    /// Validate one candidate with lstat: the entry must be a socket, and its
    /// parent directory must be a directory owned by the current user or root.
    /// Group writes are accepted only for Clash Verge's fixed, root-owned shared
    /// temp directory; other-user writes remain forbidden. `lstatPath` is a
    /// closure seam for tests.
    static func validateSocketCandidate(
        path: String,
        currentUID: uid_t = getuid(),
        lstatPath: (String) -> stat? = ClashReader.defaultLstat
    ) -> Bool {
        guard let st = lstatPath(path), st.st_mode & mode_t(S_IFMT) == mode_t(S_IFSOCK) else {
            return false
        }
        let parent = (path as NSString).deletingLastPathComponent
        guard !parent.isEmpty else { return false }
        guard let ps = lstatPath(parent), ps.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) else {
            return false
        }
        let socketOwnerOK = st.st_uid == currentUID || st.st_uid == 0
        let ownerOK = ps.st_uid == currentUID || ps.st_uid == 0
        let notGroupOtherWritable = ps.st_mode & 0o022 == 0
        let standardSharedTemp = (path as NSString).standardizingPath == "/tmp/verge/verge-mihomo.sock"
            && (parent as NSString).standardizingPath == "/tmp/verge"
            && ps.st_uid == 0
            && ps.st_mode & 0o002 == 0
        return socketOwnerOK && ownerOK && (notGroupOtherWritable || standardSharedTemp)
    }

    private static func defaultLstat(_ path: String) -> stat? {
        var st = stat()
        return lstat(path, &st) == 0 ? st : nil
    }

    // MARK: - Request building (pure)

    /// The only request paths the transport may issue. Restricting the path to
    /// this fixed whitelist prevents callers from injecting CRLF or extra
    /// request lines/headers into the outgoing HTTP request.
    static let allowedHTTPPaths: Set<String> = ["/version", "/configs", "/proxies", "/connections"]
    private static let proxyDelaySuffix = "/delay?url=https%3A%2F%2Fwww.gstatic.com%2Fgenerate_204&timeout=3000&expected=204"

    /// Build the only dynamic API path used by the app. A proxy name comes from
    /// `/proxies`, is bounded, and is encoded as one path segment before use.
    static func proxyDelayPath(proxyName: String) -> String? {
        guard !proxyName.isEmpty, proxyName.utf8.count <= 512,
              !["DIRECT", "REJECT"].contains(proxyName.uppercased()) else { return nil }
        var unreserved = CharacterSet.alphanumerics
        unreserved.insert(charactersIn: "-._~")
        guard let encoded = proxyName.addingPercentEncoding(withAllowedCharacters: unreserved),
              !encoded.isEmpty else { return nil }
        return "/proxies/\(encoded)\(proxyDelaySuffix)"
    }

    static func isAllowedHTTPPath(_ path: String) -> Bool {
        if allowedHTTPPaths.contains(path) { return true }
        let prefix = "/proxies/"
        guard path.hasPrefix(prefix), path.hasSuffix(proxyDelaySuffix),
              !path.contains("\r"), !path.contains("\n"), !path.contains(" ") else { return false }
        let nameEnd = path.index(path.endIndex, offsetBy: -proxyDelaySuffix.count)
        let encodedName = path[path.index(path.startIndex, offsetBy: prefix.count)..<nameEnd]
        return !encodedName.isEmpty && !encodedName.contains("/")
    }

    /// Fixed GET request. `nil` when the path is not in the whitelist, so a
    /// caller cannot smuggle CRLF or a second request. The secret, when present,
    /// exists only as this in-memory header value; it is never included in
    /// results or errors.
    static func buildRequest(path: String, secret: String?) -> Data? {
        guard isAllowedHTTPPath(path) else { return nil }
        var head = "GET \(path) HTTP/1.1\r\nHost: clash\r\nConnection: close\r\n"
        if let secret = secret, !secret.isEmpty {
            head += "Authorization: Bearer \(secret)\r\n"
        }
        head += "\r\n"
        return Data(head.utf8)
    }

    // MARK: - Loopback fallback endpoint (pure)

    /// Parse an external-controller value into a loopback host/port pair.
    /// Only `127.0.0.1` and `localhost` hosts with a plain numeric port in
    /// 1...65535 are accepted; everything else (wildcards, remote hosts,
    /// IPv6 literals, empty hosts, malformed ports) is rejected.
    static func loopbackHostPort(from controller: String) -> (host: String, port: UInt16)? {
        guard let colon = controller.lastIndex(of: ":") else { return nil }
        let host = String(controller[..<colon]).lowercased()
        let portText = String(controller[controller.index(after: colon)...])
        guard ["127.0.0.1", "localhost"].contains(host) else { return nil }
        guard let port = UInt16(portText), (1...65535).contains(port) else { return nil }
        return (host, port)
    }

    // MARK: - Transport (read-only, deadlines, no payload details)

    /// Thread-safe resume-once gate. The awaiting continuation is resumed at
    /// most once, even when task cancellation races with the connection being
    /// started. Resume before install marks the gate done so a later install
    /// immediately delivers a timeout instead of hanging.
    final class ResumeOnce: @unchecked Sendable {
        private let lock = NSLock()
        // All mutable state (`continuation`, `done`) is guarded by `lock`.
        private var continuation: CheckedContinuation<Result<Response, ReadError>, Never>?
        private var done = false

        func install(_ c: CheckedContinuation<Result<Response, ReadError>, Never>) {
            lock.lock(); defer { lock.unlock() }
            continuation = c
            if done {
                continuation = nil
                c.resume(returning: .failure(.timeout))
            }
        }

        func resume(_ result: Result<Response, ReadError>) {
            lock.lock(); defer { lock.unlock() }
            guard !done else { return }
            done = true
            let c = continuation
            continuation = nil
            c?.resume(returning: result)
        }

        var isDone: Bool {
            lock.lock(); defer { lock.unlock() }
            return done
        }
    }

    /// Lock-protected holder for the single active deadline work item. The old
    /// `var deadline` was captured by concurrently-running closures (connection
    /// state handler, receive/send callbacks, cancellation) — a real data race.
    /// All access is serialized by an internal lock; the reference itself is
    /// immutable, so this type is safe to capture in @Sendable closures.
    final class DeadlineSlot: @unchecked Sendable {
        private let lock = NSLock()
        private var item: DispatchWorkItem?

        /// Cancel the current item (if any) and store a replacement.
        func replace(_ newItem: DispatchWorkItem?) {
            lock.lock(); defer { lock.unlock() }
            item?.cancel()
            item = newItem
        }

        /// Cancel the current item, if any.
        func cancel() {
            lock.lock(); defer { lock.unlock() }
            item?.cancel()
        }
    }

    /// Perform a fixed GET over the given endpoint with separate 3-second
    /// connect and read deadlines. Cancellation always closes the connection
    /// and resumes exactly once. Only 2xx responses are returned.
    static func performGET(
        endpoint: NWEndpoint,
        httpPath: String,
        secret: String?,
        timeout: TimeInterval = 3
    ) async -> Result<Response, ReadError> {
        let connection = NWConnection(to: endpoint, using: .tcp)
        let resume = ResumeOnce()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (cont: CheckedContinuation<Result<Response, ReadError>, Never>) in
            resume.install(cont)
            let queue = DispatchQueue(label: "proxysentry.clashreader")
            var buffer = Data()
            let deadline = DeadlineSlot()

            func finish(_ result: Result<Response, ReadError>) {
                deadline.cancel()
                connection.cancel()
                resume.resume(result)
            }

            func finishParsed(_ buffer: Data, complete: Bool) {
                switch parseResponse(buffer) {
                case .success(let resp):
                    guard complete || hasKnownLength(resp.headers) else { return }
                    if (200...299).contains(resp.statusCode) {
                        finish(.success(resp))
                    } else {
                        finish(.failure(.non2xxStatus(resp.statusCode)))
                    }
                case .failure(let error):
                    if complete { finish(.failure(error)) }
                }
            }

            func receiveNext() {
                // Reset the read deadline on every successful progress point.
                let readDeadline = DispatchWorkItem { finish(.failure(.timeout)) }
                deadline.replace(readDeadline)
                queue.asyncAfter(deadline: .now() + timeout, execute: readDeadline)

                connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, isComplete, error in
                    if let data = data, !data.isEmpty {
                        buffer.append(data)
                        if buffer.count > maxBodyBytes + 65536 {
                            finish(.failure(.exceededBodyLimit))
                            return
                        }
                    }
                    if error != nil {
                        // Peer reset mid-stream: try a final parse before failing.
                        finishParsed(buffer, complete: true)
                        guard !resume.isDone else { return }
                        finish(.failure(.transport))
                        return
                    }
                    finishParsed(buffer, complete: isComplete)
                    guard !resume.isDone else { return }
                    if isComplete {
                        finish(.failure(.incomplete))
                        return
                    }
                    receiveNext()
                }
            }

            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    let sendDeadline = DispatchWorkItem { finish(.failure(.timeout)) }
                    deadline.replace(sendDeadline)
                    queue.asyncAfter(deadline: .now() + timeout, execute: sendDeadline)
                    guard let request = buildRequest(path: httpPath, secret: secret) else {
                        finish(.failure(.transport))
                        return
                    }
                    connection.send(content: request, completion: .contentProcessed { error in
                        if error != nil {
                            finish(.failure(.transport))
                            return
                        }
                        receiveNext()
                    })
                case .failed:
                    finish(.failure(.transport))
                case .cancelled:
                    finish(.failure(.timeout))
                default:
                    break
                }
            }

            // 3-second connect deadline.
            let connectDeadline = DispatchWorkItem { finish(.failure(.timeout)) }
            deadline.replace(connectDeadline)
            queue.asyncAfter(deadline: .now() + timeout, execute: connectDeadline)
            connection.start(queue: queue)
            }
        } onCancel: {
            // Always release the awaiting caller and close the connection, even
            // if cancellation lands before the operation body ran. Resume-once
            // guarantees the continuation is released exactly once.
            resume.resume(.failure(.timeout))
            connection.cancel()
        }
    }

    private static func hasKnownLength(_ headers: [String: String]) -> Bool {
        headers["content-length"] != nil || headers["transfer-encoding"] != nil
    }

    /// Fetch /version from a validated Unix socket path.
    static func fetchVersion(socketPath: String, secret: String?) async -> Result<ClashVersion, ReadError> {
        guard isAllowedSocketPath(socketPath), validateSocketCandidate(path: socketPath) else {
            return .failure(.transport)
        }
        return await performGET(endpoint: .unix(path: socketPath), httpPath: "/version", secret: secret)
            .flatMap { decodeVersion($0.body) }
    }

    /// Fetch /configs from a validated Unix socket path.
    static func fetchConfigs(socketPath: String, secret: String?) async -> Result<ClashInfo, ReadError> {
        guard isAllowedSocketPath(socketPath), validateSocketCandidate(path: socketPath) else {
            return .failure(.transport)
        }
        return await performGET(endpoint: .unix(path: socketPath), httpPath: "/configs", secret: secret)
            .flatMap { decodeConfigs($0.body) }
    }

    /// Fetch /proxies from a validated Unix socket path.
    static func fetchProxies(socketPath: String, secret: String?) async -> Result<ClashProxySelection?, ReadError> {
        guard isAllowedSocketPath(socketPath), validateSocketCandidate(path: socketPath) else {
            return .failure(.transport)
        }
        return await performGET(endpoint: .unix(path: socketPath), httpPath: "/proxies", secret: secret)
            .flatMap { decodeProxies($0.body) }
    }

    /// Actively test one selected proxy through Mihomo's read-only delay API.
    static func fetchProxyDelay(
        socketPath: String,
        proxyName: String,
        secret: String?
    ) async -> Result<Int, ReadError> {
        guard isAllowedSocketPath(socketPath), validateSocketCandidate(path: socketPath),
              let path = proxyDelayPath(proxyName: proxyName) else {
            return .failure(.transport)
        }
        return await performGET(endpoint: .unix(path: socketPath), httpPath: path, secret: secret)
            .flatMap { decodeProxyDelay($0.body) }
    }

    /// Fetch /connections from a validated Unix socket path.
    static func fetchConnections(socketPath: String, secret: String?) async -> Result<ConnectionsSummary, ReadError> {
        guard isAllowedSocketPath(socketPath), validateSocketCandidate(path: socketPath) else {
            return .failure(.transport)
        }
        return await performGET(endpoint: .unix(path: socketPath), httpPath: "/connections", secret: secret)
            .flatMap { decodeConnections($0.body) }
    }

    /// Explicitly requested, read-only health sample of up to two same-provider
    /// peer nodes for the current leaf. Identifies peers from /proxies, calls the
    /// delay API on them, and returns only aggregate counts. Never switches
    /// selection and never calls a write endpoint. `unavailable` when the current
    /// leaf's provider or a distinct same-provider candidate cannot be identified.
    static func samplePeerNodeHealth(
        socketPath: String,
        secret: String?
    ) async -> Result<ProxyHealthSample, ReadError> {
        guard isAllowedSocketPath(socketPath), validateSocketCandidate(path: socketPath) else {
            return .failure(.transport)
        }
        let response = await performGET(
            endpoint: .unix(path: socketPath), httpPath: "/proxies", secret: secret)
        guard case .success(let resp) = response else { return .failure(.transport) }
        guard case .success(let selection) = decodeProxies(resp.body), let selection = selection else {
            return .failure(.transport)
        }
        guard case .success(let candidates) = sameProviderCandidates(
            fromProxies: resp.body, currentLeaf: selection.selected),
            let candidates = candidates else {
            return .success(ProxyHealthSample(tested: 0, succeeded: 0, failed: 0, unavailable: true))
        }
        // Fan out the (at most two) delay probes concurrently so the sample never
        // adds a serial 2×3s tail to the round. Each probe keeps its own 3s
        // deadline; the result stays an aggregate success count.
        let succeeded = await runCandidateDelayProbes(candidates) { name in
            let r = await fetchProxyDelay(socketPath: socketPath, proxyName: name, secret: secret)
            if case .success = r { return true }
            return false
        }
        return .success(ProxyHealthSample(
            tested: candidates.count,
            succeeded: succeeded,
            failed: candidates.count - succeeded,
            unavailable: false
        ))
    }

    /// Run delay probes for the given candidate names concurrently. Returns only
    /// the number that succeeded — an aggregate, never the names. Each `probe` is
    /// responsible for its own deadline (`fetchProxyDelay` bounds each to 3s), so
    /// the concurrent fan-out costs roughly one probe's latency, not the sum.
    static func runCandidateDelayProbes(
        _ candidates: [String],
        probe: @escaping @Sendable (String) async -> Bool
    ) async -> Int {
        let results = await withTaskGroup(of: Bool.self) { group -> [Bool] in
            for name in candidates {
                group.addTask { await probe(name) }
            }
            var collected: [Bool] = []
            for await ok in group { collected.append(ok) }
            return collected
        }
        return results.filter { $0 }.count
    }

    /// Loopback-only TCP fallback. Used only when a parsed config exactly
    /// provides a legal loopback external-controller endpoint.
    static func loopbackEndpoint(from controller: String) -> NWEndpoint? {
        guard let (host, port) = loopbackHostPort(from: controller),
              let nwPort = NWEndpoint.Port(rawValue: port) else { return nil }
        return .hostPort(host: NWEndpoint.Host(host), port: nwPort)
    }

    private static func findHeaderEnd(in data: Data) -> Int? {
        let bytes = [UInt8](data)
        guard bytes.count >= 4 else { return nil }
        var i = 0
        while i + 4 <= bytes.count {
            if bytes[i] == 0x0D, bytes[i+1] == 0x0A, bytes[i+2] == 0x0D, bytes[i+3] == 0x0A {
                return i
            }
            i += 1
        }
        return nil
    }

    private static func isChunked(_ headers: [String: String]) -> Bool {
        headers["transfer-encoding"]?.lowercased().contains("chunked") == true
    }

    private static func decodeChunked(_ data: Data) -> Result<Data, ReadError> {
        var body = Data()
        var pos = data.startIndex

        func lineEnding(after index: Data.Index) -> (line: Data, next: Data.Index)? {
            var i = index
            while i < data.endIndex {
                if data[i] == 0x0D {
                    let next = data.index(after: i)
                    if next < data.endIndex, data[next] == 0x0A {
                        return (data.subdata(in: index..<i), data.index(after: next))
                    }
                }
                i = data.index(after: i)
            }
            return nil
        }

        while true {
            guard let (sizeLine, afterSize) = lineEnding(after: pos) else {
                return .failure(.malformedChunk)
            }
            let sizeText = String(data: sizeLine, encoding: .utf8) ?? ""
            let hexPart = sizeText.split(separator: ";").first.map(String.init) ?? sizeText
            guard let size = Int(hexPart.trimmingCharacters(in: .whitespaces), radix: 16),
                  size >= 0 else {
                return .failure(.malformedChunk)
            }
            if size == 0 {
                // Consume trailer until empty line (or end of data).
                return .success(body)
            }
            if body.count + size > maxBodyBytes { return .failure(.exceededBodyLimit) }
            let chunkStart = afterSize
            guard data.distance(from: chunkStart, to: data.endIndex) >= size + 2 else {
                return .failure(.malformedChunk)
            }
            let chunkEnd = data.index(chunkStart, offsetBy: size)
            body.append(data.subdata(in: chunkStart..<chunkEnd))
            // Expect \r\n after chunk
            guard data[chunkEnd] == 0x0D, data[data.index(after: chunkEnd)] == 0x0A else {
                return .failure(.malformedChunk)
            }
            pos = data.index(chunkEnd, offsetBy: 2)
        }
    }
}
