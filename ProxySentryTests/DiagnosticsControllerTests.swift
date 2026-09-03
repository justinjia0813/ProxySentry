import XCTest
@testable import ProxySentry

// MARK: - Minimal test primitives

/// A one-shot async gate: blocks until opened or the waiting task is cancelled.
/// Safe against the register/cancel race (exactly one resume per waiter).
final class Gate: @unchecked Sendable {
    private let lock = NSLock()
    private var pending: [UUID: CheckedContinuation<Void, Never>] = [:]
    private var isOpen = false

    func open() {
        lock.lock()
        isOpen = true
        let cs = Array(pending.values)
        pending.removeAll()
        lock.unlock()
        cs.forEach { $0.resume() }
    }

    func wait() async {
        lock.lock()
        let alreadyOpen = isOpen
        lock.unlock()
        if alreadyOpen { return }

        let id = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                self.lock.lock()
                if self.isOpen {
                    self.lock.unlock()
                    cont.resume()
                } else {
                    self.pending[id] = cont
                    let cancelled = Task.isCancelled
                    self.lock.unlock()
                    if cancelled {
                        self.reclaim(id, cont)
                    }
                }
            }
        } onCancel: {
            self.reclaim(id)
        }
    }

    /// Reclaim a waiter, resuming it only if we win the race with cancellation.
    private func reclaim(_ id: UUID) {
        lock.lock()
        let c = pending.removeValue(forKey: id)
        lock.unlock()
        c?.resume()
    }

    private func reclaim(_ id: UUID, _ cont: CheckedContinuation<Void, Never>) {
        lock.lock()
        let c = pending.removeValue(forKey: id)
        lock.unlock()
        if c != nil { cont.resume() }
    }
}

/// Thread-safe box for a value observed across tasks.
final class LockedBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: T
    init(_ value: T) { _value = value }
    var value: T { lock.lock(); defer { lock.unlock() }; return _value }
    func update(_ f: (inout T) -> Void) { lock.lock(); f(&_value); lock.unlock() }
}

/// Thread-safe collection of durations a sleep seam was asked to wait for.
final class DurationRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _values: [Duration] = []
    func append(_ d: Duration) { lock.lock(); _values.append(d); lock.unlock() }
    var all: [Duration] { lock.lock(); defer { lock.unlock() }; return _values }
}

final class DiagnosticsControllerTests: XCTestCase {

    // MARK: - StateDebouncer (pure)

    func testSingleAnomalyIsOnlyACandidate() {
        var d = StateDebouncer()
        XCTAssertNil(d.accept(.yellow))
        XCTAssertEqual(d.pendingKind, .yellow)
        XCTAssertNil(d.committedKind)
    }

    func testTwoConsecutiveIdenticalRoundsCommit() {
        var d = StateDebouncer()
        XCTAssertNil(d.accept(.yellow))
        XCTAssertEqual(d.accept(.yellow), .yellow)
        XCTAssertEqual(d.committedKind, .yellow)
        XCTAssertNil(d.pendingKind)
    }

    func testRecoveryCommitsAfterTwoConsecutiveRounds() {
        var d = StateDebouncer()
        XCTAssertNil(d.accept(.yellow))
        XCTAssertEqual(d.accept(.yellow), .yellow)
        XCTAssertNil(d.accept(.green), "a single recovery round must not commit yet")
        XCTAssertEqual(d.accept(.green), .green)
        XCTAssertEqual(d.committedKind, .green)
    }

    func testSameCommittedKindIsNotReNotified() {
        var d = StateDebouncer()
        XCTAssertNil(d.accept(.yellow))
        XCTAssertEqual(d.accept(.yellow), .yellow, "first confirmation notifies")
        XCTAssertNil(d.accept(.yellow), "a fresh single observation is only a candidate")
        XCTAssertNil(d.accept(.yellow), "re-confirming the committed kind must not re-notify")
        XCTAssertEqual(d.committedKind, .yellow)
    }

