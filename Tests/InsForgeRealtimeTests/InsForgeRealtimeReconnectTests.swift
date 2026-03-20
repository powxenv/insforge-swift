import XCTest
@testable import InsForgeRealtime

final class InsForgeRealtimeReconnectTests: XCTestCase {
    func testReconnectPolicyBaseDelayGrowsExponentiallyAndCaps() {
        let policy = ReconnectPolicy.default

        XCTAssertEqual(policy.baseDelay(forAttempt: 1), 1.0, accuracy: 0.0001)
        XCTAssertEqual(policy.baseDelay(forAttempt: 2), 2.0, accuracy: 0.0001)
        XCTAssertEqual(policy.baseDelay(forAttempt: 3), 4.0, accuracy: 0.0001)
        XCTAssertEqual(policy.baseDelay(forAttempt: 4), 8.0, accuracy: 0.0001)

        // Attempts after the cap should never exceed maxDelay (30s)
        XCTAssertEqual(policy.baseDelay(forAttempt: 6), 30.0, accuracy: 0.0001)
        XCTAssertEqual(policy.baseDelay(forAttempt: 9), 30.0, accuracy: 0.0001)
    }

    func testReconnectPolicyJitterStaysWithinExpectedBounds() {
        let policy = ReconnectPolicy.default
        let baseDelay: TimeInterval = 10

        // With ±20% jitter, bounds are [8.0, 12.0]
        XCTAssertEqual(policy.applyJitter(to: baseDelay, randomUnit: 0.0), 8.0, accuracy: 0.0001)
        XCTAssertEqual(policy.applyJitter(to: baseDelay, randomUnit: 0.5), 10.0, accuracy: 0.0001)
        XCTAssertEqual(policy.applyJitter(to: baseDelay, randomUnit: 1.0), 12.0, accuracy: 0.0001)
    }

    func testReconnectDecisionStopsAtMaxAttempts() {
        let policy = ReconnectPolicy.default
        var state = ReconnectRuntimeState()
        state.prepareForConnectionRequest(resetRetryAttempt: false)

        for attempt in 1...policy.maxAttempts {
            let decision = state.nextReconnectDecision(
                policy: policy,
                hasPendingReconnectTask: false,
                hasActiveConnectTask: false,
                isSocketConnected: false
            )

            switch decision {
            case .schedule(let currentAttempt, _):
                XCTAssertEqual(currentAttempt, attempt)
            default:
                XCTFail("Expected scheduled reconnect attempt \(attempt)")
            }
        }

        let exhaustedDecision = state.nextReconnectDecision(
            policy: policy,
            hasPendingReconnectTask: false,
            hasActiveConnectTask: false,
            isSocketConnected: false
        )

        XCTAssertEqual(exhaustedDecision, .maxedOut)
        XCTAssertFalse(state.shouldMaintainConnection)
    }

    func testReconnectDecisionBlockedWhenNetworkUnavailable() {
        let policy = ReconnectPolicy.default
        var state = ReconnectRuntimeState()
        state.prepareForConnectionRequest(resetRetryAttempt: false)
        _ = state.applyNetworkAvailability(.unavailable)

        let decision = state.nextReconnectDecision(
            policy: policy,
            hasPendingReconnectTask: false,
            hasActiveConnectTask: false,
            isSocketConnected: false
        )

        XCTAssertEqual(decision, .none)
    }

    func testReconnectDecisionAllowedWhenNetworkAvailabilityIsUnknown() {
        let policy = ReconnectPolicy.default
        var state = ReconnectRuntimeState()
        state.prepareForConnectionRequest(resetRetryAttempt: false)

        let decision = state.nextReconnectDecision(
            policy: policy,
            hasPendingReconnectTask: false,
            hasActiveConnectTask: false,
            isSocketConnected: false
        )

        if case .schedule(let attempt, let baseDelay) = decision {
            XCTAssertEqual(attempt, 1)
            XCTAssertEqual(baseDelay, 1.0, accuracy: 0.0001)
        } else {
            XCTFail("Expected reconnect to be scheduled when network availability is unknown")
        }
    }

