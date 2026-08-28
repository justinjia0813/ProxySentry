import XCTest
@testable import ProxySentry

final class DiagnosisTests: XCTestCase {

    // MARK: - Fixtures

    /// Snapshot for a fully healthy proxied network (green candidate).
    private func proxiedHealthy() -> NetworkSnapshot {
        NetworkSnapshot(
            systemProxyConfigured: true,
            tunEnabled: false,
            directOutcomes: [.success, .success],
            proxyOutcomes: [.success, .success],
            clashActiveProxyOutcome: .success,
            localProxyEndpointConfigured: true,
            proxyExitVerifiedThroughSystemRoute: true,
            localProxyPortReachable: true,
            clashVersionOutcome: .success,
            clashConfigsOutcome: .success,
            clashPortsMatchConfiguredProxy: true,
            clashInfoAvailable: true,
            pacConfigured: false,
            proxyAutoDiscovery: false,
            unrelatedLocalPortsListening: false,
            directIndependentlyDecidable: true
        )
    }

    /// Snapshot with no proxy route and working direct connectivity (blue candidate).
    private func directHealthyNoProxy() -> NetworkSnapshot {
        NetworkSnapshot(
            systemProxyConfigured: false,
            tunEnabled: false,
            directOutcomes: [.success, .success],
            proxyOutcomes: [],
            localProxyPortReachable: false,
            clashVersionOutcome: nil,
            clashConfigsOutcome: nil,
            clashPortsMatchConfiguredProxy: false,
            clashInfoAvailable: false,
            pacConfigured: false,
            proxyAutoDiscovery: false,
            unrelatedLocalPortsListening: true,
            directIndependentlyDecidable: true
        )
    }

    /// Red-candidate snapshot: proxied, direct partly works, Clash healthy,
    /// both proxy targets failing. Every red gate holds in this base.
    private func redCandidate() -> NetworkSnapshot {
        NetworkSnapshot(
            systemProxyConfigured: true,
            tunEnabled: false,
            directOutcomes: [.success, .failure],
            proxyOutcomes: [.failure, .failure],
            clashActiveProxyOutcome: .failure,
            localProxyEndpointConfigured: true,
            proxyExitVerifiedThroughSystemRoute: true,
            localProxyPortReachable: true,
            clashVersionOutcome: .success,
            clashConfigsOutcome: .success,
            clashPortsMatchConfiguredProxy: true,
            clashInfoAvailable: true,
            pacConfigured: false,
            proxyAutoDiscovery: false,
            unrelatedLocalPortsListening: false,
            directIndependentlyDecidable: true
        )
    }

    private func baseNetworkWorksButLocalProxyDown() -> NetworkSnapshot {
        var s = proxiedHealthy()
        s.proxyOutcomes = [.failure, .failure]
        s.localProxyPortReachable = false
        return s
    }

    // MARK: - 1. Green priority; green requires a proxy route

    func testGreenWhenConfiguredSystemProxyExitSucceeds() {
        let state = DiagnosisClassifier.classify(proxiedHealthy())
        XCTAssertEqual(state.kind, .green)
        XCTAssertEqual(state.title, "代理工作正常")
    }

    func testTunNodeHealthAloneIsNotGreen() {
        var s = proxiedHealthy()
        s.systemProxyConfigured = false
        s.tunEnabled = true
        s.proxyExitVerifiedThroughSystemRoute = false
        let state = DiagnosisClassifier.classify(s)
        XCTAssertNotEqual(state.kind, .green)
    }

    func testUnknownNodeHealthDoesNotBecomeUpstreamFailure() {
        var s = redCandidate()
        s.clashActiveProxyOutcome = nil
        XCTAssertNotEqual(DiagnosisClassifier.classify(s).kind, .red)
        s.clashActiveProxyOutcome = .unavailable
        XCTAssertNotEqual(DiagnosisClassifier.classify(s).kind, .red)
    }

    func testSuccessAloneWithoutProxyRouteIsNotGreen() {
        var s = proxiedHealthy()
        s.systemProxyConfigured = false
        s.tunEnabled = false
        s.proxyExitVerifiedThroughSystemRoute = false
        let state = DiagnosisClassifier.classify(s)
        XCTAssertNotEqual(state.kind, .green)
    }

    // MARK: - 2. Blue