    func testSameCommittedStateDoesNotBecomeASecondRoundCandidate() {
        var d = StateDebouncer()
        XCTAssertNil(d.accept(.yellow))
        XCTAssertEqual(d.accept(.yellow), .yellow)
        XCTAssertNil(d.accept(.yellow))
        XCTAssertNil(d.pendingState)
        XCTAssertEqual(d.pendingCount, 0)
    }

    func testRecoveryToCommittedStateClearsTransientCandidate() {
        var d = StateDebouncer()
        XCTAssertNil(d.accept(.green))
        XCTAssertEqual(d.accept(.green), .green)
        XCTAssertNil(d.accept(.red))
        XCTAssertEqual(d.pendingKind, .red)

        XCTAssertNil(d.accept(.green))
        XCTAssertNil(d.pendingState)
        XCTAssertEqual(d.pendingCount, 0)
    }

    func testDifferentCausesWithSameKindNeedSeparateConfirmation() {
        var d = StateDebouncer()
        XCTAssertNil(d.accept(.redCurrentNode))
        XCTAssertNil(d.accept(.redAirport))
        XCTAssertEqual(d.accept(.redAirport), .redAirport)
    }

    func testPeerSampleBudgetDropsLateOptionalAttribution() async {
        let result = await AppDelegate.peerSampleWithinRoundBudget(
            wait: {},
            sample: {
                do { try await Task.sleep(for: .seconds(10)) } catch {}
                return .failure(.timeout)
            }
        )
        XCTAssertNil(result)
    }

    // MARK: - DiagnosticsController

