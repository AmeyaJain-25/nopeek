import Foundation

// MARK: - Lenient decoding

extension KeyedDecodingContainer {
    /// Decodes a value if present and valid, otherwise falls back to a default.
    /// Lets older settings files keep loading as new fields are added.
    func value<T: Decodable>(_ key: Key, default fallback: @autoclosure () -> T) -> T {
        if let value = try? decodeIfPresent(T.self, forKey: key) {
            return value
        }
        return fallback()
    }
}

// MARK: - Shortcuts

public struct ModifierKeys: OptionSet, Codable, Hashable, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let control = ModifierKeys(rawValue: 1 << 0)
    public static let option = ModifierKeys(rawValue: 1 << 1)
    public static let shift = ModifierKeys(rawValue: 1 << 2)
    public static let command = ModifierKeys(rawValue: 1 << 3)

    /// Modifiers that make a key combo "intentional" (shift alone just types capitals).
    public static let chordModifiers: ModifierKeys = [.control, .option, .command]

    public var symbols: String {
        var out = ""
        if contains(.control) { out += "⌃" }
        if contains(.option) { out += "⌥" }
        if contains(.shift) { out += "⇧" }
        if contains(.command) { out += "⌘" }
        return out
    }
}

public struct KeyShortcut: Codable, Hashable, Sendable {
    public var keyCode: UInt16
    public var modifiers: ModifierKeys
    /// Human label captured at record time (e.g. "S", "Space", "F5").
    public var keyLabel: String

    public init(keyCode: UInt16, modifiers: ModifierKeys, keyLabel: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.keyLabel = keyLabel
    }

    public var displayString: String { modifiers.symbols + keyLabel }

    public func matches(keyCode: UInt16, modifiers: ModifierKeys) -> Bool {
        self.keyCode == keyCode && self.modifiers == modifiers
    }
}

// MARK: - Protected apps

public struct UnlockConfig: Codable, Hashable, Sendable {
    /// Secret key combo pressed on the overlay.
    public var hotkey: KeyShortcut?
    /// Whether a secret word is stored in the vault for this app.
    public var hasSecretWord: Bool
    /// Show a discreet Touch ID button on the overlay.
    public var touchID: Bool

    public init(hotkey: KeyShortcut? = nil, hasSecretWord: Bool = false, touchID: Bool = true) {
        self.hotkey = hotkey
        self.hasSecretWord = hasSecretWord
        self.touchID = touchID
    }

    public var hasAnyMethod: Bool { hotkey != nil || hasSecretWord || touchID }

    enum CodingKeys: String, CodingKey { case hotkey, hasSecretWord, touchID }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        hotkey = try? c.decodeIfPresent(KeyShortcut.self, forKey: .hotkey)
        hasSecretWord = c.value(.hasSecretWord, default: false)
        touchID = c.value(.touchID, default: true)
    }
}

public struct ProtectedApp: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var bundleID: String
    public var name: String
    public var isEnabled: Bool
    /// Lock after this many seconds with no keyboard/mouse input. nil = use the default; `LockDelay.never` = off.
    public var idleLockSeconds: Int?
    /// Lock this many seconds after you switch to another app. nil = use the default; `LockDelay.never` = off.
    public var switchAwayLockSeconds: Int?
    public var unlock: UnlockConfig

    public init(
        id: UUID = UUID(),
        bundleID: String,
        name: String,
        isEnabled: Bool = true,
        idleLockSeconds: Int? = nil,
        switchAwayLockSeconds: Int? = nil,
        unlock: UnlockConfig = UnlockConfig()
    ) {
        self.id = id
        self.bundleID = bundleID
        self.name = name
        self.isEnabled = isEnabled
        self.idleLockSeconds = idleLockSeconds
        self.switchAwayLockSeconds = switchAwayLockSeconds
        self.unlock = unlock
    }

    enum CodingKeys: String, CodingKey { case id, bundleID, name, isEnabled, idleLockSeconds, switchAwayLockSeconds, unlock }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.value(.id, default: UUID())
        bundleID = try c.decode(String.self, forKey: .bundleID)
        name = c.value(.name, default: bundleID)
        isEnabled = c.value(.isEnabled, default: true)
        let idle = try? c.decodeIfPresent(Int.self, forKey: .idleLockSeconds)
        if c.contains(.switchAwayLockSeconds) {
            idleLockSeconds = idle
            switchAwayLockSeconds = try? c.decodeIfPresent(Int.self, forKey: .switchAwayLockSeconds)
        } else if idle == LockDelay.immediately {
            // v1 "Immediately" meant: lock on switch-away, with a 1 min idle backstop.
            switchAwayLockSeconds = LockDelay.immediately
            idleLockSeconds = 60
        } else {
            idleLockSeconds = idle
            switchAwayLockSeconds = nil
        }
        unlock = c.value(.unlock, default: UnlockConfig())
    }
}

