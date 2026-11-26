import AppKit
import XCTest
@testable import NoPeek
@testable import NoPeekCore

/// Records what the session asks the engine to do.
@MainActor
private final class SpyDelegate: LockSessionDelegate {
    var captureRequests: [Int] = []
    var authenticated = 0

    func sessionDidAuthenticate(_ session: LockSession) { authenticated += 1 }
    func sessionRequestsCapture(_ session: LockSession, attempt: Int) { captureRequests.append(attempt) }
}

@MainActor
final class LockSessionTests: XCTestCase {
    /// Same as the user's settings: photo after 2 wrong tries within 40s.
    private let userConfig = CatchConfig(isEnabled: true, attemptsBeforeCapture: 2, attemptWindowSeconds: 40,
                                         ownerGraceSeconds: 20, cooldownSeconds: 60, maxCapturesPerSession: 5)

    private func makeSession(config: CatchConfig? = nil, unlock: UnlockConfig = UnlockConfig(),
                             secret: String? = nil) -> (LockSession, SpyDelegate) {
        let app = ProtectedApp(bundleID: "com.example.test", name: "Test", unlock: unlock)
        let digest = secret.flatMap { try? SecretHasher.makeDigest(for: $0) }
        let session = LockSession(app: app, theme: .peekaboo, ownerName: "Ameya",
                                  catchConfig: config ?? userConfig, digest: digest)
        let spy = SpyDelegate()
        session.delegate = spy
        return (session, spy)
    }

    private func wait(_ seconds: TimeInterval) async {
        try? await Task.sleep(for: .seconds(seconds))
    }

    private func key(_ chars: String, keyCode: UInt16 = 0, modifiers: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0, windowNumber: 0,
                         context: nil, characters: chars, charactersIgnoringModifiers: chars,
                         isARepeat: false, keyCode: keyCode)!
    }

    // MARK: Photo after N tries

    func testSecondClickRequestsPhotoWithUserSettings() async {
        let (session, spy) = makeSession()
        session.handleClick()
        XCTAssertEqual(session.attempts, 1)
        XCTAssertEqual(session.capturesLeft, 1, "warns: one more try before the photo")
        XCTAssertTrue(spy.captureRequests.isEmpty)

        await wait(LockSession.clickDebounce + 0.1)
        session.handleClick()
        XCTAssertEqual(spy.captureRequests, [2], "2nd wrong try must request a photo")
        XCTAssertEqual(session.phase, .capturing)
    }

    func testRapidClicksCountOnce() async {
        let (session, spy) = makeSession()
        for _ in 0..<5 { session.handleClick() }
        XCTAssertEqual(session.attempts, 1, "a burst of clicks is one try")
        XCTAssertTrue(spy.captureRequests.isEmpty)
    }

    func testTypingBurstCountsAsOneTryAfterPause() async {
        let (session, spy) = makeSession()
        for c in "hello" { session.handleKey(key(String(c))) }
        XCTAssertEqual(session.attempts, 0, "not counted while still typing")
        await wait(LockSession.keyBurstGap + 0.3)
        XCTAssertEqual(session.attempts, 1)
        XCTAssertTrue(spy.captureRequests.isEmpty)
    }

    func testClickThenTypingTriggersPhoto() async {
        let (session, spy) = makeSession()
        session.handleClick()
        session.handleKey(key("x"))
        await wait(LockSession.keyBurstGap + 0.3)
        XCTAssertEqual(spy.captureRequests, [2])
    }

    func testCaughtStateAfterPhoto() async {
        let (session, _) = makeSession()
        session.handleClick()
        await wait(LockSession.clickDebounce + 0.1)
        session.handleClick()
        let record = CaptureRecord(date: Date(), bundleID: "com.example.test", appName: "Test", attempt: 2, fileName: "x.jpg")
        session.showCaught(image: nil, record: record)
        XCTAssertEqual(session.phase, .caught)
        XCTAssertTrue(session.hasCaught)
        XCTAssertEqual(session.captures.map(\.id), [record.id])
    }

    func testCooldownBlocksSecondPhoto() async {
        let (session, spy) = makeSession()
        for _ in 0..<4 {
            session.handleClick()
            await wait(LockSession.clickDebounce + 0.05)
        }
        XCTAssertEqual(spy.captureRequests, [2], "60s cooldown: only one photo")
    }

    func testCatchDisabledNeverRequestsPhoto() async {
        var config = userConfig
        config.isEnabled = false
        let (session, spy) = makeSession(config: config)
        for _ in 0..<3 {
            session.handleClick()
            await wait(LockSession.clickDebounce + 0.05)
        }
        XCTAssertEqual(session.attempts, 3)
        XCTAssertTrue(spy.captureRequests.isEmpty)
    }

    // MARK: Owner gets in without being counted

    func testSecretWordUnlocksWithoutCountingATry() async {
        let (session, spy) = makeSession(unlock: UnlockConfig(hasSecretWord: true), secret: "jj")
        session.handleKey(key("j"))
        session.handleKey(key("j"))
        XCTAssertEqual(spy.authenticated, 1)
        await wait(LockSession.keyBurstGap + 0.3)
        XCTAssertEqual(session.attempts, 0, "typing the right word is never a wrong try")
    }

    func testHotkeyUnlocks() {
        let hotkey = KeyShortcut(keyCode: 45, modifiers: [.control], keyLabel: "N")
        let (session, spy) = makeSession(unlock: UnlockConfig(hotkey: hotkey))
        session.handleKey(key("n", keyCode: 45, modifiers: [.control]))
        XCTAssertEqual(spy.authenticated, 1)
        XCTAssertEqual(session.attempts, 0)
    }

    func testFinishedSessionIgnoresInput() async {
        let (session, spy) = makeSession()
        session.finish(discardedPhoto: false)
        session.handleClick()
        XCTAssertEqual(session.attempts, 0)
        XCTAssertTrue(spy.captureRequests.isEmpty)
    }
}
