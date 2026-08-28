import XCTest
@testable import ProxySentry

/// File-private thread-safe counter used to assert concurrent probe fan-out.
private final class ProbeCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var _value = 0
    var value: Int { lock.lock(); defer { lock.unlock() }; return _value }
    func increment() { lock.lock(); _value += 1; lock.unlock() }
    func decrement() { lock.lock(); _value -= 1; lock.unlock() }
    func updateMax(_ x: Int) { lock.lock(); _value = max(_value, x); lock.unlock() }
}

final class ClashReaderTests: XCTestCase {

    // MARK: - Content-Length

    func testContentLengthBody() {
        let raw = Data("HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nhello".utf8)
        let result = ClashReader.parseResponse(raw)
        guard case .success(let resp) = result else {
            return XCTFail("Expected success, got \(result)")
        }
        XCTAssertEqual(resp.statusCode, 200)
        XCTAssertEqual(resp.body, Data("hello".utf8))
        XCTAssertEqual(resp.headers["content-length"], "5")
    }

    func testContentLengthBodyShorterThanDeclaredReturnsIncomplete() {
        let raw = Data("HTTP/1.1 200 OK\r\nContent-Length: 10\r\n\r\nhel".utf8)
        let result = ClashReader.parseResponse(raw)
        guard case .failure(let err) = result else {
            return XCTFail("Expected failure, got \(result)")
        }
        XCTAssertEqual(err, .incomplete)
    }

    // MARK: - chunked

    func testChunkedBody() {
        let raw = Data("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhello\r\n3\r\n fo\r\n0\r\n\r\n".utf8)
        let result = ClashReader.parseResponse(raw)
        guard case .success(let resp) = result else {
            return XCTFail("Expected success, got \(result)")
        }
        XCTAssertEqual(resp.body, Data("hello fo".utf8))
    }

    func testChunkedBodyWithTrailingHeaders() {
        let raw = Data("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n2\r\nab\r\n0\r\nX-Trailer: 1\r\n\r\n".utf8)
        let result = ClashReader.parseResponse(raw)
        guard case .success(let resp) = result else {
            return XCTFail("Expected success, got \(result)")
        }
        XCTAssertEqual(resp.body, Data("ab".utf8))
    }

    // MARK: - connection-close

    func testConnectionCloseBodyIsRemainder() {
        let raw = Data("HTTP/1.1 200 OK\r\nConnection: close\r\n\r\nwhatever bytes until close".utf8)
        let result = ClashReader.parseResponse(raw)
        guard case .success(let resp) = result else {
            return XCTFail("Expected success, got \(result)")
        }
        XCTAssertEqual(resp.body, Data("whatever bytes until close".utf8))
    }

    func testNoLengthNoChunkedDefaultsToConnectionClose() {
        let raw = Data("HTTP/1.1 200 OK\r\n\r\nrest of stream".utf8)
        let result = ClashReader.parseResponse(raw)
        guard case .success(let resp) = result else {
            return XCTFail("Expected success, got \(result)")
        }
        XCTAssertEqual(resp.body, Data("rest of stream".utf8))
    }

    // MARK: - malformed chunked

    func testMalformedChunkSizeIsRejected() {
        let raw = Data("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\nzz\r\nhello\r\n".utf8)
        let result = ClashReader.parseResponse(raw)
        guard case .failure(let err) = result else {
            return XCTFail("Expected failure, got \(result)")
        }
        XCTAssertEqual(err, .malformedChunk)
    }

    func testTruncatedChunkIsRejected() {
        let raw = Data("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhel".utf8)
        let result = ClashReader.parseResponse(raw)
        guard case .failure(let err) = result else {
            return XCTFail("Expected failure, got \(result)")
        }
        XCTAssertEqual(err, .malformedChunk)
    }

    func testMissingFinalChunkIsRejected() {
        let raw = Data("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n2\r\nab\r\n".utf8)
        let result = ClashReader.parseResponse(raw)
        guard case .failure(let err) = result else {
            return XCTFail("Expected failure, got \(result)")
        }
        XCTAssertEqual(err, .malformedChunk)
    }

    // MARK: - 1 MB limit

    func testBodyOverOneMegabyteIsRejected() {
        let big = Data(repeating: 0x61, count: 1_048_577)
        var raw = Data("HTTP/1.1 200 OK\r\nContent-Length: \(big.count)\r\n\r\n".utf8)
        raw.append(big)
        let result = ClashReader.parseResponse(raw)
        guard case .failure(let err) = result else {
            return XCTFail("Expected failure, got \(result)")
        }
        XCTAssertEqual(err, .exceededBodyLimit)
    }

    func testChunkedBodyOverOneMegabyteIsRejected() {
        let chunkSize = 0x10000 // 65536
        var raw = Data("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n".utf8)
        for _ in 0..<(1_048_576 / chunkSize + 1) {
            raw.append(Data("\(String(chunkSize, radix: 16))\r\n".utf8))
            raw.append(Data(repeating: 0x61, count: chunkSize))
            raw.append(Data("\r\n".utf8))
        }
        raw.append(Data("0\r\n\r\n".utf8))
        let result = ClashReader.parseResponse(raw)
        guard case .failure(let err) = result else {
            return XCTFail("Expected failure, got \(result)")
        }
        XCTAssertEqual(err, .exceededBodyLimit)
    }

    func testBodyExactlyAtLimitIsAccepted() {
        let body = Data(repeating: 0x61, count: 1_048_576)
        var raw = Data("HTTP/1.1 200 OK\r\nContent-Length: \(body.count)\r\n\r\n".utf8)
        raw.append(body)
        let result = ClashReader.parseResponse(raw)
        guard case .success(let resp) = result else {
            return XCTFail("Expected success, got \(result)")
        }
        XCTAssertEqual(resp.body.count, 1_048_576)
    }

    // MARK: - malformed request line

    func testMissingHeaderTerminatorIsRejected() {
        let raw = Data("HTTP/1.1 200 OK\r\nContent-Length: 5".utf8)
        let result = ClashReader.parseResponse(raw)
        guard case .failure(let err) = result else {
            return XCTFail("Expected failure, got \(result)")
        }
        XCTAssertEqual(err, .incomplete)
    }

    // Header block cap: an oversized header section cannot bypass the cap even
    // when the declared body is tiny.
    func testOversizedHeaderBlockIsRejected() {
        let filler = String(repeating: "a", count: ClashReader.maxBodyBytes)
        let raw = Data("HTTP/1.1 200 OK\r\nX-Filler: \(filler)\r\n\r\nhi".utf8)
        guard case .failure(.exceededBodyLimit) = ClashReader.parseResponse(raw) else {
            return XCTFail("Expected exceededBodyLimit")
        }
    }
}