    /// Wait until a condition holds, using XCTest's sanctioned predicate expectation.
    private func waitUntil(_ condition: @escaping () -> Bool) async {
        let exp = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in condition() },
            object: nil
        )
        await fulfillment(of: [exp], timeout: 3)
    }

    func testAnomalySchedulesTwoSecondRecheckAndCommits() async throws {
        let recorder = DurationRecorder()
        let gate = Gate()
        let started = LockedBox(0)

        let controller = DiagnosticsController(
            sleep: { d in
                recorder.append(d)
                if d == .seconds(2) { return }          // 2s recheck: advance instantly
                await gate.wait()                        // 8s budget: block (diagnose wins)
            },
            diagnose: {
                started.update { $0 += 1 }
                return .yellow
            }
        )
        controller.start()
        controller.trigger()

        await waitUntil { started.value == 2 && controller.committedKind == .yellow }

        XCTAssertEqual(controller.diagnoseCallCount, 2, "anomaly is rechecked once before committing")
        XCTAssertEqual(controller.recheckCount, 1)
        XCTAssertEqual(controller.committedKind, .yellow)
        XCTAssertTrue(recorder.all.contains(.seconds(2)), "anomaly schedules a 2s recheck")
        XCTAssertTrue(recorder.all.contains(.seconds(8)), "each round runs under an 8s budget")
        XCTAssertEqual(controller.maxConcurrentDiagnoses, 1)
    }

    func testTriggersCoalesceIntoAtMostOneFollowUp() async throws {
        let recorder = DurationRecorder()
        let releaseDiagnose = Gate()
        let budgetGate = Gate()
        let firstStarted = XCTestExpectation(description: "first diagnosis started")

        let controller = DiagnosticsController(
            sleep: { d in
                recorder.append(d)
                if d == .seconds(2) { return } // confirmation recheck: advance instantly
                await budgetGate.wait()        // 8s budget: block so diagnose wins
            },
            diagnose: {
                firstStarted.fulfill()
                await releaseDiagnose.wait()
                return .green
            }
        )
        controller.start()
        controller.trigger()
        await fulfillment(of: [firstStarted], timeout: 3)

        // Three more triggers arrive while run 1 is in flight.
        controller.trigger()
        controller.trigger()
        controller.trigger()

        releaseDiagnose.open()
        // The initial candidate is confirmed once; the stable committed state in
        // the coalesced follow-up does not schedule another confirmation.
        await waitUntil { controller.diagnoseCallCount == 3 }
        try await Task.sleep(for: .milliseconds(50))

        XCTAssertEqual(controller.diagnoseCallCount, 3,
                       "three mid-run triggers coalesce into exactly one follow-up runRound")
        XCTAssertEqual(controller.maxConcurrentDiagnoses, 1,
                       "never more than one diagnosis in flight")
        XCTAssertEqual(controller.committedKind, .green)
    }

    func testHealthyBootCommitsGreenAfterTwoRounds() async throws {
        let recorder = DurationRecorder()
        let budgetGate = Gate()
        let started = LockedBox(0)

        let controller = DiagnosticsController(
            sleep: { d in
                recorder.append(d)
                if d == .seconds(2) { return }
                await budgetGate.wait()
            },
            diagnose: {
                started.update { $0 += 1 }
                return .green
            }
        )
        controller.start()
        controller.trigger()

        // A single green is only a candidate; the confirmation recheck must see a
        // second consecutive green before the healthy boot commits.
        await waitUntil { started.value == 2 && controller.committedKind == .green }

        XCTAssertEqual(controller.diagnoseCallCount, 2, "healthy boot needs two rounds to commit green")
        XCTAssertEqual(controller.committedKind, .green)
        XCTAssertTrue(recorder.all.contains(.seconds(2)), "initial green schedules a confirmation recheck")
        XCTAssertTrue(recorder.all.contains(.seconds(8)), "each round runs under the 8s budget")
        XCTAssertEqual(controller.maxConcurrentDiagnoses, 1)
    }

    func testRecoveryFromRedCommitsGreenAfterTwoRounds() async throws {
        let recorder = DurationRecorder()
        let budgetGate = Gate()
        let callIndex = LockedBox(0)

        let controller = DiagnosticsController(
            sleep: { d in
                recorder.append(d)
                if d == .seconds(2) { return }
                await budgetGate.wait()
            },
            diagnose: {
                let seq: [DiagnosisState.Kind] = [.red, .red, .green, .green]
                var i = 0
                callIndex.update { c in
                    i = c
                    c += 1
                }
                return seq[i]
            }
        )
        controller.start()
        controller.trigger()

        // First two rounds confirm and commit red.
        await waitUntil { controller.committedKind == .red }
        XCTAssertEqual(controller.committedKind, .red)

        // A fresh trigger begins recovery: the first green is only a candidate and
        // the second consecutive green confirms and commits the recovery.
        controller.trigger()
        await waitUntil { controller.committedKind == .green }

        XCTAssertEqual(controller.committedKind, .green)
        XCTAssertEqual(controller.diagnoseCallCount, 4,
                       "two rounds commit red, two rounds commit the recovery to green")
    }

    func testBudgetWinCancelsInFlightDiagnosisWhichObservesCancellation() async throws {
        let recorder = DurationRecorder()
        let observedCancellation = LockedBox(false)

        let controller = DiagnosticsController(
            sleep: { d in
                recorder.append(d)
            }, // budget advances instantly, so the budget always wins
            diagnose: {
                await Gate().wait() // released only when the budget cancels the task
                observedCancellation.update { $0 = Task.isCancelled }
                return .yellow
            }
        )
        controller.start()
        controller.trigger()

        // The invariant: a probe that honors cancellation observes it when the
        // budget wins, so the budget can actually terminate the round.
        await waitUntil { observedCancellation.value }

        XCTAssertTrue(observedCancellation.value,
                      "diagnose must observe Task.isCancelled when the budget wins")
        XCTAssertEqual(controller.diagnoseCallCount, 1)
        XCTAssertNil(controller.committedKind, "budget timeout must not commit a late value")
        XCTAssertEqual(controller.maxConcurrentDiagnoses, 1)
    }

    func testEightSecondBudgetCancelsUnfinishedProbesWithoutCommit() async throws {
        let recorder = DurationRecorder()
        let cancelled = XCTestExpectation(description: "diagnosis cancelled by budget")
        let started = LockedBox(false)

        let controller = DiagnosticsController(
            sleep: { d in recorder.append(d) }, // budget advances instantly
            diagnose: {
                started.update { $0 = true }
                await Gate().wait()              // block; only cancellation releases it
                if Task.isCancelled { cancelled.fulfill() }
                return .yellow
            }
        )
        controller.start()
        controller.trigger()

        await fulfillment(of: [cancelled], timeout: 3)
        try await Task.sleep(for: .milliseconds(50))

        XCTAssertTrue(recorder.all.contains(.seconds(8)), "budget requested via the sleep seam")
        XCTAssertEqual(controller.diagnoseCallCount, 1)
        XCTAssertEqual(controller.maxConcurrentDiagnoses, 1)
        XCTAssertNil(controller.committedKind, "budget timeout must not commit a late result")
    }

    func testStopCancelsInFlightRunAndCommitsNoLateResult() async throws {
        let recorder = DurationRecorder()
        let cancelled = XCTestExpectation(description: "diagnosis cancelled by stop")
        let started = XCTestExpectation(description: "first diagnosis started")

        let controller = DiagnosticsController(
            sleep: { d in
                recorder.append(d)
                await Gate().wait()
            },
            diagnose: {
                started.fulfill()
                await Gate().wait()
                if Task.isCancelled { cancelled.fulfill() }
                return .yellow
            }
        )
        controller.start()
        controller.trigger()
        await fulfillment(of: [started], timeout: 3)

        controller.stop()

        await fulfillment(of: [cancelled], timeout: 3)
        try await Task.sleep(for: .milliseconds(50))

        XCTAssertNil(controller.committedKind, "no late commit after cancellation")
        XCTAssertEqual(controller.activeDiagnoses, 0)
        XCTAssertTrue(recorder.all.contains(.seconds(8)))
    }
}

