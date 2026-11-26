import AppKit
import Carbon.HIToolbox
import NoPeekCore

@MainActor
protocol LockSessionDelegate: AnyObject {
    func sessionDidAuthenticate(_ session: LockSession)
    func sessionRequestsCapture(_ session: LockSession, attempt: Int)
}

enum OverlayPhase: Equatable {
    case guarding
    case capturing
    case caught
    case unlocking(discardedPhoto: Bool)
}

/// One lock of one app: from the moment it locks until the owner gets back in.
/// Owns the input logic (secret word, hotkey, wrong-try counting) and the overlay's state.
@MainActor
final class LockSession: ObservableObject, Identifiable {
    /// A pause this long ends a typing burst; one burst = one wrong try.
    static let keyBurstGap: TimeInterval = 1.5
    /// Rapid clicks within this gap count as one try.
    static let clickDebounce: TimeInterval = 0.6
    static let caughtDisplaySeconds: TimeInterval = 6

    let id = UUID()
    let app: ProtectedApp
    let theme: OverlayThemeID
    let ownerName: String
    let isPreview: Bool
    let startedAt = Date()

    @Published private(set) var phase: OverlayPhase = .guarding
    @Published private(set) var attempts = 0
    @Published private(set) var capturesLeft: Int?
    @Published private(set) var hasCaught = false
    @Published private(set) var caughtImage: NSImage?
    @Published private(set) var caughtAt = Date()
    /// Bumps on every wrong try; views use it to trigger shake animations.
    @Published private(set) var pulse = 0
    @Published private(set) var flash = 0

    private(set) var captures: [CaptureRecord] = []
    private(set) var finishedAt: Date?
    var isFinished: Bool { finishedAt != nil }
    var bundleID: String { app.bundleID }

    weak var delegate: LockSessionDelegate?

    private var policy: IntruderPolicy
    private let digest: SecretDigest?
    private var keyBuffer = ""
    private var burstTask: Task<Void, Never>?
    private var caughtResetTask: Task<Void, Never>?
    private var lastClickAt = Date.distantPast
    private var touchIDInFlight = false

    init(app: ProtectedApp, theme: OverlayThemeID, ownerName: String, catchConfig: CatchConfig,
         digest: SecretDigest?, isPreview: Bool = false) {
        self.app = app
        self.theme = theme
        self.ownerName = ownerName
        self.digest = digest
        self.isPreview = isPreview
        policy = IntruderPolicy(config: catchConfig)
        capturesLeft = catchConfig.isEnabled ? max(1, catchConfig.attemptsBeforeCapture) : nil
    }

    var caption: String {
        OverlayCopy.caption(theme: theme, attempts: attempts, capturesLeft: capturesLeft, hasCaught: hasCaught,
                            isCapturing: phase == .capturing, appName: app.name, ownerName: ownerName)
    }

    // MARK: Input

    func handleKey(_ event: NSEvent) {
        guard !isFinished, event.type == .keyDown else { return }
        let modifiers = ModifierKeys(event.modifierFlags)

        if let hotkey = app.unlock.hotkey, hotkey.matches(keyCode: event.keyCode, modifiers: modifiers) {
            authenticate()
            return
        }

        if !event.isARepeat, modifiers.isDisjoint(with: [.command, .control]),
           let digest, let chars = event.characters {
            let printable = chars.filter { $0.isLetter || $0.isNumber || $0.isPunctuation || $0.isSymbol || $0 == " " }
            if !printable.isEmpty {
                keyBuffer += printable.lowercased()
                if keyBuffer.count > 64 { keyBuffer = String(keyBuffer.suffix(64)) }
                if SecretHasher.matchesSuffix(of: keyBuffer, digest: digest) {
                    authenticate()
                    return
                }
            }
        }

        guard !event.isARepeat else { return }
        // Don't count each key: wait for the typing burst to end, then count it once.
        burstTask?.cancel()
        burstTask = after(Self.keyBurstGap) { [weak self] in
            guard let self, !self.isFinished else { return }
            self.keyBuffer = ""
            self.registerAttempt(source: "typing")
        }
    }

    func handleClick() {
        guard !isFinished else { return }
        let now = Date()
        guard now.timeIntervalSince(lastClickAt) > Self.clickDebounce else { return }
        lastClickAt = now
        registerAttempt(source: "click")
    }

    func requestTouchID() {
        guard !isFinished, !touchIDInFlight else { return }
        touchIDInFlight = true
        Task { @MainActor in
            let ok = await OwnerAuth.verify(reason: "unlock \(app.name)")
            touchIDInFlight = false
            if ok { authenticate() } else { registerAttempt(source: "touchID") }
        }
    }

    // MARK: State changes driven by the engine

    func showCaught(image: NSImage?, record: CaptureRecord?) {
        guard !isFinished else { return }
        if let record { captures.append(record) }
        caughtImage = image
        caughtAt = record?.date ?? Date()
        hasCaught = true
        flash += 1
        phase = .caught
        caughtResetTask?.cancel()
        caughtResetTask = after(Self.caughtDisplaySeconds) { [weak self] in
            guard let self, self.phase == .caught else { return }
            self.phase = .guarding
        }
    }

    func captureFailed() {
        guard !isFinished, phase == .capturing else { return }
        phase = .guarding
    }

    func finish(discardedPhoto: Bool) {
        guard !isFinished else { return }
        finishedAt = Date()
        cancelTimers()
        phase = .unlocking(discardedPhoto: discardedPhoto)
    }

    func removeCaptures(ids: Set<UUID>) {
        captures.removeAll { ids.contains($0.id) }
    }

    func cancelTimers() {
        burstTask?.cancel()
        caughtResetTask?.cancel()
    }

    // MARK: Private

    private func authenticate() {
        keyBuffer = ""
        burstTask?.cancel()
        delegate?.sessionDidAuthenticate(self)
    }

    private func registerAttempt(source: String) {
        let decision = policy.registerAttempt(at: Date())
        if !isPreview {
            log.info("Wrong try #\(decision.attempt) on \(self.app.name, privacy: .public) via \(source, privacy: .public) → \(String(describing: decision), privacy: .public)")
        }
        attempts = decision.attempt
        pulse += 1
        switch decision {
        case let .counted(_, left):
            capturesLeft = left
        case let .capture(attempt):
            capturesLeft = nil
            phase = .capturing
            delegate?.sessionRequestsCapture(self, attempt: attempt)
        case .suppressed:
            capturesLeft = nil
        }
    }
}
