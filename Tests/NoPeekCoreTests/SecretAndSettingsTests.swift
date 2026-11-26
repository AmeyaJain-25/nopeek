import XCTest
@testable import NoPeekCore

final class SecretHasherTests: XCTestCase {
    func testDigestMatchesAndIsSalted() throws {
        let a = try SecretHasher.makeDigest(for: "jj")
        let b = try SecretHasher.makeDigest(for: "jj")
        XCTAssertNotEqual(a.hash, b.hash, "same secret must hash differently with different salts")
        XCTAssertTrue(SecretHasher.matches("jj", digest: a))
        XCTAssertTrue(SecretHasher.matches("JJ", digest: a), "matching is case-insensitive")
        XCTAssertFalse(SecretHasher.matches("jk", digest: a))
    }

    func testSuffixMatchingToleratesStrayKeys() throws {
        let digest = try SecretHasher.makeDigest(for: "open")
        XCTAssertTrue(SecretHasher.matchesSuffix(of: "asdfopen", digest: digest))
        XCTAssertTrue(SecretHasher.matchesSuffix(of: "open", digest: digest))
        XCTAssertFalse(SecretHasher.matchesSuffix(of: "openx", digest: digest))
        XCTAssertFalse(SecretHasher.matchesSuffix(of: "o", digest: digest))
    }

    func testValidation() {
        XCTAssertThrowsError(try SecretHasher.validate("j"))
        XCTAssertThrowsError(try SecretHasher.validate("   "))
        XCTAssertThrowsError(try SecretHasher.validate(String(repeating: "a", count: 33)))
        XCTAssertNoThrow(try SecretHasher.validate("jj"))
    }
}

final class SettingsCodingTests: XCTestCase {
    func testRoundTrip() throws {
        var settings = AppSettings.default
        settings.ownerName = "Ameya"
        settings.apps[0].unlock.hotkey = KeyShortcut(keyCode: 1, modifiers: [.control, .option], keyLabel: "S")
        let data = try JSONEncoder().encode(settings)
        XCTAssertEqual(try JSONDecoder().decode(AppSettings.self, from: data), settings)
    }