// MARK: - YAML scalar extraction

extension ClashReaderTests {

    func testYAMLValidKnownFields() {
        let yaml = """
        # Clash config
        mode: rule
        mixed-port: 7890
        external-controller: 127.0.0.1:9090
        allow-lan: true
        """
        let result = ClashReader.extractYAMLScalars(yaml)
        guard case .success(let info) = result else {
            return XCTFail("Expected success, got \(result)")
        }
        XCTAssertEqual(info.mode, "rule")
        XCTAssertEqual(info.mixedPort, 7890)
        XCTAssertEqual(info.externalController, "127.0.0.1:9090")
        XCTAssertEqual(info.allowLan, true)
    }

    func testYAMLIgnoresNestedCommentsListsUnknownAndAnchors() {
        let yaml = """
        proxies: # unknown field
          - name: nested-item
            type: ss
        secret: hunter2
        rules:
          - MATCH,DIRECT
        anchor: &a value
        alias: *a
        tagged: !!str something
        block: |
          multi
          line
        mode: global
        log-level: info
        """
        let result = ClashReader.extractYAMLScalars(yaml)
        guard case .success(let info) = result else {
            return XCTFail("Expected success, got \(result)")
        }
        XCTAssertEqual(info.mode, "global")
        XCTAssertNil(info.mixedPort)
        XCTAssertNil(info.externalController)
        XCTAssertNil(info.allowLan)
    }

    func testYAMLNestedKnownKeyUnderOtherObjectIsIgnored() {
        let yaml = """
        tun:
          mode: rule
        mode: direct
        """
        let result = ClashReader.extractYAMLScalars(yaml)
        guard case .success(let info) = result else {
            return XCTFail("Expected success, got \(result)")
        }
        XCTAssertEqual(info.mode, "direct")
    }

    func testYAMLInlineCommentAndQuotes() {
        let yaml = """
        mode: "rule" # quoted with comment
        external-controller: '0.0.0.0:9090'
        allow-lan: false
        """
        let result = ClashReader.extractYAMLScalars(yaml)
        guard case .success(let info) = result else {
            return XCTFail("Expected success, got \(result)")
        }
        XCTAssertEqual(info.mode, "rule")
        XCTAssertEqual(info.externalController, "0.0.0.0:9090")
        XCTAssertEqual(info.allowLan, false)
    }

    func testYAMLMalformedPortRejected() {
        let yaml = "mixed-port: not-a-number\n"
        let result = ClashReader.extractYAMLScalars(yaml)
        guard case .failure(.malformedValue(let field)) = result else {
            return XCTFail("Expected malformedValue, got \(result)")
        }
        XCTAssertEqual(field, "mixed-port")
    }

    func testYAMLOutOfRangePortRejected() {
        let result = ClashReader.extractYAMLScalars("mixed-port: 70000\n")
        guard case .failure(.malformedValue(let field)) = result else {
            return XCTFail("Expected malformedValue, got \(result)")
        }
        XCTAssertEqual(field, "mixed-port")
    }

    func testYAMLMalformedBooleanRejected() {
        let result = ClashReader.extractYAMLScalars("allow-lan: yes-please\n")
        guard case .failure(.malformedValue(let field)) = result else {
            return XCTFail("Expected malformedValue, got \(result)")
        }
        XCTAssertEqual(field, "allow-lan")
    }

    func testYAMLMalformedModeRejected() {
        let result = ClashReader.extractYAMLScalars("mode: super\n")
        guard case .failure(.malformedValue(let field)) = result else {
            return XCTFail("Expected malformedValue, got \(result)")
        }
        XCTAssertEqual(field, "mode")
    }
}

// MARK: - JSON decoding (/version, /configs)

extension ClashReaderTests {

