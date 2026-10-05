import CryptoKit
import Foundation

struct WalkedFile: Sendable, Hashable {
    var name: String
    var size: Int64
    var modified: Double
    var fileID: UInt64?
}

struct WalkedFolder: Sendable {
    var relativePath: String
    var audio: [WalkedFile] = []
    var others: [WalkedFile] = []
    var subfolders: [String] = []
    var unsupported = 0
    /// Every entry could be read: a file not listed is not there.
    var isComplete = true

    var name: String { (relativePath as NSString).lastPathComponent }

    /// Changes whenever a file the library cares about is added, removed, renamed or written
    /// (tags edited in place change no folder date, so the folder's own date is not enough).
    var signature: String {
        var hasher = SHA256()
        for file in (audio + others).sorted(by: { $0.name < $1.name }) {
            hasher.update(data: Data("\(file.name)\u{1}\(file.size)\u{1}\(file.modified)\u{2}".utf8))
        }
        return hasher.finalize().prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    var imageNames: [String] { others.map(\.name).filter { ["jpg", "jpeg", "png", "webp", "gif", "bmp"].contains(($0 as NSString).pathExtension.lowercased()) } }
}

enum FolderWalk {
    static let sideFileExtensions: Set<String> = ["jpg", "jpeg", "png", "webp", "gif", "bmp", "lrc", "ttml", "yrc", "qrc", "krc", "txt", "cue"]
    static let ignoreMarkers = [".nomedia", ".starryignore"]

    struct Result: Sendable {
        var folders: [String: WalkedFolder] = [:]
        /// Every folder under the start was read: what is not in `folders` is gone.
        var isComplete = true
    }

    private static let keys: [URLResourceKey] = [.isDirectoryKey, .isRegularFileKey, .fileSizeKey, .contentModificationDateKey, .fileIdentifierKey, .isSymbolicLinkKey]

    /// The folder at `relativePath` under `root` and every folder below it (or only it, with
    /// `recursive` false), skipping hidden files, packages, `excluded` folders and folders marked
    /// to be ignored.
    static func walk(root: URL, from relativePath: String = "", recursive: Bool = true, excluded: [String] = []) -> Result {
        var result = Result()
        let start = relativePath.isEmpty ? root : root.appending(path: relativePath, directoryHint: .isDirectory)
        guard isFolder(start) else {
            result.isComplete = false
            return result
        }
        let rootPath = canonicalPath(root.path)
        var pending: [String] = [relativePath]
        while let current = pending.popLast() {
            let url = current.isEmpty ? root : root.appending(path: current, directoryHint: .isDirectory)
            if ignoreMarkers.contains(where: { FileManager.default.fileExists(atPath: url.appending(path: $0).path) }) { continue }
            let entries: [URL]
            do {
                entries = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles, .skipsPackageDescendants])
            } catch {
                result.isComplete = false
                continue
            }
            var folder = WalkedFolder(relativePath: current)
            for entry in entries {
                guard let values = try? entry.resourceValues(forKeys: Set(keys)) else {
                    result.isComplete = false
                    folder.isComplete = false
                    continue
                }
                let name = entry.lastPathComponent
                let child = current.isEmpty ? name : current + "/" + name
                if values.isDirectory == true {
                    // Folders reached through a link are not followed: they may loop.
                    guard values.isSymbolicLink != true, !excluded.contains(child) else { continue }
                    guard canonicalPath(entry.path).hasPrefix(rootPath) else { continue }
                    folder.subfolders.append(name)
                    if recursive { pending.append(child) }
                    continue
                }
                guard values.isRegularFile == true || values.isSymbolicLink == true else { continue }
                let ext = (name as NSString).pathExtension.lowercased()
                let file = WalkedFile(name: name, size: Int64(values.fileSize ?? 0), modified: values.contentModificationDate?.timeIntervalSince1970 ?? 0, fileID: values.fileIdentifier)
                if TagReader.playableExtensions.contains(ext) {
                    folder.audio.append(file)
                } else if TagReader.unsupportedExtensions.contains(ext) {
                    folder.unsupported += 1
                } else if sideFileExtensions.contains(ext) {
                    folder.others.append(file)
                }
            }
            result.folders[current] = folder
        }
        return result
    }

    /// The path with links resolved as the system has it (`realpath`): `/private/tmp/…` for
    /// `/tmp/…`, as FSEvents names it — `resolvingSymlinksInPath` drops `/private` instead.
    static func canonicalPath(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else { return (path as NSString).standardizingPath }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    static func isFolder(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }
}