    func testReconnectDecisionResumesAfterNetworkBecomesAvailable() {
        let policy = ReconnectPolicy.default
        var state = ReconnectRuntimeState()
        state.prepareForConnectionRequest(resetRetryAttempt: false)

        _ = state.applyNetworkAvailability(.unavailable)
        let blockedDecision = state.nextReconnectDecision(
            policy: policy,
            hasPendingReconnectTask: false,
            hasActiveConnectTask: false,
            isSocketConnected: false
        )
        XCTAssertEqual(blockedDecision, .none)

        let becameOnline = state.applyNetworkAvailability(.available)
        XCTAssertTrue(becameOnline.didChange)
        XCTAssertTrue(becameOnline.becameAvailableFromUnavailable)
        let resumedDecision = state.nextReconnectDecision(
            policy: policy,
            hasPendingReconnectTask: false,
            hasActiveConnectTask: false,
            isSocketConnected: false
        )

        if case .schedule(let attempt, let baseDelay) = resumedDecision {
            XCTAssertEqual(attempt, 1)
            XCTAssertEqual(baseDelay, 1.0, accuracy: 0.0001)
        } else {
            XCTFail("Expected reconnect to be scheduled when network is restored")
        }
    }

    func testManualDisconnectPreventsReconnect() {
        let policy = ReconnectPolicy.default
        var state = ReconnectRuntimeState()
        state.prepareForConnectionRequest(resetRetryAttempt: false)
        state.markManualDisconnect()

        let decision = state.nextReconnectDecision(
            policy: policy,
            hasPendingReconnectTask: false,
            hasActiveConnectTask: false,
            isSocketConnected: false
        )

        XCTAssertEqual(decision, .none)
        XCTAssertFalse(state.shouldMaintainConnection)
        XCTAssertTrue(state.isManuallyDisconnected)
    }

    func testSuccessfulConnectResetsRetryAttempt() {
        let policy = ReconnectPolicy.default
        var state = ReconnectRuntimeState()
        state.prepareForConnectionRequest(resetRetryAttempt: false)

        _ = state.nextReconnectDecision(
            policy: policy,
            hasPendingReconnectTask: false,
            hasActiveConnectTask: false,
            isSocketConnected: false
        )
        _ = state.nextReconnectDecision(
            policy: policy,
            hasPendingReconnectTask: false,
            hasActiveConnectTask: false,
            isSocketConnected: false
        )

        XCTAssertEqual(state.retryAttempt, 2)

        state.markConnectSucceeded()

        XCTAssertEqual(state.retryAttempt, 0)
        XCTAssertTrue(state.shouldMaintainConnection)
        XCTAssertFalse(state.isManuallyDisconnected)
    }

    func testReconnectDecisionIsSuppressedWhenReconnectTaskIsPending() {
        let policy = ReconnectPolicy.default
        var state = ReconnectRuntimeState()
        state.prepareForConnectionRequest(resetRetryAttempt: false)

        let decision = state.nextReconnectDecision(
            policy: policy,
            hasPendingReconnectTask: true,
            hasActiveConnectTask: false,
            isSocketConnected: false
        )

        XCTAssertEqual(decision, .none)
        XCTAssertEqual(state.retryAttempt, 0)
    }

    func testUnknownToAvailableTransitionDoesNotResetRetryAttempt() {
        let policy = ReconnectPolicy.default
        var state = ReconnectRuntimeState()
        state.prepareForConnectionRequest(resetRetryAttempt: false)

        _ = state.nextReconnectDecision(
            policy: policy,
            hasPendingReconnectTask: false,
            hasActiveConnectTask: false,
            isSocketConnected: false
        )
        _ = state.nextReconnectDecision(
            policy: policy,
            hasPendingReconnectTask: false,
            hasActiveConnectTask: false,
            isSocketConnected: false
        )

        XCTAssertEqual(state.retryAttempt, 2)

        let transition = state.applyNetworkAvailability(.available)
        XCTAssertTrue(transition.didChange)
        XCTAssertFalse(transition.becameAvailableFromUnavailable)
        XCTAssertEqual(state.retryAttempt, 2)
    }

