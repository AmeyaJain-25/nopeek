import XCTest
@testable import NoPeekCore

final class IntruderPolicyTests: XCTestCase {
    private let t0 = Date(timeIntervalSinceReferenceDate: 1_000_000)

    func testOwnerFumblingBelowThresholdIsNeverCaptured() {
        var policy = IntruderPolicy(config: CatchConfig(attemptsBeforeCapture: 3))
        XCTAssertEqual(policy.registerAttempt(at: t0), .counted(attempt: 1, capturesIn: 2))
        XCTAssertEqual(policy.registerAttempt(at: t0 + 1), .counted(attempt: 2, capturesIn: 1))
    }

    func testCaptureOnThreshold() {
        var policy = IntruderPolicy(config: CatchConfig(attemptsBeforeCapture: 3))
        _ = policy.registerAttempt(at: t0)
        _ = policy.registerAttempt(at: t0 + 1)
        XCTAssertEqual(policy.registerAttempt(at: t0 + 2), .capture(attempt: 3))
        XCTAssertEqual(policy.capturesThisSession, 1)
    }

    func testAttemptsOutsideWindowDoNotAccumulate() {
        var policy = IntruderPolicy(config: CatchConfig(attemptsBeforeCapture: 3, attemptWindowSeconds: 10))
        _ = policy.registerAttempt(at: t0)
        _ = policy.registerAttempt(at: t0 + 11)
        // First attempt expired, so this is only the 2nd inside the window.
        XCTAssertEqual(policy.registerAttempt(at: t0 + 12), .counted(attempt: 3, capturesIn: 1))
    }

    func testCooldownSuppressesThenAllows() {
        var policy = IntruderPolicy(config: CatchConfig(attemptsBeforeCapture: 1, cooldownSeconds: 60))
        XCTAssertEqual(policy.registerAttempt(at: t0), .capture(attempt: 1))
        XCTAssertEqual(policy.registerAttempt(at: t0 + 10), .suppressed(attempt: 2, reason: .cooldown))
        XCTAssertEqual(policy.registerAttempt(at: t0 + 61), .capture(attempt: 3))
    }

    func testSessionLimit() {
        var policy = IntruderPolicy(config: CatchConfig(attemptsBeforeCapture: 1, cooldownSeconds: 0, maxCapturesPerSession: 2))
        XCTAssertEqual(policy.registerAttempt(at: t0), .capture(attempt: 1))
        XCTAssertEqual(policy.registerAttempt(at: t0 + 1), .capture(attempt: 2))
        XCTAssertEqual(policy.registerAttempt(at: t0 + 2), .suppressed(attempt: 3, reason: .sessionLimit))
    }

    func testDisabledNeverCaptures() {
        var policy = IntruderPolicy(config: CatchConfig(isEnabled: false, attemptsBeforeCapture: 1))
        for i in 0..<10 {
            XCTAssertEqual(policy.registerAttempt(at: t0 + TimeInterval(i)), .counted(attempt: i + 1, capturesIn: nil))
        }
    }

    func testOwnerGrace() {
        XCTAssertTrue(OwnerGrace.shouldDiscard(captureDate: t0, unlockDate: t0 + 5, graceSeconds: 20))
        XCTAssertTrue(OwnerGrace.shouldDiscard(captureDate: t0, unlockDate: t0 + 20, graceSeconds: 20))
        XCTAssertFalse(OwnerGrace.shouldDiscard(captureDate: t0, unlockDate: t0 + 21, graceSeconds: 20))
        XCTAssertFalse(OwnerGrace.shouldDiscard(captureDate: t0 + 5, unlockDate: t0, graceSeconds: 20))

        let old = CaptureRecord(date: t0, bundleID: "a", appName: "A", attempt: 3, fileName: "1.jpg")
        let recent = CaptureRecord(date: t0 + 70, bundleID: "a", appName: "A", attempt: 6, fileName: "2.jpg")
        let discarded = OwnerGrace.recordsToDiscard([old, recent], unlockDate: t0 + 80, graceSeconds: 20)
        XCTAssertEqual(discarded, [recent])
    }
}