// MARK: - Round integration (task 6)

extension DiagnosticsControllerTests {

    private func probeOut(_ o: NetworkProbes.ProbeResult) -> NetworkProbes.ProbeOutput {
        NetworkProbes.ProbeOutput(outcome: o, failureCategory: nil, milliseconds: 0)
    }

    private func testClash(_ ok: Bool = true) -> DiagnosticsController.ClashRead {
        DiagnosticsController.ClashRead(
            versionOk: ok, configsOk: ok, infoAvailable: ok,
            localPortMatchesConfiguredProxy: ok,
            summary: DiagnosticsController.ClashSummary(version: "1.18.0", mode: "rule", selectedGroup: "GLOBAL", delay: 120))
    }

    private func pathUp() -> PathSnapshot {
        PathSnapshot(satisfied: true, interfaceType: "wifi", supportsDNS: true)
    }

    func testRoundPinsSystemSnapshotsBeforeProbing() async {
        let proxyCalls = LockedBox(0)
        let proxySource: @Sendable () -> ProxySnapshot = {
            proxyCalls.update { $0 += 1 }
            // First read is 7890; any re-read would return 9999 and must never be used.
            return proxyCalls.value == 1
                ? ProxySnapshot(httpProxy: FixedProxy(host: "127.0.0.1", port: 7890))
                : ProxySnapshot(httpProxy: FixedProxy(host: "127.0.0.1", port: 9999))
        }
        let usedProxy = LockedBox<FixedProxy?>(nil)

        _ = await DiagnosticsController.makeRound(
            pathSnapshot: { self.pathUp() },
            proxySnapshot: proxySource,
            dnsResolves: { _ in true },
            runDirect: { [self.probeOut(.success)] },
            runLocal: { fixed in usedProxy.update { $0 = fixed }; return self.probeOut(.success) },
            runProxy: { p in usedProxy.update { $0 = p }; return [self.probeOut(.success)] },
            readClash: { _ in self.testClash() }
        )

        XCTAssertEqual(proxyCalls.value, 1, "proxy snapshot is read exactly once and pinned")
        XCTAssertEqual(usedProxy.value?.port, 7890,
                       "round must use the pinned endpoint, never a mid-round re-read")
    }