    func testBlueWhenNoProxyAndDirectSucceeds() {
        let state = DiagnosisClassifier.classify(directHealthyNoProxy())
        XCTAssertEqual(state.kind, .blue)
        XCTAssertEqual(state.title, "系统未使用代理，直连网络正常")
    }

    func testHealthyNodeWithOnlyUnresolvedAutomaticRouteIsNotLocalConfigFailure() {
        var s = directHealthyNoProxy()
        s.systemProxyConfigured = true
        s.pacConfigured = true
        s.clashActiveProxyOutcome = .success

        let state = DiagnosisClassifier.classify(s)

        XCTAssertEqual(state.kind, .blue)
        XCTAssertEqual(state.title, "代理节点正常，系统路由未确认")
    }

    // MARK: - 3. Yellow

    func testYellowWhenBaseNetworkWorksButLocalProxyUnreachable() {
        let state = DiagnosisClassifier.classify(baseNetworkWorksButLocalProxyDown())
        XCTAssertEqual(state.kind, .yellow)
        XCTAssertEqual(state.title, "本机代理配置异常")
    }

    func testYellowWhenPortsMismatch() {
        // Proxy exit must NOT succeed, otherwise green-priority wins.
        var s = redCandidate()
        s.proxyOutcomes = [.failure, .failure]
        s.clashPortsMatchConfiguredProxy = false
        s.localProxyPortReachable = true
        let state = DiagnosisClassifier.classify(s)
        XCTAssertEqual(state.kind, .yellow)
        XCTAssertEqual(state.title, "本机代理配置异常")
    }

    // MARK: - 4. Red

    func testRedWhenAllRedConditionsHold() {
        let state = DiagnosisClassifier.classify(redCandidate())
        XCTAssertEqual(state.kind, .red)
        XCTAssertEqual(state.title, "疑似机场或节点故障")
    }

    func testRedRequiresAtLeastTwoProxyOutcomes() {
        var s = redCandidate()
        s.proxyOutcomes = [.failure]
        let state = DiagnosisClassifier.classify(s)
        XCTAssertNotEqual(state.kind, .red, "single proxy outcome must not be red")
    }

    // MARK: - 5. Red near-misses: exactly one gate mutated each

    func testRedNearMissesSingleGateMutations() {
        // Each case mutates exactly one red gate of the redCandidate base.
        let cases: [(String, (inout NetworkSnapshot) -> Void)] = [
            // no proxy route (the only gate that removes the route)
            ("no proxy route", { $0.systemProxyConfigured = false }),
            // only /version succeeded
            ("only version ok", { $0.clashConfigsOutcome = .failure }),
            // port mismatch
            ("port mismatch", { $0.clashPortsMatchConfiguredProxy = false }),
            // Clash info unavailable
            ("clash info unavailable", { $0.clashInfoAvailable = false }),
            // PAC unresolved
            ("pac unresolved", { $0.pacConfigured = true }),
            // TUN makes direct indecidable
            ("direct indecidable", { $0.directIndependentlyDecidable = false }),
            // direct and proxy both failing
            ("direct also down", { $0.directOutcomes = [.failure, .timeout] }),
            // local port unreachable
            ("local port unreachable", { $0.localProxyPortReachable = false }),
        ]

        for (name, mutate) in cases {
            var s = redCandidate()
            mutate(&s)
            let state = DiagnosisClassifier.classify(s)
            XCTAssertNotEqual(state.kind, .red, name)
        }
    }

    func testUnrelatedListeningPortsWithoutProxyIsNotRed() {
        // No proxy route at all, an unrelated local port is listening.
        var s = redCandidate()
        s.systemProxyConfigured = false
        s.tunEnabled = false
        s.unrelatedLocalPortsListening = true
        let state = DiagnosisClassifier.classify(s)
        XCTAssertNotEqual(state.kind, .red)
    }

    // MARK: - 6. Gray with minimal gap explanation

    func testGrayWhenEvidenceInsufficient() {
        let empty = NetworkSnapshot()
        let state = DiagnosisClassifier.classify(empty)
        XCTAssertEqual(state.kind, .gray)
        XCTAssertEqual(state.title, "网络不可用或暂时无法定位")
        XCTAssertFalse(state.missingEvidenceExplanation.isEmpty)
    }

