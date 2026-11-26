import AppKit
import XCTest
@testable import NoPeek

/// Quitting while an app is locked runs `NSApp.terminate` from inside a main-actor task (after Touch ID).
/// AppKit then waits for the `.terminateLater` reply in a nested run loop, so the reply must be able to fire
/// there. These tests recreate that nested loop from inside a main-actor task.
@MainActor
final class QuitRunLoopTests: XCTestCase {
    override func setUp() async throws {
        // Like the app: NSApplication registers the modal-panel mode (used while waiting for the
        // `.terminateLater` reply) as a common mode. Without it the nested loop below isn't realistic.
        _ = NSApplication.shared
    }

    /// Spins the main run loop in AppKit's terminate-wait mode until `done()` or the timeout.
    private func spinNestedLoop(timeout: TimeInterval, until done: () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while !done(), Date() < deadline {
            _ = RunLoop.current.run(mode: .modalPanel, before: Date().addingTimeInterval(0.01))
        }
    }

    func testRunLoopTimerFiresInsideNestedLoopStartedFromATask() async {
        var firedInsideLoop = false
        await Task { @MainActor in
            var fired = false
            onMainRunLoop(after: 0.05) { fired = true }
            spinNestedLoop(timeout: 2) { fired }
            firedInsideLoop = fired   // checked before this task returns, so it can't fire "late"
        }.value
        XCTAssertTrue(firedInsideLoop, "the quit reply must be able to fire while terminate's nested loop runs")
    }

    /// Documents the bug: a main-actor task can't start while the task that spun the loop is still running.
    func testTaskBasedAfterCannotFireInsideThatLoop() async {
        var fired = false
        await Task { @MainActor in
            let pending = after(0.05) { fired = true }
            spinNestedLoop(timeout: 0.5) { fired }
            XCTAssertFalse(fired, "after() is a task, so it waits for this task to return")
            pending.cancel()
        }.value
    }
}