// MARK: - Lock timing

public enum LockDelay {
    /// Timer disabled.
    public static let never = -1
    /// Switch-away only: lock the moment another app takes over.
    public static let immediately = 0
    /// Shortest idle timeout allowed.
    public static let minimumIdleSeconds = 5
}

/// What decides when protected apps lock on their own.
public enum LockTrigger: String, Codable, CaseIterable, Sendable {
    /// Each app's own rules: lock after switching away and/or after no input (per-app overrides apply).
    case perApp
    /// One Mac-wide rule: everything locks together after the whole Mac has had no keyboard/mouse
    /// input for a while. Overrides every app's own switch-away and idle settings; switching apps never locks.
    case wholeMac

    public var displayName: String {
        switch self {
        case .perApp: return "Each app's own rules"
        case .wholeMac: return "Whole Mac inactivity"
        }
    }
}

// MARK: - Overlay themes

public enum OverlayThemeID: String, Codable, CaseIterable, Sendable {
    case googlyEyes
    case bouncer
    case peekaboo
    case shuffle

    public static var concrete: [OverlayThemeID] { [.peekaboo, .googlyEyes, .bouncer] }

    public var displayName: String {
        switch self {
        case .googlyEyes: return "👀 Googly Eyes"
        case .bouncer: return "🕶️ The Bouncer"
        case .peekaboo: return "🫣 Peekaboo (light)"
        case .shuffle: return "🎲 Shuffle"
        }
    }

    /// Light, frosted themes use dark text and a light blur.
    public var isLight: Bool { self == .peekaboo }

    /// Picks a concrete theme (shuffle → random).
    public func resolved<G: RandomNumberGenerator>(using generator: inout G) -> OverlayThemeID {
        self == .shuffle ? (Self.concrete.randomElement(using: &generator) ?? .googlyEyes) : self
    }

    public func resolved() -> OverlayThemeID {
        var g = SystemRandomNumberGenerator()
        return resolved(using: &g)
    }
}

// MARK: - Intruder catch

public struct CatchConfig: Codable, Hashable, Sendable {
    public var isEnabled: Bool
    /// Wrong tries needed (within the window) before a photo is taken.
    public var attemptsBeforeCapture: Int
    /// Tries older than this don't count towards the threshold.
    public var attemptWindowSeconds: Int
    /// A photo taken this close before an owner unlock is assumed to be the owner and deleted.
    public var ownerGraceSeconds: Int
    /// Minimum gap between two photos.
    public var cooldownSeconds: Int
    /// Hard cap of photos per lock session.
    public var maxCapturesPerSession: Int
    /// Photos older than this are purged.
    public var retentionDays: Int

    public init(
        isEnabled: Bool = true,
        attemptsBeforeCapture: Int = 3,
        attemptWindowSeconds: Int = 30,
        ownerGraceSeconds: Int = 20,
        cooldownSeconds: Int = 60,
        maxCapturesPerSession: Int = 5,
        retentionDays: Int = 30
    ) {
        self.isEnabled = isEnabled
        self.attemptsBeforeCapture = attemptsBeforeCapture
        self.attemptWindowSeconds = attemptWindowSeconds
        self.ownerGraceSeconds = ownerGraceSeconds
        self.cooldownSeconds = cooldownSeconds
        self.maxCapturesPerSession = maxCapturesPerSession
        self.retentionDays = retentionDays
    }