    func testRoundRunsAllInjectedProbesConcurrently() async {
        let dnsCalls = LockedBox(0), directCalls = LockedBox(0)
        let localCalls = LockedBox(0), proxyCalls = LockedBox(0), clashCalls = LockedBox(0)

        _ = await DiagnosticsController.makeRound(
            pathSnapshot: { self.pathUp() },
            proxySnapshot: { ProxySnapshot(httpProxy: FixedProxy(host: "127.0.0.1", port: 7890)) },
            dnsResolves: { _ in dnsCalls.update { $0 += 1 }; return true },
            runDirect: { directCalls.update { $0 += 1 }; return [] },
            runLocal: { _ in localCalls.update { $0 += 1 }; return self.probeOut(.failure) },
            runProxy: { _ in proxyCalls.update { $0 += 1 }; return [] },
            readClash: { _ in clashCalls.update { $0 += 1 }; return self.testClash(false) }
        )

        XCTAssertEqual(dnsCalls.value, 1)
        XCTAssertEqual(directCalls.value, 1)
        XCTAssertEqual(localCalls.value, 1)
        XCTAssertEqual(proxyCalls.value, 1)
        XCTAssertEqual(clashCalls.value, 1)
    }

    func testRoundClashFailureDoesNotOverrideGreen() async {
        let round = await DiagnosticsController.makeRound(
            pathSnapshot: { self.pathUp() },
            proxySnapshot: { ProxySnapshot(httpProxy: FixedProxy(host: "127.0.0.1", port: 7890)) },
            dnsResolves: { _ in true },
            runDirect: { [self.probeOut(.failure)] },
            runLocal: { _ in self.probeOut(.failure) },
            runProxy: { _ in [self.probeOut(.success)] },
            readClash: { _ in self.testClash(false) } // Clash read failing
        )
        XCTAssertEqual(round.state.kind, .green, "Clash failure must not override proxy-success green")
    }

    func testRoundClashFailureDoesNotOverrideBlue() async {
        let round = await DiagnosticsController.makeRound(
            pathSnapshot: { self.pathUp() },
            proxySnapshot: { ProxySnapshot() }, // no proxy route
            dnsResolves: { _ in true },
            runDirect: { [self.probeOut(.success)] },
            runLocal: { _ in self.probeOut(.failure) },
            runProxy: { _ in [] },
            readClash: { _ in self.testClash(false) } // Clash read failing
        )
        XCTAssertEqual(round.state.kind, .blue, "Clash failure must not override direct-success blue")
    }

    func testRoundWithTunEnabledShowsHealthyNodeWithoutClaimingVerifiedRoute() async {
        var clash = self.testClash(true)
        clash.tunEnabled = true
        clash.activeProxyProbe = self.probeOut(.success)
        let round = await DiagnosticsController.makeRound(
            pathSnapshot: { self.pathUp() },
            proxySnapshot: { ProxySnapshot() },
            dnsResolves: { _ in false },
            runDirect: { [self.probeOut(.success)] },
            runLocal: { _ in self.probeOut(.unavailable) },
            runProxy: { _ in [] },
            readClash: { _ in clash }
        )
        XCTAssertEqual(round.state.kind, .gray)
        XCTAssertTrue(round.evidence.contains {
            $0.category == .node && $0.outcome == .success
        })
        XCTAssertFalse(round.evidence.contains { $0.category == .direct })
    }

    func testRoundWithTunEnabledDoesNotPromoteDirectTargetSuccess() async {
        var clash = self.testClash(true)
        clash.tunEnabled = true
        clash.activeProxyProbe = self.probeOut(.failure)
        let round = await DiagnosticsController.makeRound(
            pathSnapshot: { self.pathUp() },
            proxySnapshot: { ProxySnapshot() },
            dnsResolves: { _ in true },
            runDirect: { [self.probeOut(.success)] },
            runLocal: { _ in self.probeOut(.unavailable) },
            runProxy: { _ in [] },
            readClash: { _ in clash }
        )
        XCTAssertNotEqual(round.state.kind, .green)
        XCTAssertFalse(round.evidence.contains { $0.category == .direct })
        XCTAssertTrue(round.evidence.contains {
            $0.category == .node && $0.outcome == .failure
        })
    }