    func testJSONVersionValid() {
        let data = Data(#"{"version":"1.18.0","meta":true,"extra":"ignored"}"#.utf8)
        let result = ClashReader.decodeVersion(data)
        guard case .success(let version) = result else {
            return XCTFail("Expected success, got \(result)")
        }
        XCTAssertEqual(version.version, "1.18.0")
        XCTAssertEqual(version.meta, true)
    }

    func testJSONVersionMissingMetaStillOk() {
        let data = Data(#"{"version":"1.18.0"}"#.utf8)
        guard case .success(let version) = ClashReader.decodeVersion(data) else {
            return XCTFail("Expected success")
        }
        XCTAssertNil(version.meta)
    }

    func testJSONVersionMissingVersionRejected() {
        let data = Data(#"{"meta":true}"#.utf8)
        guard case .failure(.malformedJSON(let field)) = ClashReader.decodeVersion(data) else {
            return XCTFail("Expected malformedJSON")
        }
        XCTAssertEqual(field, "version")
    }

    func testJSONVersionWrongTypeRejected() {
        let data = Data(#"{"version":123}"#.utf8)
        guard case .failure(.malformedJSON(let field)) = ClashReader.decodeVersion(data) else {
            return XCTFail("Expected malformedJSON")
        }
        XCTAssertEqual(field, "version")
    }

    func testJSONVersionMalformedJSONRejected() {
        let data = Data(#"{"version":"1.18""#.utf8)
        guard case .failure = ClashReader.decodeVersion(data) else {
            return XCTFail("Expected failure")
        }
    }

    func testJSONConfigsValidWithUnknownFieldsIgnored() {
        let json = """
        {"port":7891,"socks-port":7892,"mode":"rule","mixed-port":7890,
         "allow-lan":true,"external-controller":"127.0.0.1:9090","tun":{"enable":true},
         "log-level":"info","secret":"should-not-be-extracted"}
        """
        let result = ClashReader.decodeConfigs(Data(json.utf8))
        guard case .success(let info) = result else {
            return XCTFail("Expected success, got \(result)")
        }
        XCTAssertEqual(info.mode, "rule")
        XCTAssertEqual(info.mixedPort, 7890)
        XCTAssertEqual(info.allowLan, true)
        XCTAssertEqual(info.externalController, "127.0.0.1:9090")
        XCTAssertEqual(info.tunEnabled, true)
    }

    func testJSONConfigsTunEnableWrongTypeRejected() {
        let data = Data(#"{"tun":{"enable":1}}"#.utf8)
        guard case .failure(.malformedJSON(let field)) = ClashReader.decodeConfigs(data) else {
            return XCTFail("Expected malformedJSON")
        }
        XCTAssertEqual(field, "tun.enable")
    }

    func testJSONConfigsAdversarialNestedModeIsWrongTypeRejected() {
        // mode as an object (attacker-controlled nesting) must be rejected.
        let data = Data(#"{"mode":{"rule":true}}"#.utf8)
        guard case .failure(.malformedJSON(let field)) = ClashReader.decodeConfigs(data) else {
            return XCTFail("Expected malformedJSON")
        }
        XCTAssertEqual(field, "mode")
    }

    func testJSONConfigsMixedPortAsStringRejected() {
        let data = Data(#"{"mixed-port":"7890"}"#.utf8)
        guard case .failure(.malformedJSON(let field)) = ClashReader.decodeConfigs(data) else {
            return XCTFail("Expected malformedJSON")
        }
        XCTAssertEqual(field, "mixed-port")
    }

    func testJSONConfigsAllowLanAsNumberRejected() {
        let data = Data(#"{"allow-lan":1}"#.utf8)
        guard case .failure(.malformedJSON(let field)) = ClashReader.decodeConfigs(data) else {
            return XCTFail("Expected malformedJSON")
        }
        XCTAssertEqual(field, "allow-lan")
    }

    func testJSONConfigsOutOfRangePortRejected() {
        let data = Data(#"{"mixed-port":99999}"#.utf8)
        guard case .failure(.malformedJSON(let field)) = ClashReader.decodeConfigs(data) else {
            return XCTFail("Expected malformedJSON")
        }
        XCTAssertEqual(field, "mixed-port")
    }

    func testJSONConfigsPayloadOverLimitRejected() {
        let big = Data(repeating: 0x20, count: ClashReader.maxBodyBytes + 1)
        guard case .failure(.exceededBodyLimit) = ClashReader.decodeConfigs(big) else {
            return XCTFail("Expected exceededBodyLimit")
        }
    }

    func testJSONVersionRootArrayRejected() {
        let data = Data(#"[{"version":"1.0"}]"#.utf8)
        guard case .failure(.malformedJSON) = ClashReader.decodeVersion(data) else {
            return XCTFail("Expected malformedJSON")
        }
    }
}

// MARK: - Regression: adversarial HTTP framing

extension ClashReaderTests {

    func testNegativeChunkSizeNeverCrashes() {
        let raw = Data("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n-5\r\nhello\r\n".utf8)
        guard case .failure(.malformedChunk) = ClashReader.parseResponse(raw) else {
            return XCTFail("Expected malformedChunk")
        }
    }

    func testOverflowingChunkSizeRejected() {
        let raw = Data("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\nFFFFFFFFFFFFFFFFFF\r\n".utf8)
        guard case .failure(.malformedChunk) = ClashReader.parseResponse(raw) else {
            return XCTFail("Expected malformedChunk")
        }
    }

    func testNegativeContentLengthRejected() {
        let raw = Data("HTTP/1.1 200 OK\r\nContent-Length: -5\r\n\r\nhello".utf8)
        guard case .failure(.malformedContentLength) = ClashReader.parseResponse(raw) else {
            return XCTFail("Expected malformedContentLength")
        }
    }

    func testMalformedContentLengthRejected() {
        let raw = Data("HTTP/1.1 200 OK\r\nContent-Length: 5x\r\n\r\nhello".utf8)
        guard case .failure(.malformedContentLength) = ClashReader.parseResponse(raw) else {
            return XCTFail("Expected malformedContentLength")
        }
    }
}

// MARK: - Regression: YAML duplicates and complex values for known keys

extension ClashReaderTests {

    func testDuplicateKnownYAMLKeyRejected() {
        let yaml = "mode: rule\nmode: global\n"
        guard case .failure(.duplicateKey(let field)) = ClashReader.extractYAMLScalars(yaml) else {
            return XCTFail("Expected duplicateKey")
        }
        XCTAssertEqual(field, "mode")
    }

    func testComplexFlowValueForKnownKeyRejected() {
        guard case .failure(.malformedValue(let field)) = ClashReader.extractYAMLScalars("mode: [rule, global]\n") else {
            return XCTFail("Expected malformedValue")
        }
        XCTAssertEqual(field, "mode")
    }

    func testAnchorValueForKnownKeyRejected() {
        guard case .failure(.malformedValue) = ClashReader.extractYAMLScalars("mode: *modealias\n") else {
            return XCTFail("Expected malformedValue")
        }
    }

    func testEmptyValueForKnownKeyRejected() {
        guard case .failure(.malformedValue(let field)) = ClashReader.extractYAMLScalars("mixed-port:\n") else {
            return XCTFail("Expected malformedValue")
        }
        XCTAssertEqual(field, "mixed-port")
    }
}

// MARK: - Unix socket candidates (pure)

extension ClashReaderTests {

    func testSocketCandidatePathsAreFixedThree() {
        let paths = ClashReader.socketCandidatePaths(
            tempDir: "/var/folders/zz/T/", homeDir: "/Users/tester")
        XCTAssertEqual(paths, [
            "/var/folders/zz/T/verge-mihomo.sock",
            "/tmp/verge/verge-mihomo.sock",
            "/Users/tester/.config/verge/verge-mihomo.sock",
        ])
    }

    func testSocketCandidatePathsNormalizesMissingTrailingSlash() {
        let paths = ClashReader.socketCandidatePaths(
            tempDir: "/var/folders/zz/T", homeDir: "/Users/tester/")
        XCTAssertEqual(paths.first, "/var/folders/zz/T/verge-mihomo.sock")
        XCTAssertEqual(paths.last, "/Users/tester/.config/verge/verge-mihomo.sock")
    }

    func testOnlyNormalizedWhitelistPathsAreAllowed() {
        let candidates = ClashReader.socketCandidatePaths(
            tempDir: "/var/folders/zz/T", homeDir: "/Users/tester")
        XCTAssertTrue(ClashReader.isAllowedSocketPath(
            "/tmp/verge/../verge/verge-mihomo.sock", candidates: candidates))
        XCTAssertFalse(ClashReader.isAllowedSocketPath(
            "/tmp/other/verge-mihomo.sock", candidates: candidates))
    }
}

// MARK: - Socket candidate validation (lstat seam)

extension ClashReaderTests {

    private func makeStat(mode: mode_t, uid: uid_t) -> stat {
        var st = stat()
        st.st_mode = mode
        st.st_uid = uid
        return st
    }

    func testValidSocketWithSafeParentAccepted() {
        let sock = "/var/folders/zz/T/verge-mihomo.sock"
        let parent = "/var/folders/zz/T"
        let table: [String: stat] = [
            sock: makeStat(mode: mode_t(S_IFSOCK | 0o600), uid: 501),
            parent: makeStat(mode: mode_t(S_IFDIR | 0o755), uid: 501),
        ]
        XCTAssertTrue(ClashReader.validateSocketCandidate(
            path: sock, currentUID: 501, lstatPath: { table[$0] }))
    }

    func testValidSocketWithRootOwnedParentAccepted() {
        let sock = "/tmp/verge/verge-mihomo.sock"
        let table: [String: stat] = [
            sock: makeStat(mode: mode_t(S_IFSOCK | 0o600), uid: 0),
            "/tmp/verge": makeStat(mode: mode_t(S_IFDIR | 0o755), uid: 0),
        ]
        XCTAssertTrue(ClashReader.validateSocketCandidate(
            path: sock, currentUID: 501, lstatPath: { table[$0] }))
    }

    func testClashVergeSharedTempSocketAccepted() {
        let sock = "/tmp/verge/verge-mihomo.sock"
        let table: [String: stat] = [
            sock: makeStat(mode: mode_t(S_IFSOCK | 0o666), uid: 501),
            "/tmp/verge": makeStat(mode: mode_t(S_IFDIR | 0o2770), uid: 0),
        ]
        XCTAssertTrue(ClashReader.validateSocketCandidate(
            path: sock, currentUID: 501, lstatPath: { table[$0] }))
    }

    func testClashVergeWorldWritableParentRejected() {
        let sock = "/tmp/verge/verge-mihomo.sock"
        let table: [String: stat] = [
            sock: makeStat(mode: mode_t(S_IFSOCK | 0o666), uid: 501),
            "/tmp/verge": makeStat(mode: mode_t(S_IFDIR | 0o2777), uid: 0),
        ]
        XCTAssertFalse(ClashReader.validateSocketCandidate(
            path: sock, currentUID: 501, lstatPath: { table[$0] }))
    }

    func testRegularFileRejected() {
        let path = "/tmp/verge/verge-mihomo.sock"
        let table: [String: stat] = [
            path: makeStat(mode: mode_t(S_IFREG | 0o600), uid: 501),
            "/tmp/verge": makeStat(mode: mode_t(S_IFDIR | 0o755), uid: 501),
        ]
        XCTAssertFalse(ClashReader.validateSocketCandidate(
            path: path, currentUID: 501, lstatPath: { table[$0] }))
    }

    func testMissingSocketRejected() {
        let table: [String: stat] = ["/tmp/verge": makeStat(mode: mode_t(S_IFDIR | 0o755), uid: 501)]
        XCTAssertFalse(ClashReader.validateSocketCandidate(
            path: "/tmp/verge/verge-mihomo.sock", currentUID: 501, lstatPath: { table[$0] }))
    }

    func testGroupWritableParentRejected() {
        let sock = "/tmp/verge/verge-mihomo.sock"
        let table: [String: stat] = [
            sock: makeStat(mode: mode_t(S_IFSOCK | 0o600), uid: 501),
            "/tmp/verge": makeStat(mode: mode_t(S_IFDIR | 0o770), uid: 501),
        ]
        XCTAssertFalse(ClashReader.validateSocketCandidate(
            path: sock, currentUID: 501, lstatPath: { table[$0] }))
    }

    func testOtherWritableParentRejected() {
        let sock = "/tmp/verge/verge-mihomo.sock"
        let table: [String: stat] = [
            sock: makeStat(mode: mode_t(S_IFSOCK | 0o600), uid: 501),
            "/tmp/verge": makeStat(mode: mode_t(S_IFDIR | 0o757), uid: 501),
        ]
        XCTAssertFalse(ClashReader.validateSocketCandidate(
            path: sock, currentUID: 501, lstatPath: { table[$0] }))
    }

    func testParentOwnedByOtherUserRejected() {
        let sock = "/tmp/other/verge-mihomo.sock"
        let table: [String: stat] = [
            sock: makeStat(mode: mode_t(S_IFSOCK | 0o600), uid: 501),
            "/tmp/other": makeStat(mode: mode_t(S_IFDIR | 0o755), uid: 12345),
        ]
        XCTAssertFalse(ClashReader.validateSocketCandidate(
            path: sock, currentUID: 501, lstatPath: { table[$0] }))
    }


    func testSocketOwnedByOtherUserRejected() {
        let sock = "/tmp/verge/verge-mihomo.sock"
        let table: [String: stat] = [
            sock: makeStat(mode: mode_t(S_IFSOCK | 0o600), uid: 12345),
            "/tmp/verge": makeStat(mode: mode_t(S_IFDIR | 0o755), uid: 501),
        ]
        XCTAssertFalse(ClashReader.validateSocketCandidate(
            path: sock, currentUID: 501, lstatPath: { table[$0] }))
    }
}

// MARK: - Request building (pure)

extension ClashReaderTests {

    func testBuildRequestWithoutSecret() {
        guard let reqData = ClashReader.buildRequest(path: "/version", secret: nil) else {
            return XCTFail("Expected request")
        }
        let req = String(decoding: reqData, as: UTF8.self)
        XCTAssertTrue(req.hasPrefix("GET /version HTTP/1.1\r\n"))
        XCTAssertFalse(req.contains("Authorization"))
    }

    func testBuildRequestWithSecretKeptInHeaderOnly() {
        // Dummy marker only; never a real token. Not printed on failure.
        guard let reqData = ClashReader.buildRequest(path: "/configs", secret: "dummy-secret") else {
            return XCTFail("Expected request")
        }
        let req = String(decoding: reqData, as: UTF8.self)
        XCTAssertTrue(req.contains("Authorization: Bearer dummy-secret\r\n"))
        XCTAssertTrue(req.hasPrefix("GET /configs HTTP/1.1\r\n"))
    }

    // MARK: - Request path whitelist (CRLF / request-smuggling injection)

    func testBuildRequestAcceptsOnlyWhitelistedPaths() {
        XCTAssertNotNil(ClashReader.buildRequest(path: "/version", secret: nil))
        XCTAssertNotNil(ClashReader.buildRequest(path: "/configs", secret: nil))
        XCTAssertNotNil(ClashReader.buildRequest(path: "/proxies", secret: nil))
        XCTAssertTrue(ClashReader.isAllowedHTTPPath("/version"))
        XCTAssertTrue(ClashReader.isAllowedHTTPPath("/configs"))
        XCTAssertTrue(ClashReader.isAllowedHTTPPath("/proxies"))
    }

    func testBuildRequestRejectsCRLFAndNonWhitelistedPaths() {
        // CRLF injection: caller-supplied path cannot smuggle a second request
        // line, extra headers, or an early body.
        XCTAssertNil(ClashReader.buildRequest(
            path: "/proxies HTTP/1.1\r\nHost: evil\r\n\r\nGET /configs HTTP/1.1\r\n", secret: nil))
        XCTAssertNil(ClashReader.buildRequest(path: "/version\r\nX-Injected: 1", secret: nil))
        // Anything other than the exact three paths is rejected.
        XCTAssertNil(ClashReader.buildRequest(path: "/version/", secret: nil))
        XCTAssertNil(ClashReader.buildRequest(path: "/version?x=1", secret: nil))
        XCTAssertNil(ClashReader.buildRequest(path: "/configs/../proxies", secret: nil))
        XCTAssertNil(ClashReader.buildRequest(path: "/reload", secret: nil))
        XCTAssertNil(ClashReader.buildRequest(path: "", secret: nil))
        XCTAssertFalse(ClashReader.isAllowedHTTPPath("/reload"))
    }

    func testProxyDelayPathEncodesOneBoundedSegment() {
        let path = ClashReader.proxyDelayPath(proxyName: "香港/01")
        XCTAssertEqual(
            path,
            "/proxies/%E9%A6%99%E6%B8%AF%2F01/delay?url=https%3A%2F%2Fwww.gstatic.com%2Fgenerate_204&timeout=3000&expected=204"
        )
        XCTAssertTrue(ClashReader.isAllowedHTTPPath(path!))
        XCTAssertNil(ClashReader.proxyDelayPath(proxyName: "DIRECT"))
        XCTAssertNil(ClashReader.proxyDelayPath(proxyName: String(repeating: "a", count: 513)))
        XCTAssertFalse(ClashReader.isAllowedHTTPPath("/proxies/a\r\nX-Test: 1/delay"))
    }
}


// MARK: - Active proxy delay decoding

extension ClashReaderTests {
    func testDecodeProxyDelayAcceptsPositiveMilliseconds() {
        XCTAssertEqual(ClashReader.decodeProxyDelay(Data(#"{"delay":42}"#.utf8)), .success(42))
    }

    func testDecodeProxyDelayRejectsZeroAndWrongTypes() {
        XCTAssertEqual(
            ClashReader.decodeProxyDelay(Data(#"{"delay":0}"#.utf8)),
            .failure(.malformedJSON(field: "delay"))
        )
        XCTAssertEqual(
            ClashReader.decodeProxyDelay(Data(#"{"delay":"42"}"#.utf8)),
            .failure(.malformedJSON(field: "delay"))
        )
    }
}

// MARK: - Loopback endpoint parsing (pure)

extension ClashReaderTests {

    func testLoopbackEndpointsAccepted() {
        XCTAssertEqual(ClashReader.loopbackHostPort(from: "127.0.0.1:9090")?.port, 9090)
        XCTAssertEqual(ClashReader.loopbackHostPort(from: "localhost:9090")?.port, 9090)
    }

    func testNonLoopbackEndpointsRejected() {
        XCTAssertNil(ClashReader.loopbackHostPort(from: "0.0.0.0:9090"))
        XCTAssertNil(ClashReader.loopbackHostPort(from: "192.168.1.5:9090"))
        XCTAssertNil(ClashReader.loopbackHostPort(from: "example.com:9090"))
        XCTAssertNil(ClashReader.loopbackHostPort(from: "[::1]:9090"))
        XCTAssertNil(ClashReader.loopbackHostPort(from: ":9090"))
    }

    func testMalformedPortsRejected() {
        XCTAssertNil(ClashReader.loopbackHostPort(from: "127.0.0.1:0"))
        XCTAssertNil(ClashReader.loopbackHostPort(from: "127.0.0.1:99999"))
        XCTAssertNil(ClashReader.loopbackHostPort(from: "127.0.0.1:abc"))
        XCTAssertNil(ClashReader.loopbackHostPort(from: "127.0.0.1"))
    }
}

// MARK: - /proxies decoding (whitelisted)

extension ClashReaderTests {

    func testProxiesPrefersGlobal() {
        let json = """
        {"proxies":{"GLOBAL":{"type":"Selector","now":"ProxyA","all":["ProxyA","ProxyB"]},
         "Group1":{"type":"Selector","now":"ProxyB","all":["ProxyB"]}}}
        """
        let result = ClashReader.decodeProxies(Data(json.utf8))
        guard case .success(let sel) = result, let sel = sel else {
            return XCTFail("Expected success with selection")
        }
        XCTAssertEqual(sel.group, "GLOBAL")
        XCTAssertEqual(sel.selected, "ProxyA")
        XCTAssertEqual(sel.delay, nil)
    }

    func testProxiesFallsBackToFirstSelectorWithNow() {
        let json = """
        {"proxies":{"DIRECT":{"type":"Direct"},"Group2":{"type":"Selector","now":"ProxyB"},
         "Group3":{"type":"Selector","now":"ProxyC"}}}
        """
        let result = ClashReader.decodeProxies(Data(json.utf8))
        guard case .success(let sel) = result, let sel = sel else {
            return XCTFail("Expected success with selection")
        }
        XCTAssertEqual(sel.group, "Group2")
        XCTAssertEqual(sel.selected, "ProxyB")
    }

    func testProxiesResolvesNestedSelectionToLeaf() {
        let json = #"{"proxies":{"GLOBAL":{"type":"Selector","now":"Proxy"},"Proxy":{"type":"Selector","now":"DIRECT"},"DIRECT":{"type":"Direct"}}}"#
        guard case .success(let sel) = ClashReader.decodeProxies(Data(json.utf8)) else {
            return XCTFail("Expected success")
        }
        XCTAssertEqual(sel?.selected, "DIRECT")
        XCTAssertNil(ClashReader.proxyDelayPath(proxyName: sel?.selected ?? ""))
    }

    func testProxiesExtractsLatestNumericDelay() {
        let json = """
        {"proxies":{"GLOBAL":{"type":"Selector","now":"ProxyA",
         "history":[{"delay":120},{"delay":340}]}}}
        """
        let result = ClashReader.decodeProxies(Data(json.utf8))
        guard case .success(let sel) = result, let sel = sel else {
            return XCTFail("Expected success with selection")
        }
        XCTAssertEqual(sel.delay, 340)
    }

    func testProxiesNonNumericDelayTreatedAsAbsent() {
        let json = """
        {"proxies":{"GLOBAL":{"type":"Selector","now":"ProxyA","history":[{"delay":"fast"}]}}}
        """
        let result = ClashReader.decodeProxies(Data(json.utf8))
        guard case .success(let sel) = result, let sel = sel else {
            return XCTFail("Expected success with selection")
        }
        XCTAssertNil(sel.delay)
    }

    func testProxiesNoSuitableGroupReturnsNil() {
        let json = """
        {"proxies":{"DIRECT":{"type":"Direct"},"Group1":{"type":"Selector","all":[]}}}
        """
        guard case .success(let sel) = ClashReader.decodeProxies(Data(json.utf8)) else {
            return XCTFail("Expected success")
        }
        XCTAssertNil(sel)
    }

    func testProxiesAdversarialProxiesAsArrayRejected() {
        let data = Data(#"{"proxies":["GLOBAL"]}"#.utf8)
        guard case .failure(.malformedJSON(let field)) = ClashReader.decodeProxies(data) else {
            return XCTFail("Expected malformedJSON")
        }
        XCTAssertEqual(field, "proxies")
    }

    func testProxiesGlobalNowWrongTypeRejected() {
        let data = Data(#"{"proxies":{"GLOBAL":{"type":"Selector","now":123}}}"#.utf8)
        guard case .failure(.malformedJSON(let field)) = ClashReader.decodeProxies(data) else {
            return XCTFail("Expected malformedJSON")
        }
        XCTAssertEqual(field, "now")
    }

    func testProxiesSelectorNowWrongTypeRejected() {
        let data = Data(#"{"proxies":{"Group1":{"type":"Selector","now":[1,2]}}}"#.utf8)
        guard case .failure(.malformedJSON) = ClashReader.decodeProxies(data) else {
            return XCTFail("Expected malformedJSON")
        }
    }

    func testProxiesOverLimitRejected() {
        let big = Data(repeating: 0x20, count: ClashReader.maxBodyBytes + 1)
        guard case .failure(.exceededBodyLimit) = ClashReader.decodeProxies(big) else {
            return XCTFail("Expected exceededBodyLimit")
        }
    }
}

// MARK: - Cancellation resume-once (deterministic, no live connection)

extension ClashReaderTests {

    func testResumeOnceDeliversExactlyOnce() async {
        let gate = ClashReader.ResumeOnce()
        let lock = NSLock()
        var received: Result<ClashReader.Response, ClashReader.ReadError>?

        let consumer = Task {
            let result = await withCheckedContinuation {
                (c: CheckedContinuation<Result<ClashReader.Response, ClashReader.ReadError>, Never>) in
                gate.install(c)
            }
            lock.lock(); received = result; lock.unlock()
        }
        await Task.yield()

        // Two resumes: only the first must be delivered.
        gate.resume(.failure(.timeout))
        gate.resume(.success(ClashReader.Response(statusCode: 200, headers: [:], body: Data())))

        await consumer.value
        lock.lock(); let value = received; lock.unlock()
        XCTAssertEqual(value, .failure(.timeout))
    }

    func testCancellationBeforeInstallStillResumesExactlyOnce() async {
        // Simulates onCancel firing before the operation body ever installs the
        // continuation — the case that could otherwise hang forever.
        let gate = ClashReader.ResumeOnce()
        gate.resume(.failure(.timeout))
        gate.resume(.failure(.transport)) // second resume must be ignored

        let result = await withCheckedContinuation {
            (c: CheckedContinuation<Result<ClashReader.Response, ClashReader.ReadError>, Never>) in
            gate.install(c)
        }
        XCTAssertEqual(result, .failure(.timeout))
        XCTAssertTrue(gate.isDone)
    }

    func testResumeOnceNotDoneBeforeResume() async {
        let gate = ClashReader.ResumeOnce()
        XCTAssertFalse(gate.isDone)
        let consumer = Task {
            await withCheckedContinuation {
                (c: CheckedContinuation<Result<ClashReader.Response, ClashReader.ReadError>, Never>) in
                gate.install(c)
            }
        }
        await Task.yield()
        XCTAssertFalse(gate.isDone)
        gate.resume(.failure(.transport))
        await consumer.value
        XCTAssertTrue(gate.isDone)
    }
}

// MARK: - /connections decoding (task: Mihomo read-only telemetry)

extension ClashReaderTests {

    private func connJSON(
        connections: [[String: Any]],
        upload: Any = 1000,
        download: Any = 2000
    ) -> Data {
        var dict: [String: Any] = ["uploadTotal": upload, "downloadTotal": download]
        dict["connections"] = connections
        let data = try! JSONSerialization.data(withJSONObject: dict)
        return data
    }

    private func connection(
        chains: [String],
        host: String = "example.com",
        process: String = "curl",
        rule: String = "MATCH",
        ip: String = "1.2.3.4"
    ) -> [String: Any] {
        ["chains": chains,
         "metadata": ["host": host, "process": process, "rule": rule,
                      "destinationIP": ip, "chain": chains]]
    }

    func testConnectionsPrivacyFieldsDoNotLeak() {
        let data = connJSON(connections: [
            connection(chains: ["ProxyA"], host: "secret-host", process: "secret-proc", rule: "secret-rule", ip: "9.9.9.9"),
            connection(chains: ["DIRECT"]),
        ])
        guard case .success(let s) = ClashReader.decodeConnections(data) else {
            return XCTFail("Expected success")
        }
        XCTAssertEqual(s.activeConnectionCount, 2)
        XCTAssertEqual(s.proxiedConnectionCount, 1)
        XCTAssertEqual(s.uploadTotal, 1000)
        XCTAssertEqual(s.downloadTotal, 2000)
        XCTAssertTrue(s.proxyTrafficObserved)
        // The summary exposes no host/process/rule/ip — it cannot reference them.
        XCTAssertEqual(
            Mirror(reflecting: s).children.map { $0.label },
            ["activeConnectionCount", "proxiedConnectionCount", "uploadTotal", "downloadTotal", "proxyTrafficObserved"])
    }

    func testDirectConnectionsAreNotProxyTraffic() {
        let data = connJSON(connections: [
            connection(chains: ["DIRECT"]),
            connection(chains: ["DIRECT"]),
        ])
        guard case .success(let s) = ClashReader.decodeConnections(data) else {
            return XCTFail("Expected success")
        }
        XCTAssertEqual(s.activeConnectionCount, 2)
        XCTAssertEqual(s.proxiedConnectionCount, 0, "DIRECT chains must not count as proxied traffic")
        XCTAssertFalse(s.proxyTrafficObserved)
    }

    func testConnectionsProxiedWhenChainHasNonDirectHop() {
        // A chain that ends in DIRECT but traverses a proxy still counts as proxied.
        let data = connJSON(connections: [connection(chains: ["ProxyA", "DIRECT"])])
        guard case .success(let s) = ClashReader.decodeConnections(data) else {
            return XCTFail("Expected success")
        }
        XCTAssertEqual(s.proxiedConnectionCount, 1)
        XCTAssertTrue(s.proxyTrafficObserved)
    }

    func testConnectionsMissingChainsIsNotProxied() {
        let data = connJSON(connections: [["id": "x", "metadata": ["host": "h"]]])
        guard case .success(let s) = ClashReader.decodeConnections(data) else {
            return XCTFail("Expected success")
        }
        XCTAssertEqual(s.proxiedConnectionCount, 0, "unknown chain must be treated conservatively")
    }

    func testConnectionsMalformedTypesRejected() {
        // String total.
        guard case .failure(.malformedJSON) = ClashReader.decodeConnections(
            connJSON(connections: [], upload: "1000")) else {
            return XCTFail("string uploadTotal must be rejected")
        }
        // Float total.
        guard case .failure(.malformedJSON) = ClashReader.decodeConnections(
            connJSON(connections: [], upload: 1.5)) else {
            return XCTFail("float uploadTotal must be rejected")
        }
        // Boolean total.
        guard case .failure(.malformedJSON) = ClashReader.decodeConnections(
            connJSON(connections: [], upload: true)) else {
            return XCTFail("boolean uploadTotal must be rejected")
        }
        // Negative total.
        guard case .failure(.malformedJSON) = ClashReader.decodeConnections(
            connJSON(connections: [], upload: -5)) else {
            return XCTFail("negative uploadTotal must be rejected")
        }
        // connections not an array.
        guard case .failure(.malformedJSON(let field)) = ClashReader.decodeConnections(
            connJSON(connections: [], upload: 0).withReplacedTopLevel("connections", value: "nope")) else {
            return XCTFail("connections as string must be rejected")
        }
        XCTAssertEqual(field, "connections")
    }

    func testConnectionsOverLimitRejected() {
        let big = Data(repeating: 0x20, count: ClashReader.maxBodyBytes + 1)
        guard case .failure(.exceededBodyLimit) = ClashReader.decodeConnections(big) else {
            return XCTFail("Expected exceededBodyLimit")
        }
    }
}

private extension Data {
    func withReplacedTopLevel(_ key: String, value: Any) -> Data {
        var dict: [String: Any]
        if let o = (try? JSONSerialization.jsonObject(with: self)) as? [String: Any] {
            dict = o
        } else {
            dict = [:]
        }
        dict[key] = value
        return try! JSONSerialization.data(withJSONObject: dict)
    }
}

// MARK: - Same-provider peer-node health sampling (task: Mihomo read-only telemetry)

extension ClashReaderTests {

    private func proxiesJSON(currentLeaf: String, current: [String: Any], others: [String: Any]) -> Data {
        var all = others
        all[currentLeaf] = current
        let data = try! JSONSerialization.data(withJSONObject: ["proxies": all])
        return data
    }

    private func leaf(type: String = "Vmess", providerName: String? = nil, legacyProvider: String? = nil, now: String? = nil) -> [String: Any] {
        var d: [String: Any] = ["type": type]
        if let providerName { d["provider-name"] = providerName }
        if let legacyProvider { d["provider"] = legacyProvider }
        if let now { d["now"] = now }
        return d
    }

    func testSameProviderCapsAtTwoNodes() {
        let data = proxiesJSON(
            currentLeaf: "A", current: leaf(providerName: "subA", now: "A"),
            others: [
                "B": leaf(providerName: "subA"),
                "C": leaf(providerName: "subA"),
                "D": leaf(providerName: "subA"),
            ])
        guard case .success(let candidates) = ClashReader.sameProviderCandidates(
            fromProxies: data, currentLeaf: "A") else {
            return XCTFail("Expected success")
        }
        XCTAssertEqual(candidates?.count, 2, "must sample at most two same-provider peers")
    }

    func testSameProviderUsesProviderNameKey() {
        // Real Mihomo exposes provider-name (official key); provider is legacy.
        let data = proxiesJSON(
            currentLeaf: "A", current: leaf(providerName: "subA", now: "A"),
            others: [
                "B": leaf(providerName: "subA"),
                "C": leaf(providerName: "subB"),
            ])
        guard case .success(let candidates) = ClashReader.sameProviderCandidates(
            fromProxies: data, currentLeaf: "A") else {
            return XCTFail("Expected success")
        }
        XCTAssertEqual(candidates, ["B"], "provider-name is the primary matching key")
    }

    func testSameProviderFallsBackToLegacyProviderKey() {
        // When provider-name is absent everywhere, the legacy provider key is used.
        let data = proxiesJSON(
            currentLeaf: "A", current: leaf(legacyProvider: "subA", now: "A"),
            others: ["B": leaf(legacyProvider: "subA"), "C": leaf(legacyProvider: "subB")])
        guard case .success(let candidates) = ClashReader.sameProviderCandidates(
            fromProxies: data, currentLeaf: "A") else {
            return XCTFail("Expected success")
        }
        XCTAssertEqual(candidates, ["B"], "legacy provider key is accepted as a fallback")
    }

    func testSameProviderProviderNameTakesPrecedenceOverLegacy() {
        // A node with a legacy provider key but no provider-name must NOT match a
        // current leaf whose provider-name differs.
        let data = proxiesJSON(
            currentLeaf: "A", current: leaf(providerName: "subA", legacyProvider: "legacyB", now: "A"),
            others: ["B": leaf(legacyProvider: "legacyB")])
        guard case .success(let candidates) = ClashReader.sameProviderCandidates(
            fromProxies: data, currentLeaf: "A") else {
            return XCTFail("Expected success")
        }
        XCTAssertNil(candidates, "provider-name mismatch must not be rescued by the legacy key")
    }

    func testSameProviderExcludesDifferentProvidersAndDirect() {
        let data = proxiesJSON(
            currentLeaf: "A", current: leaf(providerName: "subA", now: "A"),
            others: [
                "B": leaf(providerName: "subA"),
                "C": leaf(providerName: "subB"),
                "D": leaf(providerName: "subA"),
                "DIRECT": ["type": "Direct"],
            ])
        guard case .success(let candidates) = ClashReader.sameProviderCandidates(
            fromProxies: data, currentLeaf: "A") else {
            return XCTFail("Expected success")
        }
        XCTAssertEqual(candidates?.count, 2, "only subA peers count; DIRECT and subB excluded")
        XCTAssertFalse(candidates?.contains("DIRECT") == true)
        XCTAssertFalse(candidates?.contains("C") == true)
    }

    func testSameProviderNoCandidateIsUnavailable() {
        // Provider present but no distinct same-provider leaf.
        let data = proxiesJSON(
            currentLeaf: "A", current: leaf(providerName: "subA", now: "A"),
            others: ["B": leaf(providerName: "subB")])
        guard case .success(let candidates) = ClashReader.sameProviderCandidates(
            fromProxies: data, currentLeaf: "A") else {
            return XCTFail("Expected success")
        }
        XCTAssertNil(candidates, "no same-provider peer must signal unavailable")

        // Provider not reliably present.
        let data2 = proxiesJSON(
            currentLeaf: "A", current: leaf(now: "A"),
            others: ["B": leaf(providerName: "subB")])
        guard case .success(let c2) = ClashReader.sameProviderCandidates(
            fromProxies: data2, currentLeaf: "A") else {
            return XCTFail("Expected success")
        }
        XCTAssertNil(c2, "missing provider must signal unavailable")
    }

    func testSameProviderExcludesCurrentLeaf() {
        let data = proxiesJSON(
            currentLeaf: "A", current: leaf(providerName: "subA", now: "A"),
            others: ["B": leaf(providerName: "subA")])
        guard case .success(let candidates) = ClashReader.sameProviderCandidates(
            fromProxies: data, currentLeaf: "A") else {
            return XCTFail("Expected success")
        }
        XCTAssertEqual(candidates?.count, 1, "the current leaf itself must be excluded")
        XCTAssertFalse(candidates?.contains("A") == true)
    }

    func testSameProviderExcludesPolicyGroupsWithSameProvider() async {
        // Groups also carry provider-name in real Mihomo; they must never be
        // sampled as if they were same-airport leaf nodes.
        let data = proxiesJSON(
            currentLeaf: "A", current: leaf(providerName: "subA", now: "A"),
            others: [
                "B": leaf(type: "Selector", providerName: "subA"),
                "C": leaf(type: "URLTest", providerName: "subA"),
                "D": leaf(type: "Fallback", providerName: "subA"),
                "E": leaf(type: "LoadBalance", providerName: "subA"),
                "F": leaf(type: "Vmess", providerName: "subA"),
            ])
        guard case .success(let candidates) = ClashReader.sameProviderCandidates(
            fromProxies: data, currentLeaf: "A") else {
            return XCTFail("Expected success")
        }
        XCTAssertEqual(candidates, ["F"], "only ordinary leaf proxies are sampled as peers")
    }

    func testSameProviderExcludesSpecialAndDirectTypes() async {
        let data = proxiesJSON(
            currentLeaf: "A", current: leaf(providerName: "subA", now: "A"),
            others: [
                "B": leaf(type: "Direct", providerName: "subA"),
                "C": leaf(type: "Reject", providerName: "subA"),
                "D": leaf(type: "RejectDrop", providerName: "subA"),
                "E": leaf(type: "Pass", providerName: "subA"),
                "F": leaf(type: "Trojan", providerName: "subA"),
            ])
        guard case .success(let candidates) = ClashReader.sameProviderCandidates(
            fromProxies: data, currentLeaf: "A") else {
            return XCTFail("Expected success")
        }
        XCTAssertEqual(candidates, ["F"], "Direct/Reject/Pass types must not be sampled")
    }

    func testSameProviderOverLimitRejected() {
        let big = Data(repeating: 0x20, count: ClashReader.maxBodyBytes + 1)
        guard case .failure(.exceededBodyLimit) = ClashReader.sameProviderCandidates(
            fromProxies: big, currentLeaf: "A") else {
            return XCTFail("Expected exceededBodyLimit")
        }
    }

    // MARK: - Path safety for the new dynamic /connections path

    func testConnectionsPathIsWhitelistedAndInjectionSafe() {
        XCTAssertTrue(ClashReader.isAllowedHTTPPath("/connections"))
        XCTAssertNotNil(ClashReader.buildRequest(path: "/connections", secret: nil))
        // CRLF injection through the fixed path must still be rejected.
        XCTAssertNil(ClashReader.buildRequest(path: "/connections\r\nGET /configs HTTP/1.1\r\n", secret: nil))
        XCTAssertNil(ClashReader.buildRequest(path: "/connections ", secret: nil))
        XCTAssertFalse(ClashReader.isAllowedHTTPPath("/connections/"))
    }

    // MARK: - Concurrent delay probes (budget correction)

    func testCandidateDelayProbesRunConcurrently() async {
        let active = ProbeCounter()
        let maxActive = ProbeCounter()
        let start = ContinuousClock.now
        let succeeded = await ClashReader.runCandidateDelayProbes(["a", "b", "c"]) { _ in
            active.increment()
            maxActive.updateMax(active.value)
            try? await Task.sleep(for: .milliseconds(200))
            active.decrement()
            return true
        }
        let elapsed = ContinuousClock.now - start
        let elapsedMs = Int(elapsed.components.seconds) * 1000
            + Int(elapsed.components.attoseconds / 1_000_000_000_000_000)

        XCTAssertEqual(succeeded, 3, "result is an aggregate success count only")
        XCTAssertGreaterThanOrEqual(maxActive.value, 2, "delay probes must run concurrently")
        XCTAssertLessThan(elapsedMs, 450,
                         "3×200ms probes must finish in ~one latency, not the 600ms serial sum")
    }

    func testCandidateDelayProbesAggregateCountOnly() async {
        // Mixed outcomes: only the success count is returned — no names.
        let succeeded = await ClashReader.runCandidateDelayProbes(["a", "b", "c"]) { name in
            name != "b" // a and c succeed, b fails
        }
        XCTAssertEqual(succeeded, 2)
    }
}