    func testRetryAttemptResetsWhenNetworkIsRestored() {
        let policy = ReconnectPolicy.default
        var state = ReconnectRuntimeState()
        state.prepareForConnectionRequest(resetRetryAttempt: false)

        _ = state.nextReconnectDecision(
            policy: policy,
            hasPendingReconnectTask: false,
            hasActiveConnectTask: false,
            isSocketConnected: false
        )
        _ = state.nextReconnectDecision(
            policy: policy,
            hasPendingReconnectTask: false,
            hasActiveConnectTask: false,
            isSocketConnected: false
        )

        XCTAssertEqual(state.retryAttempt, 2)

        let becameOffline = state.applyNetworkAvailability(.unavailable)
        XCTAssertTrue(becameOffline.didChange)
        XCTAssertFalse(becameOffline.becameAvailableFromUnavailable)
        XCTAssertEqual(state.retryAttempt, 2)

        let becameOnline = state.applyNetworkAvailability(.available)
        XCTAssertTrue(becameOnline.didChange)
        XCTAssertTrue(becameOnline.becameAvailableFromUnavailable)
        XCTAssertEqual(state.retryAttempt, 0)

        let decision = state.nextReconnectDecision(
            policy: policy,
            hasPendingReconnectTask: false,
            hasActiveConnectTask: false,
            isSocketConnected: false
        )

        if case .schedule(let attempt, _) = decision {
            XCTAssertEqual(attempt, 1)
        } else {
            XCTFail("Expected reconnect attempt counter to restart after network recovery")
        }
    }

    func testPrepareForConnectionRequestWithResetStartsNewRetryCycle() {
        let policy = ReconnectPolicy.default
        var state = ReconnectRuntimeState()
        state.prepareForConnectionRequest(resetRetryAttempt: false)

        for _ in 1...policy.maxAttempts {
            _ = state.nextReconnectDecision(
                policy: policy,
                hasPendingReconnectTask: false,
                hasActiveConnectTask: false,
                isSocketConnected: false
            )
        }

        let exhaustedDecision = state.nextReconnectDecision(
            policy: policy,
            hasPendingReconnectTask: false,
            hasActiveConnectTask: false,
            isSocketConnected: false
        )
        XCTAssertEqual(exhaustedDecision, .maxedOut)

        state.prepareForConnectionRequest(resetRetryAttempt: true)

        let resumedDecision = state.nextReconnectDecision(
            policy: policy,
            hasPendingReconnectTask: false,
            hasActiveConnectTask: false,
            isSocketConnected: false
        )

        if case .schedule(let attempt, _) = resumedDecision {
            XCTAssertEqual(attempt, 1)
        } else {
            XCTFail("Expected retry cycle to restart after resetRetryAttempt=true")
        }
    }

    func testPrepareForConnectionRequestWithoutResetPreservesRetryBudget() {
        let policy = ReconnectPolicy.default
        var state = ReconnectRuntimeState()
        state.prepareForConnectionRequest(resetRetryAttempt: false)

        _ = state.nextReconnectDecision(
            policy: policy,
            hasPendingReconnectTask: false,
            hasActiveConnectTask: false,
            isSocketConnected: false
        )
        _ = state.nextReconnectDecision(
            policy: policy,
            hasPendingReconnectTask: false,
            hasActiveConnectTask: false,
            isSocketConnected: false
        )
        XCTAssertEqual(state.retryAttempt, 2)

        state.prepareForConnectionRequest(resetRetryAttempt: false)

        let nextDecision = state.nextReconnectDecision(
            policy: policy,
            hasPendingReconnectTask: false,
            hasActiveConnectTask: false,
            isSocketConnected: false
        )

        if case .schedule(let attempt, _) = nextDecision {
            XCTAssertEqual(attempt, 3)
        } else {
            XCTFail("Expected retry counter to continue when resetRetryAttempt=false")
        }
    }
}
