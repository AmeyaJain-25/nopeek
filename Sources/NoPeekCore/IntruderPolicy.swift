import Foundation

public enum SuppressionReason: Equatable, Sendable {
    /// A photo was taken too recently.
    case cooldown
    /// This lock session already has the maximum number of photos.
    case sessionLimit
}

public enum AttemptDecision: Equatable, Sendable {
    /// Counted, no photo. `capturesIn` = wrong tries left before a photo (nil when catching is off).
    case counted(attempt: Int, capturesIn: Int?)
    /// Take a photo now.
    case capture(attempt: Int)
    /// Threshold reached but a photo isn't allowed right now.
    case suppressed(attempt: Int, reason: SuppressionReason)

    public var attempt: Int {
        switch self {
        case let .counted(attempt, _), let .capture(attempt), let .suppressed(attempt, _):
            return attempt
        }
    }
}

/// Decides when a wrong try should turn into a photo.
///
/// Designed so the owner fumbling once or twice never gets photographed:
/// a photo needs `attemptsBeforeCapture` wrong tries inside `attemptWindowSeconds`,
/// photos are rate limited by `cooldownSeconds` and capped per session.
public struct IntruderPolicy: Sendable {
    public let config: CatchConfig
    public private(set) var totalAttempts = 0
    public private(set) var capturesThisSession = 0
    private var recentAttempts: [Date] = []
    private var lastCaptureAt: Date?

    public init(config: CatchConfig) {
        self.config = config
    }

    public mutating func registerAttempt(at now: Date) -> AttemptDecision {
        totalAttempts += 1
        guard config.isEnabled else {
            return .counted(attempt: totalAttempts, capturesIn: nil)
        }

        let window = TimeInterval(max(1, config.attemptWindowSeconds))
        recentAttempts.removeAll { now.timeIntervalSince($0) > window }
        recentAttempts.append(now)

        let threshold = max(1, config.attemptsBeforeCapture)
        if recentAttempts.count < threshold {
            return .counted(attempt: totalAttempts, capturesIn: threshold - recentAttempts.count)
        }
        if capturesThisSession >= max(0, config.maxCapturesPerSession) {
            return .suppressed(attempt: totalAttempts, reason: .sessionLimit)
        }
        if let last = lastCaptureAt, now.timeIntervalSince(last) < TimeInterval(max(0, config.cooldownSeconds)) {
            return .suppressed(attempt: totalAttempts, reason: .cooldown)
        }

        lastCaptureAt = now
        capturesThisSession += 1
        recentAttempts.removeAll()
        return .capture(attempt: totalAttempts)
    }
}

/// "It was me" detection: photos taken shortly before the owner unlocks are discarded.
public enum OwnerGrace {
    public static func shouldDiscard(captureDate: Date, unlockDate: Date, graceSeconds: Int) -> Bool {
        let delta = unlockDate.timeIntervalSince(captureDate)
        return delta >= 0 && delta <= TimeInterval(max(0, graceSeconds))
    }

    public static func recordsToDiscard(
        _ records: [CaptureRecord],
        unlockDate: Date,
        graceSeconds: Int
    ) -> [CaptureRecord] {
        records.filter { shouldDiscard(captureDate: $0.date, unlockDate: unlockDate, graceSeconds: graceSeconds) }
    }
}
