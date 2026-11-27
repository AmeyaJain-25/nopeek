import AppKit
import AVFoundation
import Carbon.HIToolbox
import LocalAuthentication
import NoPeekCore
import UserNotifications

// MARK: - Owner authentication (Touch ID / password)

@MainActor
enum OwnerAuth {
    private static var inProgressCount = 0
    /// True while a Touch ID / password sheet is on screen.
    static var isInProgress: Bool { inProgressCount > 0 }
    /// Lets the shield step aside while the system auth sheet is shown.
    static var onProgressChange: ((Bool) -> Void)?

    /// Touch ID with password fallback. Returns false on cancel/failure.
    static func verify(reason: String) async -> Bool {
        inProgressCount += 1
        onProgressChange?(true)
        defer {
            inProgressCount -= 1
            onProgressChange?(isInProgress)
        }
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            log.error("Owner auth unavailable: \(error?.localizedDescription ?? "unknown", privacy: .public)")
            return false
        }
        do {
            return try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
        } catch {
            return false
        }
    }
}

// MARK: - Camera

enum CameraError: Error {
    case notAuthorized, noDevice, busy, captureFailed, timedOut
}

/// Grabs a single still from the default camera.
// All mutable state is confined to `queue`.
final class CameraCapture: NSObject, AVCapturePhotoCaptureDelegate, @unchecked Sendable {
    static var status: AVAuthorizationStatus { AVCaptureDevice.authorizationStatus(for: .video) }
    static var isAuthorized: Bool { status == .authorized }

    static func requestAccess() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .video)
    }

    private let queue = DispatchQueue(label: "io.github.ameyajain-25.nopeek.camera")
    private var session: AVCaptureSession?
    private var continuation: CheckedContinuation<Data, Error>?

    /// - Parameter warmUp: lets auto-exposure settle so the photo isn't black.
    func capturePhoto(warmUp: TimeInterval = 0.9) async throws -> Data {
        // Never prompt for permission at intrusion time: only shoot when already allowed.
        guard Self.isAuthorized else { throw CameraError.notAuthorized }

        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Error>) in
            queue.async { [self] in
                guard continuation == nil else {
                    cont.resume(throwing: CameraError.busy)
                    return
                }
                guard let device = AVCaptureDevice.default(for: .video),
                      let input = try? AVCaptureDeviceInput(device: device) else {
                    cont.resume(throwing: CameraError.noDevice)
                    return
                }
                let session = AVCaptureSession()
                session.sessionPreset = .photo
                let output = AVCapturePhotoOutput()
                guard session.canAddInput(input), session.canAddOutput(output) else {
                    cont.resume(throwing: CameraError.captureFailed)
                    return
                }
                session.addInput(input)
                session.addOutput(output)
                session.startRunning()
                self.session = session
                self.continuation = cont

                queue.asyncAfter(deadline: .now() + warmUp) {
                    output.capturePhoto(with: AVCapturePhotoSettings(), delegate: self)
                }
                queue.asyncAfter(deadline: .now() + warmUp + 5) { [weak self] in
                    self?.finish(with: .failure(CameraError.timedOut))
                }
            }
        }
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        let result: Result<Data, Error>
        if let data = photo.fileDataRepresentation(), error == nil {
            result = .success(data)
        } else {
            result = .failure(error ?? CameraError.captureFailed)
        }
        queue.async { [weak self] in self?.finish(with: result) }
    }

    /// Must run on `queue`.
    private func finish(with result: Result<Data, Error>) {
        guard let cont = continuation else { return }
        continuation = nil
        session?.stopRunning()
        session = nil
        cont.resume(with: result)
    }
}

// MARK: - Notifications