    func testRoundShowsHealthyNodeWithoutClaimingSystemProxyRoute() async {
        var clash = self.testClash(true)
        clash.activeProxyProbe = self.probeOut(.success)
        let round = await DiagnosticsController.makeRound(
            pathSnapshot: { self.pathUp() },
            proxySnapshot: { ProxySnapshot() },
            dnsResolves: { _ in true },
            runDirect: { [self.probeOut(.success)] },
            runLocal: { _ in self.probeOut(.unavailable) },
            runProxy: { _ in [] },
            readClash: { _ in clash }
        )
        XCTAssertEqual(round.state.kind, .blue)
        XCTAssertEqual(round.state.title, "代理节点正常，系统路由未确认")
        XCTAssertTrue(round.evidence.contains {
            $0.category == .node && $0.outcome == .success
        })
    }

    func testAutomaticProxyFlagWithoutFixedEndpointDoesNotBecomeLocalConfigFailure() async {
        var clash = self.testClash(true)
        clash.activeProxyProbe = self.probeOut(.success)
        let round = await DiagnosticsController.makeRound(
            pathSnapshot: { self.pathUp() },
            proxySnapshot: { ProxySnapshot(pacConfigured: true) },
            dnsResolves: { _ in true },
            runDirect: { [self.probeOut(.success)] },
            runLocal: { _ in self.probeOut(.unavailable) },
            runProxy: { _ in [] },
            readClash: { _ in clash }
        )

        XCTAssertEqual(round.state.kind, .blue)
        XCTAssertEqual(round.state.title, "代理节点正常，系统路由未确认")
    }

    func testRoundWithTunAndSystemProxyUsesFixedProxyProbeOnly() async {
        var clash = self.testClash(true)
        clash.tunEnabled = true
        clash.activeProxyProbe = self.probeOut(.failure)
        let round = await DiagnosticsController.makeRound(
            pathSnapshot: { self.pathUp() },
            proxySnapshot: { ProxySnapshot(httpProxy: FixedProxy(host: "127.0.0.1", port: 7890)) },
            dnsResolves: { _ in true },
            runDirect: { [self.probeOut(.success)] },
            runLocal: { _ in self.probeOut(.success) },
            runProxy: { _ in [self.probeOut(.success)] },
            readClash: { _ in clash }
        )
        XCTAssertEqual(round.state.kind, .green)
        XCTAssertFalse(round.evidence.contains { $0.category == .direct })
    }

    func testHealthyNodeAndFailingSystemProxyExitIsLocalConfigFailure() async {
        var clash = self.testClash(true)
        clash.activeProxyProbe = self.probeOut(.success)
        let round = await DiagnosticsController.makeRound(
            pathSnapshot: { self.pathUp() },
            proxySnapshot: { ProxySnapshot(httpProxy: FixedProxy(host: "127.0.0.1", port: 7890)) },
            dnsResolves: { _ in true },
            runDirect: { [self.probeOut(.success)] },
            runLocal: { _ in self.probeOut(.success) },
            runProxy: { _ in [self.probeOut(.failure), self.probeOut(.timeout)] },
            readClash: { _ in clash }
        )
        XCTAssertEqual(round.state.kind, .yellow)
        XCTAssertTrue(round.evidence.contains {
            $0.category == .node && $0.outcome == .success
        })
        XCTAssertTrue(round.evidence.contains {
            $0.category == .proxy && $0.outcome == .failure
        })
    }

    func testRoundGreenPriorityOverDirectFailure() async {
        let round = await DiagnosticsController.makeRound(
            pathSnapshot: { self.pathUp() },
            proxySnapshot: { ProxySnapshot(httpProxy: FixedProxy(host: "127.0.0.1", port: 7890)) },
            dnsResolves: { _ in true },
            runDirect: { [self.probeOut(.failure), self.probeOut(.timeout)] },
            runLocal: { _ in self.probeOut(.failure) },
            runProxy: { _ in [self.probeOut(.success)] },
            readClash: { _ in self.testClash(true) }
        )
        XCTAssertEqual(round.state.kind, .green, "proxy success must take priority over direct failure")
    }

