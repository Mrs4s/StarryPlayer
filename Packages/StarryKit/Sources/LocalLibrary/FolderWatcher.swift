import CoreServices
import Foundation

/// Follows a library folder with FSEvents, folder by folder. Started
/// from the last event id it reported, it first replays what changed while the app was not
/// running, then says `historyDone`, then reports changes as they happen.
final class FolderWatcher: @unchecked Sendable {
    struct Batch: Sendable {
        var folders: Set<String> = []
        /// Folders to walk whole: events were dropped, or the history cannot say.
        var subtrees: Set<String> = []
        var rootChanged = false
        /// The replay of the time the app was not running is over.
        var historyDone = false
        var lastEventID: UInt64 = 0
    }

    private var stream: FSEventStreamRef?
    private let queue = DispatchQueue(label: "moe.mrs4s.starry-player.local-library.events")
    private let handler: @Sendable (Batch) -> Void

    /// `since` nil: from now (a folder never watched before, which is scanned whole anyway).
    init?(path: String, since: UInt64?, latency: TimeInterval = 2, handler: @escaping @Sendable (Batch) -> Void) {
        self.handler = handler
        // The stream holds the watcher (retain / release) for as long as it can call back, so a
        // callback already queued never finds it gone; `stop()` lets go of it.
        var context = FSEventStreamContext(version: 0, info: nil, retain: { info in
            guard let info else { return nil }
            _ = Unmanaged<FolderWatcher>.fromOpaque(info).retain()
            return info
        }, release: { info in
            guard let info else { return }
            Unmanaged<FolderWatcher>.fromOpaque(info).release()
        }, copyDescription: nil)
        context.info = Unmanaged.passUnretained(self).toOpaque()
        let flags = UInt32(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagWatchRoot)
        let start = since.map { FSEventStreamEventId($0) } ?? FSEventStreamEventId(kFSEventStreamEventIdSinceNow)
        guard let stream = FSEventStreamCreate(nil, FolderWatcher.callback, &context, [path] as CFArray, start, latency, flags) else { return nil }
        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, queue)
        guard FSEventStreamStart(stream) else {
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            self.stream = nil
            return nil
        }
        if since == nil {
            queue.async { [handler] in handler(Batch(historyDone: true, lastEventID: UInt64(FSEventsGetCurrentEventId()))) }
        }
    }

    /// Stops watching; the owner must call it (the stream holds the watcher until then).
    func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    static var currentEventID: UInt64 { UInt64(FSEventsGetCurrentEventId()) }

    private static let callback: FSEventStreamCallback = { _, info, count, paths, flags, ids in
        guard let info else { return }
        let watcher = Unmanaged<FolderWatcher>.fromOpaque(info).takeUnretainedValue()
        let array = unsafeBitCast(paths, to: NSArray.self)
        var batch = Batch()
        for index in 0..<count {
            guard let path = array[index] as? String else { continue }
            let flag = Int(flags[index])
            batch.lastEventID = max(batch.lastEventID, UInt64(ids[index]))
            if flag & kFSEventStreamEventFlagHistoryDone != 0 {
                batch.historyDone = true
                continue
            }
            if flag & kFSEventStreamEventFlagRootChanged != 0 {
                batch.rootChanged = true
                continue
            }
            let lost = kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagUserDropped | kFSEventStreamEventFlagKernelDropped
                | kFSEventStreamEventFlagEventIdsWrapped | kFSEventStreamEventFlagMount | kFSEventStreamEventFlagUnmount
            let folder = path.hasSuffix("/") && path.count > 1 ? String(path.dropLast()) : path
            if flag & lost != 0 {
                batch.subtrees.insert(folder)
            } else {
                batch.folders.insert(folder)
            }
        }
        watcher.handler(batch)
    }
}