@MainActor
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    var onOpen: (() -> Void)?

    private var center: UNUserNotificationCenter? {
        // UNUserNotificationCenter crashes outside an .app bundle (e.g. `swift run`).
        Bundle.main.bundleIdentifier == nil ? nil : UNUserNotificationCenter.current()
    }

    func activate() {
        center?.delegate = self
    }

    @discardableResult
    func requestAuthorization() async -> Bool {
        guard let center else { return false }
        return (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
    }

    func authorizationStatus() async -> UNAuthorizationStatus {
        guard let center else { return .denied }
        return await center.notificationSettings().authorizationStatus
    }

    func post(title: String, body: String, imageURL: URL?) {
        guard let center else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        if let imageURL {
            // Attachments are moved into the notification store, so hand over a copy.
            let copy = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".jpg")
            if (try? FileManager.default.copyItem(at: imageURL, to: copy)) != nil,
               let attachment = try? UNNotificationAttachment(identifier: "photo", url: copy) {
                content.attachments = [attachment]
            }
        }
        center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        DispatchQueue.main.async {
            MainActor.assumeIsolated { self.onOpen?() }
        }
        completionHandler()
    }
}

// MARK: - Global hotkey (Carbon, needs no permissions)

@MainActor
final class GlobalHotKey {
    private static var handlers: [UInt32: () -> Void] = [:]
    private static var nextID: UInt32 = 1
    private static var handlerInstalled = false

    private var ref: EventHotKeyRef?
    private let id: UInt32

    init?(shortcut: KeyShortcut, handler: @escaping () -> Void) {
        Self.installHandlerIfNeeded()
        id = Self.nextID
        Self.nextID += 1

        let hotKeyID = EventHotKeyID(signature: OSType(0x4E50_656B), id: id) // "NPek"
        let status = RegisterEventHotKey(UInt32(shortcut.keyCode), shortcut.modifiers.carbonFlags,
                                         hotKeyID, GetApplicationEventTarget(), 0, &ref)
        guard status == noErr else {
            log.error("RegisterEventHotKey failed: \(status)")
            return nil
        }
        Self.handlers[id] = handler
    }

    func unregister() {
        if let ref { UnregisterEventHotKey(ref) }
        ref = nil
        Self.handlers[id] = nil
    }

    private static func installHandlerIfNeeded() {
        guard !handlerInstalled else { return }
        handlerInstalled = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hotKeyID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            let id = hotKeyID.id
            DispatchQueue.main.async {
                MainActor.assumeIsolated { GlobalHotKey.handlers[id]?() }
            }
            return noErr
        }, 1, &spec, nil, nil)
    }
}

// MARK: - Keystroke guard (needs Accessibility)

/// While a locked app is frontmost, swallows keystrokes before they reach it
/// and hands them to NoPeek instead. Defense in depth on top of overlay focus.
@MainActor
final class InputGuard {
    var shouldIntercept: (_ frontmostPID: pid_t) -> Bool = { _ in false }
    var onInterceptedKeyDown: (NSEvent) -> Void = { _ in }

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private(set) var isRunning = false
    /// The tap is only enabled while something is locked, so normal typing never passes through NoPeek.
    private var wantsActive = false

    static var isTrusted: Bool { AXIsProcessTrusted() }

    static func promptForTrust() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    @discardableResult
    func startIfPossible() -> Bool {
        guard !isRunning, Self.isTrusted else { return isRunning }
        let mask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(mask),
            callback: inputGuardCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            log.error("Could not create keyboard event tap")
            return false
        }
        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: wantsActive)
        self.tap = tap
        self.source = source
        isRunning = true
        log.info("Keyboard guard active")
        return true
    }

    /// Turn interception on only while at least one app is locked.
    func setActive(_ active: Bool) {
        wantsActive = active
        if let tap { CGEvent.tapEnable(tap: tap, enable: active) }
    }

    fileprivate func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap, wantsActive { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        guard wantsActive else { return Unmanaged.passUnretained(event) }
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier,
              shouldIntercept(pid) else {
            return Unmanaged.passUnretained(event)
        }
        if type == .keyDown, let nsEvent = NSEvent(cgEvent: event) {
            onInterceptedKeyDown(nsEvent)
        }
        return nil
    }
}

private func inputGuardCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    refcon: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let refcon else { return Unmanaged.passUnretained(event) }
    let guardian = Unmanaged<InputGuard>.fromOpaque(refcon).takeUnretainedValue()
    // The tap's run loop source is on the main run loop.
    return MainActor.assumeIsolated { guardian.handle(type: type, event: event) }
}