    func testMissingFieldsFallBackToDefaults() throws {
        let json = #"{"ownerName":"Sam","apps":[{"bundleID":"com.example.app"}]}"#
        let settings = try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))
        XCTAssertEqual(settings.ownerName, "Sam")
        XCTAssertEqual(settings.defaultIdleLockSeconds, 60)
        XCTAssertEqual(settings.catchConfig, CatchConfig())
        XCTAssertEqual(settings.apps.count, 1)
        XCTAssertEqual(settings.apps[0].name, "com.example.app")
        XCTAssertTrue(settings.apps[0].unlock.touchID)
        XCTAssertNotNil(settings.lockAllShortcut, "absent key keeps the default shortcut")
    }

    func testExplicitNullShortcutStaysCleared() throws {
        let json = #"{"lockAllShortcut":null}"#
        let settings = try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))
        XCTAssertNil(settings.lockAllShortcut)
    }

    func testIdleTimeoutOverrideAndFloor() {
        let settings = AppSettings(defaultIdleLockSeconds: 60)
        XCTAssertEqual(settings.idleTimeout(for: ProtectedApp(bundleID: "a", name: "A")), 60)
        XCTAssertEqual(settings.idleTimeout(for: ProtectedApp(bundleID: "a", name: "A", idleLockSeconds: 120)), 120,
                       "app setting overrides the default")
        XCTAssertEqual(settings.idleTimeout(for: ProtectedApp(bundleID: "a", name: "A", idleLockSeconds: 1)), 5)
        XCTAssertNil(settings.idleTimeout(for: ProtectedApp(bundleID: "a", name: "A", idleLockSeconds: LockDelay.never)))
        XCTAssertNil(AppSettings(defaultIdleLockSeconds: LockDelay.never).idleTimeout(for: ProtectedApp(bundleID: "a", name: "A")))
    }

    func testWholeMacModeOverridesPerAppRules() {
        var settings = AppSettings(defaultIdleLockSeconds: 60, defaultSwitchAwayLockSeconds: LockDelay.immediately,
                                   lockTrigger: .wholeMac, macIdleLockSeconds: 600)
        let custom = ProtectedApp(bundleID: "a", name: "A", idleLockSeconds: LockDelay.never, switchAwayLockSeconds: 30)
        let plain = ProtectedApp(bundleID: "b", name: "B")
        for app in [custom, plain] {
            XCTAssertEqual(settings.idleTimeout(for: app), 600, "every app shares the Mac-wide timeout")
            XCTAssertNil(settings.switchAwayDelay(for: app), "switching apps never locks in whole-Mac mode")
            XCTAssertFalse(settings.locksOnSwitchAway(app))
        }
        settings.macIdleLockSeconds = 1
        XCTAssertEqual(settings.idleTimeout(for: plain), LockDelay.minimumIdleSeconds)
        settings.macIdleLockSeconds = LockDelay.never
        XCTAssertNil(settings.idleTimeout(for: plain))

        // Switching back restores each app's own rules untouched.
        settings.lockTrigger = .perApp
        XCTAssertNil(settings.idleTimeout(for: custom))
        XCTAssertEqual(settings.switchAwayDelay(for: custom), 30)
        XCTAssertEqual(settings.switchAwayDelay(for: plain), LockDelay.immediately)
    }

    func testLockTriggerDecodingDefaultsToPerApp() throws {
        let old = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"defaultIdleLockSeconds":120}"#.utf8))
        XCTAssertEqual(old.lockTrigger, .perApp)
        XCTAssertEqual(old.macIdleLockSeconds, 300)
        let new = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"lockTrigger":"wholeMac","macIdleLockSeconds":900}"#.utf8))
        XCTAssertEqual(new.lockTrigger, .wholeMac)
        XCTAssertEqual(new.macIdleLockSeconds, 900)
    }

    func testSwitchAwayIsIndependentOfIdle() {
        let settings = AppSettings(defaultIdleLockSeconds: 300, defaultSwitchAwayLockSeconds: 30)
        let usesDefaults = ProtectedApp(bundleID: "a", name: "A")
        XCTAssertEqual(settings.switchAwayDelay(for: usesDefaults), 30)
        XCTAssertEqual(settings.idleTimeout(for: usesDefaults), 300)

        let own = ProtectedApp(bundleID: "a", name: "A", idleLockSeconds: 45, switchAwayLockSeconds: LockDelay.immediately)
        XCTAssertEqual(settings.switchAwayDelay(for: own), 0)
        XCTAssertEqual(settings.idleTimeout(for: own), 45)

        let off = ProtectedApp(bundleID: "a", name: "A", switchAwayLockSeconds: LockDelay.never)
        XCTAssertNil(settings.switchAwayDelay(for: off))
        XCTAssertFalse(settings.locksOnSwitchAway(off))
        XCTAssertFalse(AppSettings().locksOnSwitchAway(usesDefaults), "switch-away is off by default for new installs")
    }

    func testMigratesV1Immediately() throws {
        // v1: idleLockSeconds 0 meant "lock on switch-away, idle backstop 1 min".
        let json = #"{"defaultIdleLockSeconds":5,"apps":[{"bundleID":"com.slack","idleLockSeconds":0}]}"#
        let settings = try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))
        let app = settings.apps[0]
        XCTAssertEqual(settings.defaultIdleLockSeconds, 5)
        XCTAssertEqual(settings.defaultSwitchAwayLockSeconds, LockDelay.never)
        XCTAssertEqual(settings.switchAwayDelay(for: app), 0)
        XCTAssertEqual(settings.idleTimeout(for: app), 60)

        let v1Default = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"defaultIdleLockSeconds":0}"#.utf8))
        XCTAssertEqual(v1Default.defaultSwitchAwayLockSeconds, 0)
        XCTAssertEqual(v1Default.defaultIdleLockSeconds, 60)
    }

    func testCaptionEscalation() {
        func caption(_ attempts: Int, left: Int?, caught: Bool = false) -> String {
            OverlayCopy.caption(theme: .bouncer, attempts: attempts, capturesLeft: left, hasCaught: caught,
                                isCapturing: false, appName: "Slack", ownerName: "Ameya")
        }
        XCTAssertEqual(caption(0, left: 3), OverlayCopy.tagline(for: .bouncer))
        XCTAssertEqual(OverlayCopy.caption(theme: .peekaboo, attempts: 1, capturesLeft: 2, hasCaught: false, isCapturing: false, appName: "Slack", ownerName: "Ameya"), "Nothing to see here, promise.")
        XCTAssertEqual(caption(1, left: 2), "Nope.")
        XCTAssertTrue(caption(2, left: 1).contains("photo"), "warns before the photo is taken")
        XCTAssertTrue(caption(5, left: nil, caught: true).contains("Ameya"))
    }
}