    enum CodingKeys: String, CodingKey {
        case isEnabled, attemptsBeforeCapture, attemptWindowSeconds, ownerGraceSeconds
        case cooldownSeconds, maxCapturesPerSession, retentionDays
    }

    public init(from decoder: Decoder) throws {
        let d = CatchConfig()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        isEnabled = c.value(.isEnabled, default: d.isEnabled)
        attemptsBeforeCapture = c.value(.attemptsBeforeCapture, default: d.attemptsBeforeCapture)
        attemptWindowSeconds = c.value(.attemptWindowSeconds, default: d.attemptWindowSeconds)
        ownerGraceSeconds = c.value(.ownerGraceSeconds, default: d.ownerGraceSeconds)
        cooldownSeconds = c.value(.cooldownSeconds, default: d.cooldownSeconds)
        maxCapturesPerSession = c.value(.maxCapturesPerSession, default: d.maxCapturesPerSession)
        retentionDays = c.value(.retentionDays, default: d.retentionDays)
    }
}

// MARK: - App settings

public struct AppSettings: Codable, Hashable, Sendable {
    public static let currentSchemaVersion = 1
    public static let slackBundleID = "com.tinyspeck.slackmacgap"

    public var schemaVersion: Int
    /// Shown to snoopers ("Reporting to Ameya…").
    public var ownerName: String
    /// Default "lock after no input" (seconds, or `LockDelay.never`).
    public var defaultIdleLockSeconds: Int
    /// Default "lock after switching away" (seconds, `LockDelay.immediately`, or `LockDelay.never`).
    public var defaultSwitchAwayLockSeconds: Int
    /// `.wholeMac` overrides every per-app timer with `macIdleLockSeconds`.
    public var lockTrigger: LockTrigger
    /// Seconds of Mac-wide inactivity before everything locks (used when `lockTrigger == .wholeMac`).
    public var macIdleLockSeconds: Int
    public var lockOnScreenLock: Bool
    /// Unlocking your Mac proves it's you, so protected apps unlock too.
    public var trustSystemUnlock: Bool
    /// Unlocking one protected app unlocks all of them.
    public var unlockAllTogether: Bool
    public var lockAllShortcut: KeyShortcut?
    public var theme: OverlayThemeID
    public var catchConfig: CatchConfig
    public var apps: [ProtectedApp]

    public init(
        ownerName: String = "Ameya",
        defaultIdleLockSeconds: Int = 60,
        defaultSwitchAwayLockSeconds: Int = LockDelay.never,
        lockTrigger: LockTrigger = .perApp,
        macIdleLockSeconds: Int = 300,
        lockOnScreenLock: Bool = true,
        trustSystemUnlock: Bool = true,
        unlockAllTogether: Bool = true,
        lockAllShortcut: KeyShortcut? = KeyShortcut(keyCode: 37, modifiers: [.control, .option], keyLabel: "L"),
        theme: OverlayThemeID = .peekaboo,
        catchConfig: CatchConfig = CatchConfig(),
        apps: [ProtectedApp] = [
            ProtectedApp(bundleID: AppSettings.slackBundleID, name: "Slack")
        ]
    ) {
        schemaVersion = Self.currentSchemaVersion
        self.ownerName = ownerName
        self.defaultIdleLockSeconds = defaultIdleLockSeconds
        self.defaultSwitchAwayLockSeconds = defaultSwitchAwayLockSeconds
        self.lockTrigger = lockTrigger
        self.macIdleLockSeconds = macIdleLockSeconds
        self.lockOnScreenLock = lockOnScreenLock
        self.trustSystemUnlock = trustSystemUnlock
        self.unlockAllTogether = unlockAllTogether
        self.lockAllShortcut = lockAllShortcut
        self.theme = theme
        self.catchConfig = catchConfig
        self.apps = apps
    }