    func testGrayExplanationMentionsDirectGapWhenNoDirectEvidence() {
        var s = directHealthyNoProxy()
        s.directOutcomes = []
        let state = DiagnosisClassifier.classify(s)
        XCTAssertEqual(state.kind, .gray)
        XCTAssertTrue(state.missingEvidenceExplanation.contains("直连"), state.missingEvidenceExplanation)
    }

    func testGrayStatesWithDifferentExplanationsAreNotEqual() {
        // Value-semantic Equatable includes the explanation.
        let a = DiagnosisClassifier.classify(NetworkSnapshot())
        var b = NetworkSnapshot()
        b.systemProxyConfigured = true
        let c = DiagnosisClassifier.classify(b)
        XCTAssertEqual(a.kind, c.kind)
        XCTAssertNotEqual(a, c, "explanations differ, values must differ")
    }

    // MARK: - 7. Summaries must not leak secrets / subscription URLs / node lists

    private func assertSanitized(_ text: String, _ label: String) {
        XCTAssertFalse(text.lowercased().contains("secret"), label)
        XCTAssertFalse(text.lowercased().contains("subscription"), label)
        XCTAssertFalse(text.lowercased().contains("订阅"), label)
        XCTAssertFalse(text.lowercased().contains("token"), label)
        XCTAssertFalse(text.lowercased().contains("http://"), label)
        XCTAssertFalse(text.lowercased().contains("https://"), label)
        XCTAssertFalse(text.lowercased().contains("节点"), label)
    }

    func testGreenSummaryHasNoSecretsSubscriptionOrNodeList() {
        let state = DiagnosisClassifier.classify(proxiedHealthy())
        assertSanitized(state.summary, "green")
    }

    func testGraySummaryHasNoSecretsSubscriptionOrNodeList() {
        let state = DiagnosisClassifier.classify(NetworkSnapshot())
        assertSanitized(state.summary, "gray")
        assertSanitized(state.missingEvidenceExplanation, "gray explanation")
    }

    // MARK: - State mappings

    func testStateMappingsAreDistinct() {
        let states: [DiagnosisState] = [.green, .blue, .yellow, .red, .gray]
        XCTAssertEqual(Set(states.map(\.symbolName)).count, 5)
        XCTAssertEqual(Set(states.map(\.title)).count, 5)
        for s in states {
            XCTAssertFalse(s.symbolName.isEmpty)
            XCTAssertFalse(s.title.isEmpty)
        }
    }

    // MARK: - 8. Base-network layer matrix (PLAN §B/§C)

    func testInterfaceDownYieldsLocalNetworkConclusion() {
        var s = NetworkSnapshot()
        s.pathSatisfied = false
        XCTAssertEqual(DiagnosisClassifier.classify(s), .grayLocalNetwork)
    }

    func testPublicReachableButDnsFailsYieldsDnsConfigConclusion() {
        // Public IP reachable (no DNS dependency) but DNS fails → computer config
        // issue, classified as yellow (not gray, not green).
        var s = NetworkSnapshot()
        s.publicIPOutcomes = [.success, .success]
        s.dnsOutcome = .failure
        let state = DiagnosisClassifier.classify(s)
        XCTAssertEqual(state, .yellowDnsConfig)
        XCTAssertEqual(state.kind, .yellow)
        XCTAssertEqual(state.title, "电脑域名解析配置异常")
    }

    func testGatewayOkButBothPublicFailYieldsExternalConclusion() {
        var s = NetworkSnapshot()
        s.gatewayOutcome = .success
        s.publicIPOutcomes = [.failure, .timeout]
        XCTAssertEqual(DiagnosisClassifier.classify(s), .grayExternal)
    }

    func testDirectSuccessOverridesFailedFixedPublicIPTargets() {
        var s = NetworkSnapshot()
        s.directOutcomes = [.success]
        s.gatewayOutcome = .success
        s.publicIPOutcomes = [.failure, .timeout]
        XCTAssertEqual(DiagnosisClassifier.classify(s), .blue)
    }

    func testGatewayAndPublicBothFailYieldsLocalNetworkConclusion() {
        var s = NetworkSnapshot()
        s.gatewayOutcome = .failure
        s.publicIPOutcomes = [.failure, .timeout]
        XCTAssertEqual(DiagnosisClassifier.classify(s), .grayLocalNetwork)
    }

