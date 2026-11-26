import AppKit
import Carbon.HIToolbox
import NoPeekCore
import os

let log = Logger(subsystem: "com.ameyajain.nopeek", category: "app")

// MARK: - Paths

enum AppPaths {
    static let supportDirectory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("NoPeek", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }()

    static let capturesDirectory: URL = {
        let dir = supportDirectory.appendingPathComponent("Captures", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    static var settingsFile: URL { supportDirectory.appendingPathComponent("settings.json") }
    static var secretsFile: URL { supportDirectory.appendingPathComponent("secrets.json") }
    static var captureIndexFile: URL { capturesDirectory.appendingPathComponent("index.json") }
}

enum JSONCoding {
    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    static func write<T: Encodable>(_ value: T, to url: URL, privateFile: Bool = false) {
        do {
            let data = try encoder.encode(value)
            try data.write(to: url, options: .atomic)
            if privateFile {
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            }
        } catch {
            log.error("Failed writing \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }
}

// MARK: - Main-actor delays

@MainActor
@discardableResult
func after(_ seconds: TimeInterval, _ work: @escaping @MainActor () -> Void) -> Task<Void, Never> {
    Task { @MainActor in
        try? await Task.sleep(for: .seconds(seconds))
        guard !Task.isCancelled else { return }
        work()
    }
}

/// Runs `work` on the main thread from a plain run-loop timer in `.common` modes, not as a Swift task.
/// Use it for anything that must run while AppKit spins a nested run loop (e.g. after `.terminateLater`)
/// from inside a main-actor task: a new main-actor task can't start until that task returns, so
/// `after()` would never fire there.
func onMainRunLoop(after seconds: TimeInterval = 0, _ work: @escaping @MainActor () -> Void) {
    let timer = Timer(timeInterval: max(0, seconds), repeats: false) { _ in
        MainActor.assumeIsolated { work() }
    }
    RunLoop.main.add(timer, forMode: .common)
}

/// Last-resort exit that never needs the main thread, so it still fires if the main thread is stuck.
func armHardExit(after seconds: TimeInterval) {
    DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + seconds) { _exit(0) }
}

// MARK: - Idle time

enum IdleMonitor {
    /// Seconds since the last keyboard/mouse/trackpad input anywhere in the session.
    static func secondsSinceLastInput() -> TimeInterval {
        guard let anyInput = CGEventType(rawValue: ~0) else { return 0 }
        return CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: anyInput)
    }
}

// MARK: - Keys

extension ModifierKeys {
    init(_ flags: NSEvent.ModifierFlags) {
        var m: ModifierKeys = []
        if flags.contains(.control) { m.insert(.control) }
        if flags.contains(.option) { m.insert(.option) }
        if flags.contains(.shift) { m.insert(.shift) }
        if flags.contains(.command) { m.insert(.command) }
        self = m
    }

    var carbonFlags: UInt32 {
        var f: UInt32 = 0
        if contains(.control) { f |= UInt32(controlKey) }
        if contains(.option) { f |= UInt32(optionKey) }
        if contains(.shift) { f |= UInt32(shiftKey) }
        if contains(.command) { f |= UInt32(cmdKey) }
        return f
    }
}

enum KeyLabel {
    private static let special: [Int: String] = [
        kVK_Space: "Space", kVK_Return: "↩", kVK_Tab: "⇥", kVK_Delete: "⌫", kVK_ForwardDelete: "⌦",
        kVK_Escape: "⎋", kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
        kVK_Home: "↖", kVK_End: "↘", kVK_PageUp: "⇞", kVK_PageDown: "⇟",
    ]

    private static let functionKeys: [Int: String] = [
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
        kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
        kVK_F13: "F13", kVK_F14: "F14", kVK_F15: "F15", kVK_F16: "F16", kVK_F17: "F17",
        kVK_F18: "F18", kVK_F19: "F19", kVK_F20: "F20",
    ]

    static func isFunctionKey(_ keyCode: UInt16) -> Bool {
        functionKeys[Int(keyCode)] != nil
    }

    static func label(for event: NSEvent) -> String {
        let code = Int(event.keyCode)
        if let name = special[code] ?? functionKeys[code] { return name }
        let chars = event.charactersIgnoringModifiers?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return chars.isEmpty ? "Key \(code)" : chars.uppercased()
    }
}

// MARK: - App icons

enum AppIcons {
    static func url(for bundleID: String) -> URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
    }

    private static let cache = NSCache<NSString, NSImage>()

    static func icon(for bundleID: String) -> NSImage {
        if let cached = cache.object(forKey: bundleID as NSString) { return cached }
        let image: NSImage
        if let url = url(for: bundleID) {
            image = NSWorkspace.shared.icon(forFile: url.path)
        } else {
            image = NSImage(systemSymbolName: "app.dashed", accessibilityDescription: nil) ?? NSImage()
        }
        cache.setObject(image, forKey: bundleID as NSString)
        return image
    }
}

// MARK: - Durations

enum DurationText {
    static func short(_ seconds: Int) -> String {
        if seconds <= 0 { return "Immediately" }
        if seconds < 60 { return "\(seconds)s" }
        if seconds % 3600 == 0 { return "\(seconds / 3600)h" }
        if seconds % 60 == 0 { return "\(seconds / 60) min" }
        return "\(seconds / 60)m \(seconds % 60)s"
    }
}