    public static var `default`: AppSettings { AppSettings() }

    public var ownerDisplayName: String {
        let trimmed = ownerName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "the owner" : trimmed
    }

    /// Seconds of no input before the app locks, or nil if idle locking is off for it.
    /// In `.wholeMac` mode every app shares the Mac-wide timeout, so they all lock together.
    public func idleTimeout(for app: ProtectedApp) -> Int? {
        let value = lockTrigger == .wholeMac ? macIdleLockSeconds : (app.idleLockSeconds ?? defaultIdleLockSeconds)
        return value < 0 ? nil : max(LockDelay.minimumIdleSeconds, value)
    }

    /// Seconds after switching away before the app locks (0 = immediately), or nil if off.
    /// Always nil in `.wholeMac` mode: only inactivity of the whole Mac locks.
    public func switchAwayDelay(for app: ProtectedApp) -> Int? {
        guard lockTrigger == .perApp else { return nil }
        let value = app.switchAwayLockSeconds ?? defaultSwitchAwayLockSeconds
        return value < 0 ? nil : value
    }

    public func locksOnSwitchAway(_ app: ProtectedApp) -> Bool {
        switchAwayDelay(for: app) != nil
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion, ownerName, defaultIdleLockSeconds, defaultSwitchAwayLockSeconds, lockTrigger, macIdleLockSeconds
        case lockOnScreenLock, trustSystemUnlock
        case unlockAllTogether, lockAllShortcut, theme, catchConfig, apps
    }

    public init(from decoder: Decoder) throws {
        let d = AppSettings()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = c.value(.schemaVersion, default: Self.currentSchemaVersion)
        ownerName = c.value(.ownerName, default: d.ownerName)
        let idle = c.value(.defaultIdleLockSeconds, default: d.defaultIdleLockSeconds)
        if c.contains(.defaultSwitchAwayLockSeconds) {
            defaultIdleLockSeconds = idle
            defaultSwitchAwayLockSeconds = c.value(.defaultSwitchAwayLockSeconds, default: d.defaultSwitchAwayLockSeconds)
        } else if idle == LockDelay.immediately {
            // v1 "Immediately" default → switch-away immediately + 1 min idle.
            defaultIdleLockSeconds = 60
            defaultSwitchAwayLockSeconds = LockDelay.immediately
        } else {
            defaultIdleLockSeconds = idle
            defaultSwitchAwayLockSeconds = LockDelay.never
        }
        lockTrigger = c.value(.lockTrigger, default: d.lockTrigger)
        macIdleLockSeconds = c.value(.macIdleLockSeconds, default: d.macIdleLockSeconds)
        lockOnScreenLock = c.value(.lockOnScreenLock, default: d.lockOnScreenLock)
        trustSystemUnlock = c.value(.trustSystemUnlock, default: d.trustSystemUnlock)
        unlockAllTogether = c.value(.unlockAllTogether, default: d.unlockAllTogether)
        lockAllShortcut = c.contains(.lockAllShortcut)
            ? (try? c.decodeIfPresent(KeyShortcut.self, forKey: .lockAllShortcut))
            : d.lockAllShortcut
        theme = c.value(.theme, default: d.theme)
        catchConfig = c.value(.catchConfig, default: d.catchConfig)
        apps = c.value(.apps, default: d.apps)
    }
}

// MARK: - Captures

public struct CaptureRecord: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var date: Date
    public var bundleID: String
    public var appName: String
    /// Which wrong try triggered the photo.
    public var attempt: Int
    public var fileName: String

    public init(id: UUID = UUID(), date: Date, bundleID: String, appName: String, attempt: Int, fileName: String) {
        self.id = id
        self.date = date
        self.bundleID = bundleID
        self.appName = appName
        self.attempt = attempt
        self.fileName = fileName
    }
}