    func testWorkingProxyGreenWinsOverDnsConfig() {
        // A fully working verified proxy exit is the strongest signal; a
        // contradictory DNS-failure reading must not downgrade it to yellow.
        var s = proxiedHealthy()
        s.publicIPOutcomes = [.success, .success]
        s.dnsOutcome = .failure
        XCTAssertEqual(DiagnosisClassifier.classify(s), .green)
    }

    // MARK: - 9. Node anomaly conclusions

    func testCurrentNodeFailWithAlternateSuccessYieldsCurrentNode() {
        var s = NetworkSnapshot()
        s.clashActiveProxyOutcome = .failure
        s.alternateNodeOutcomes = [.success]
        XCTAssertEqual(DiagnosisClassifier.classify(s), .redCurrentNode)
    }

    func testCurrentAndBothAlternatesFailYieldsAirportSide() {
        var s = NetworkSnapshot()
        s.clashActiveProxyOutcome = .failure
        s.alternateNodeOutcomes = [.failure, .failure]
        s.directOutcomes = [.success]
        s.clashInfoAvailable = true
        s.clashVersionOutcome = .success
        s.clashConfigsOutcome = .success
        XCTAssertEqual(DiagnosisClassifier.classify(s), .redAirport)
    }

    // MARK: - 10. Near-misses must not false-positive

    func testTrafficObservedWithHealthyNodeYieldsGreenTrafficActive() {
        var s = NetworkSnapshot()
        s.clashTrafficObserved = true
        s.clashActiveProxyOutcome = .success
        s.clashVersionOutcome = .success
        s.clashConfigsOutcome = .success
        s.clashInfoAvailable = true
        XCTAssertEqual(DiagnosisClassifier.classify(s), .greenTrafficActive)
        XCTAssertEqual(DiagnosisClassifier.classify(s).kind, .green)
    }

    func testTrafficObservedWithoutHealthyNodeIsNotGreenTraffic() {
        var s = NetworkSnapshot()
        s.clashTrafficObserved = true
        s.clashActiveProxyOutcome = .failure
        s.clashVersionOutcome = .success
        s.clashConfigsOutcome = .success
        s.clashInfoAvailable = true
        XCTAssertNotEqual(DiagnosisClassifier.classify(s), .greenTrafficActive)
        XCTAssertNotEqual(DiagnosisClassifier.classify(s).kind, .red)
    }

    func testTrafficAbsentNilIsNotTreatedAsFailure() {
        var s = proxiedHealthy()
        s.clashTrafficObserved = nil
        XCTAssertEqual(DiagnosisClassifier.classify(s), .green, "missing traffic evidence must not block green")
        s.clashTrafficObserved = false
        XCTAssertEqual(DiagnosisClassifier.classify(s), .green, "traffic=false must not be a failure")
    }

    func testOneAlternateFailAloneDoesNotAttribute() {
        // A single failing alternate (fewer than two) and a failed current node:
        // not enough to say current-node or airport-side.
        var s = NetworkSnapshot()
        s.clashActiveProxyOutcome = .failure
        s.alternateNodeOutcomes = [.failure]
        let state = DiagnosisClassifier.classify(s)
        XCTAssertNotEqual(state, .redCurrentNode)
        XCTAssertNotEqual(state, .redAirport)
    }

    func testUnknownNodeDoesNotAttribute() {
        var s = redCandidate()
        s.clashActiveProxyOutcome = nil
        s.alternateNodeOutcomes = [.success, .failure]
        XCTAssertNotEqual(DiagnosisClassifier.classify(s), .redCurrentNode)
        XCTAssertNotEqual(DiagnosisClassifier.classify(s), .redAirport)
    }

    func testGatewayAloneFailDoesNotAttribute() {
        // Gateway failed but no public-IP evidence: cannot conclude local or
        // external network anomaly (needs at least two public-IP failures).
        var s = NetworkSnapshot()
        s.gatewayOutcome = .failure
        let state = DiagnosisClassifier.classify(s)
        XCTAssertNotEqual(state, .grayLocalNetwork)
        XCTAssertNotEqual(state, .grayExternal)
        XCTAssertEqual(state.kind, .gray) // falls back to unknown, not attributed
    }
}
