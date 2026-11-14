import CoreServices
import Foundation

/// Tells the monitor which files changed under some folders. The real one is FSEvents; tests call the handler by hand.
public protocol AIAgentFileWatching: AnyObject {
    /// `onChange` gets the changed paths, or nil when the system lost track and everything should be looked at.
    func start(paths: [String], queue: DispatchQueue, onChange: @escaping @Sendable ([String]?) -> Void)
    func stop()
}

/// FSEvents with per-file events, coalesced over `latency` seconds. Nothing runs while nothing changes.
public final class FSEventsFileWatcher: AIAgentFileWatching, @unchecked Sendable {
    private final class Box {
        let onChange: @Sendable ([String]?) -> Void
        init(_ onChange: @escaping @Sendable ([String]?) -> Void) { self.onChange = onChange }
    }

    private let latency: CFTimeInterval
    private var stream: FSEventStreamRef?
    private var box: Box?

    public init(latency: CFTimeInterval = 1.0) {
        self.latency = latency
    }

    deinit { stop() }

    public func start(paths: [String], queue: DispatchQueue, onChange: @escaping @Sendable ([String]?) -> Void) {
        stop()
        guard !paths.isEmpty else { return }
        let box = Box(onChange)
        self.box = box
        var context = FSEventStreamContext(
            version: 0, info: Unmanaged.passUnretained(box).toOpaque(), retain: nil, release: nil, copyDescription: nil
        )
        let callback: FSEventStreamCallback = { _, info, count, eventPaths, flags, _ in
            guard let info else { return }
            let box = Unmanaged<Box>.fromOpaque(info).takeUnretainedValue()
            let paths = unsafeBitCast(eventPaths, to: NSArray.self) as? [String] ?? []
            var mustRescan = false
            for index in 0..<count {
                let flag = Int(flags[index])
                if flag & (kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagUserDropped | kFSEventStreamEventFlagKernelDropped) != 0 {
                    mustRescan = true
                }
            }
            box.onChange(mustRescan ? nil : paths)
        }
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents)
        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault, callback, &context, paths as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency, flags
        ) else { return }
        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)
        self.stream = stream
    }

    public func stop() {
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
        stream = nil
        box = nil
    }
}
