import Foundation

/// Access only on the plugin's queue.
final class PluginStorage: @unchecked Sendable {
    private var values: [String: String]
    private let file: URL?
    private var saveScheduled = false

    init(file: URL?) {
        self.file = file
        values = file.flatMap { try? Data(contentsOf: $0) }.flatMap { try? JSONDecoder().decode([String: String].self, from: $0) } ?? [:]
    }

    func value(for key: String) -> String? { values[key] }

    var keys: [String] { values.keys.sorted() }

    func set(_ value: String?, for key: String, saveOn queue: DispatchQueue) {
        values[key] = value
        scheduleSave(on: queue)
    }

    func clear(saveOn queue: DispatchQueue) {
        values.removeAll()
        scheduleSave(on: queue)
    }

    private func scheduleSave(on queue: DispatchQueue) {
        guard file != nil, !saveScheduled else { return }
        saveScheduled = true
        queue.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self else { return }
            saveScheduled = false
            save()
        }
    }

    private func save() {
        guard let file else { return }
        let manager = FileManager.default
        do {
            try manager.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            try encoder.encode(values).write(to: file, options: .atomic)
            try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        } catch {
        }
    }
}
