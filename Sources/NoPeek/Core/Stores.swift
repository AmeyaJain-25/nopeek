import AppKit
import Combine
import NoPeekCore

// MARK: - Settings

@MainActor
final class SettingsStore: ObservableObject {
    @Published var settings: AppSettings {
        didSet { if settings != oldValue { scheduleSave() } }
    }

    let isFirstLaunch: Bool
    private var saveTask: Task<Void, Never>?

    init() {
        let url = AppPaths.settingsFile
        if let data = try? Data(contentsOf: url) {
            if let decoded = try? JSONCoding.decoder.decode(AppSettings.self, from: data) {
                settings = decoded
            } else {
                // Keep the broken file for inspection instead of silently overwriting it.
                let backup = url.deletingPathExtension().appendingPathExtension("corrupt.json")
                try? FileManager.default.removeItem(at: backup)
                try? FileManager.default.moveItem(at: url, to: backup)
                log.error("settings.json was unreadable; moved to settings.corrupt.json and reset to defaults")
                settings = .default
            }
            isFirstLaunch = false
        } else {
            settings = .default
            isFirstLaunch = true
            JSONCoding.write(settings, to: url)
        }
    }

    func app(withID id: UUID) -> ProtectedApp? {
        settings.apps.first { $0.id == id }
    }

    func update(app: ProtectedApp) {
        guard let index = settings.apps.firstIndex(where: { $0.id == app.id }) else { return }
        settings.apps[index] = app
    }

    func saveNow() {
        saveTask?.cancel()
        JSONCoding.write(settings, to: AppPaths.settingsFile)
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = after(0.4) { [weak self] in self?.saveNow() }
    }
}

// MARK: - Secret words

/// Salted hashes of per-app secret words, stored in a 0600 file.
@MainActor
final class SecretVault {
    private var digests: [String: SecretDigest]

    init() {
        if let data = try? Data(contentsOf: AppPaths.secretsFile),
           let decoded = try? JSONCoding.decoder.decode([String: SecretDigest].self, from: data) {
            digests = decoded
        } else {
            digests = [:]
        }
    }

    func digest(for appID: UUID) -> SecretDigest? {
        digests[appID.uuidString]
    }

    func setSecret(_ secret: String, for appID: UUID) throws {
        digests[appID.uuidString] = try SecretHasher.makeDigest(for: secret)
        persist()
    }

    func removeSecret(for appID: UUID) {
        digests[appID.uuidString] = nil
        persist()
    }

    private func persist() {
        JSONCoding.write(digests, to: AppPaths.secretsFile, privateFile: true)
    }
}

// MARK: - Captured photos

@MainActor
final class CaptureStore: ObservableObject {
    @Published private(set) var records: [CaptureRecord] = []
    @Published private(set) var lastViewedAt: Date

    private static let lastViewedKey = "captures.lastViewedAt"

    init() {
        lastViewedAt = UserDefaults.standard.object(forKey: Self.lastViewedKey) as? Date ?? .distantPast
        if let data = try? Data(contentsOf: AppPaths.captureIndexFile),
           let decoded = try? JSONCoding.decoder.decode([CaptureRecord].self, from: data) {
            records = decoded.filter { FileManager.default.fileExists(atPath: url(for: $0).path) }
        }
    }

    var unseenCount: Int { records.filter { $0.date > lastViewedAt }.count }

    func url(for record: CaptureRecord) -> URL {
        AppPaths.capturesDirectory.appendingPathComponent(record.fileName)
    }

    func image(for record: CaptureRecord) -> NSImage? {
        NSImage(contentsOf: url(for: record))
    }

    /// Saves the photo as JPEG and returns the new record.
    func add(imageData: Data, date: Date, bundleID: String, appName: String, attempt: Int) -> CaptureRecord? {
        guard let jpeg = Self.jpegData(from: imageData) else { return nil }
        let id = UUID()
        let record = CaptureRecord(id: id, date: date, bundleID: bundleID, appName: appName,
                                   attempt: attempt, fileName: "\(id.uuidString).jpg")
        do {
            try jpeg.write(to: url(for: record), options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url(for: record).path)
        } catch {
            log.error("Failed to save capture: \(error.localizedDescription, privacy: .public)")
            return nil
        }
        records.insert(record, at: 0)
        persist()
        return record
    }

    func delete(ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        for record in records where ids.contains(record.id) {
            try? FileManager.default.removeItem(at: url(for: record))
        }
        records.removeAll { ids.contains($0.id) }
        persist()
    }

    func deleteAll() {
        delete(ids: Set(records.map(\.id)))
    }

    func purge(olderThanDays days: Int) {
        guard days > 0 else { return }
        let cutoff = Date().addingTimeInterval(-TimeInterval(days) * 86_400)
        delete(ids: Set(records.filter { $0.date < cutoff }.map(\.id)))
    }

    func markViewed() {
        lastViewedAt = Date()
        UserDefaults.standard.set(lastViewedAt, forKey: Self.lastViewedKey)
    }

    private func persist() {
        JSONCoding.write(records, to: AppPaths.captureIndexFile, privateFile: true)
    }

    private static func jpegData(from data: Data) -> Data? {
        guard let rep = NSBitmapImageRep(data: data) ?? NSImage(data: data)?.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)) else {
            return nil
        }
        return rep.representation(using: .jpeg, properties: [.compressionFactor: 0.85])
    }
}