    func testRoundRedThresholdRequiresFullConjunction() async {
        var unhealthyClash = self.testClash(true)
        unhealthyClash.activeProxyProbe = self.probeOut(.failure)
        let redRound = await DiagnosticsController.makeRound(
            pathSnapshot: { self.pathUp() },
            proxySnapshot: { ProxySnapshot(httpProxy: FixedProxy(host: "127.0.0.1", port: 7890)) },
            dnsResolves: { _ in true },
            runDirect: { [self.probeOut(.success)] },
            runLocal: { _ in self.probeOut(.success) },
            runProxy: { _ in [self.probeOut(.failure), self.probeOut(.failure)] },
            readClash: { _ in unhealthyClash }
        )
        XCTAssertEqual(redRound.state.kind, .red, "full red conjunction must classify red")

        // Near miss: only one proxy outcome → never red.
        let nearMiss = await DiagnosticsController.makeRound(
            pathSnapshot: { self.pathUp() },
            proxySnapshot: { ProxySnapshot(httpProxy: FixedProxy(host: "127.0.0.1", port: 7890)) },
            dnsResolves: { _ in true },
            runDirect: { [self.probeOut(.success)] },
            runLocal: { _ in self.probeOut(.success) },
            runProxy: { _ in [self.probeOut(.failure)] },
            readClash: { _ in unhealthyClash }
        )
        XCTAssertNotEqual(nearMiss.state.kind, .red, "single proxy outcome must not be red")
    }

    func testRoundEvidenceIsWhitelisted() async {
        let round = await DiagnosticsController.makeRound(
            pathSnapshot: { self.pathUp() },
            proxySnapshot: { ProxySnapshot(httpProxy: FixedProxy(host: "127.0.0.1", port: 7890)) },
            dnsResolves: { _ in true },
            runDirect: { [self.probeOut(.success), self.probeOut(.failure)] },
            runLocal: { _ in self.probeOut(.success) },
            runProxy: { _ in [self.probeOut(.success)] },
            readClash: { _ in self.testClash(true) }
        )

        let allowed: Set<ProbeEvidence.Category> = [.direct, .proxy, .node, .localPort, .clashVersion, .clashConfigs]
        XCTAssertFalse(round.evidence.isEmpty)
        for ev in round.evidence {
            XCTAssertTrue(allowed.contains(ev.category), "evidence category must be whitelisted")
            XCTAssertTrue([ProbeOutcome.success, .failure, .timeout, .unavailable].contains(ev.outcome))
        }
        XCTAssertEqual(round.clashSummary?.version, "1.18.0")
    }

    func testControllerPublishesCommittedStateEvidenceAndIsChecking() async throws {
        let budgetGate = Gate()
        let started = LockedBox(0)
        let controller = DiagnosticsController(
            sleep: { d in
                if d == .seconds(2) { return }
                await budgetGate.wait()
            },
            round: {
                started.update { $0 += 1 }
                return DiagnosticsController.DiagnosisRound(
                    state: .green,
                    evidence: [ProbeEvidence(category: .proxy, outcome: .success, milliseconds: 1, userVisibleDescription: "")],
                    clashSummary: DiagnosticsController.ClashSummary(version: "1.18.0", mode: "rule", selectedGroup: "GLOBAL", delay: 120))
            }
        )
        controller.start()
        controller.trigger()

        await waitUntil { started.value == 2 && controller.committedState == .green }

        XCTAssertEqual(controller.committedKind, .green)
        XCTAssertEqual(controller.committedState, .green)
        XCTAssertFalse(controller.isChecking)
        XCTAssertNotNil(controller.lastCheckedAt)
        XCTAssertEqual(controller.evidence.count, 1)
        XCTAssertEqual(controller.evidence.first?.category, .proxy)
        XCTAssertEqual(controller.clashSummary?.version, "1.18.0")
        XCTAssertEqual(controller.maxConcurrentDiagnoses, 1)
    }

    // MARK: - Base-network wiring (PLAN §B)

    func testRoundWiresBaseNetworkAndTrafficEvidence() async {
        var clash = self.testClash(true)
        clash.trafficObserved = true
        clash.activeProxyProbe = self.probeOut(.success)
        clash.alternateNodeProbes = [self.probeOut(.failure), self.probeOut(.success)]

        let round = await DiagnosticsController.makeRound(
            pathSnapshot: { PathSnapshot(satisfied: true, interfaceType: "wifi", supportsDNS: true) },
            proxySnapshot: { ProxySnapshot() },
            dnsResolves: { _ in true },
            runDirect: { [self.probeOut(.success)] },
            runLocal: { _ in self.probeOut(.unavailable) },
            runProxy: { _ in [] },
            readClash: { _ in clash },
            gatewayProbe: { self.probeOut(.success) },
            publicIPProbes: { [self.probeOut(.success), self.probeOut(.success)] }
        )

        XCTAssertTrue(round.evidence.contains { $0.category == .gateway && $0.outcome == .success })
        XCTAssertTrue(round.evidence.contains { $0.category == .publicIP })
        XCTAssertTrue(round.evidence.contains { $0.category == .clashTraffic && $0.outcome == .success })
        XCTAssertTrue(round.evidence.contains {
            $0.category == .alternateNode && $0.userVisibleDescription.contains("备选节点")
        })
        // Traffic observed + healthy node + healthy kernel → independent green.
        XCTAssertEqual(round.state, .greenTrafficActive)
        XCTAssertEqual(round.state.kind, .green)
    }

    func testRoundClassifiesExternalNetworkAnomaly() async {
        let round = await DiagnosticsController.makeRound(
            pathSnapshot: { PathSnapshot(satisfied: true, interfaceType: "wifi", supportsDNS: true) },
            proxySnapshot: { ProxySnapshot() },
            dnsResolves: { _ in true },
            runDirect: { [self.probeOut(.failure)] },
            runLocal: { _ in self.probeOut(.unavailable) },
            runProxy: { _ in [] },
            readClash: { _ in self.testClash(false) },
            gatewayProbe: { self.probeOut(.success) },
            publicIPProbes: { [self.probeOut(.failure), self.probeOut(.timeout)] }
        )
        XCTAssertEqual(round.state, .grayExternal)
        XCTAssertEqual(round.state.kind, .gray)
    }

    func testRoundBaseDownWithClashTimeoutsStaysABaseNetworkFailure() async {
        var clash = testClash(true)
        clash.activeProxyProbe = probeOut(.timeout)
        clash.alternateNodeProbes = [probeOut(.timeout), probeOut(.timeout)]

        let round = await DiagnosticsController.makeRound(
            pathSnapshot: { PathSnapshot(satisfied: true, interfaceType: "wifi", supportsDNS: true) },
            proxySnapshot: { ProxySnapshot(httpProxy: FixedProxy(host: "127.0.0.1", port: 7890)) },
            dnsResolves: { _ in false },
            runDirect: { [self.probeOut(.failure), self.probeOut(.timeout)] },
            runLocal: { _ in self.probeOut(.success) },
            runProxy: { _ in [self.probeOut(.timeout), self.probeOut(.timeout)] },
            readClash: { _ in clash },
            gatewayProbe: { self.probeOut(.failure) },
            publicIPProbes: { [self.probeOut(.failure), self.probeOut(.timeout)] }
        )

        XCTAssertEqual(round.state, .grayLocalNetwork)
        XCTAssertNotEqual(round.state.kind, .red)
    }

    func testRoundDnsConfigConclusionIsYellow() async {
        let round = await DiagnosticsController.makeRound(
            pathSnapshot: { PathSnapshot(satisfied: true, interfaceType: "wifi", supportsDNS: true) },
            proxySnapshot: { ProxySnapshot() },
            dnsResolves: { _ in false }, // DNS fails
            runDirect: { [self.probeOut(.failure)] },
            runLocal: { _ in self.probeOut(.unavailable) },
            runProxy: { _ in [] },
            readClash: { _ in self.testClash(false) },
            gatewayProbe: { self.probeOut(.unavailable) },
            publicIPProbes: { [self.probeOut(.success), self.probeOut(.success)] }
        )
        XCTAssertEqual(round.state.kind, .yellow)
        XCTAssertEqual(round.state, .yellowDnsConfig)
        XCTAssertTrue(round.evidence.contains { $0.category == .dns && $0.outcome == .failure })
    }
}
