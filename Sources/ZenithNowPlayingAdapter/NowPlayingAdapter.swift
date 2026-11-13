import Foundation

// The system's Now Playing session, printed as JSON lines.
//
// Since macOS 15.4 the private MediaRemote framework answers only processes that carry Apple's signature, so
// Zenith cannot read it in its own process. `/usr/bin/perl` is such a process: `PerlNowPlayingSource` (ZenithCore)
// starts perl, has it load this library with DynaLoader and calls one of the two entry points below. Nothing here is
// linked into the app; `bundle_app.sh` copies the library to `Contents/Frameworks` and signs it.
//
// Output, one object per line: `pid`, `bundleID`, `parentBundleID`, `title`, `artist`, `album`, `duration`,
// `elapsed` (already moved forward to the moment of printing), `rate`, `playing`, and `artwork` (base64) or
// `artworkSame` when it is the picture of the previous line, and `canNext` / `canPrevious` / `canSeek` when the
// player says which commands it takes (absent when it does not say). Nothing playing is `{"playing":false}`.
// Input (watch mode), one command per line: `toggle`, `next`, `previous`, or `seek <seconds>`; answered with
// `{"command":…,"sent":…}`.

private typealias InfoCallback = @convention(block) (NSDictionary?) -> Void
private typealias InfoFunction = @convention(c) (DispatchQueue, @escaping InfoCallback) -> Void
private typealias PIDCallback = @convention(block) (Int32) -> Void
private typealias PIDFunction = @convention(c) (DispatchQueue, @escaping PIDCallback) -> Void
private typealias BoolCallback = @convention(block) (Bool) -> Void
private typealias BoolFunction = @convention(c) (DispatchQueue, @escaping BoolCallback) -> Void
private typealias ClientCallback = @convention(block) (AnyObject?) -> Void
private typealias ClientFunction = @convention(c) (DispatchQueue, @escaping ClientCallback) -> Void
private typealias ClientStringFunction = @convention(c) (AnyObject?) -> Unmanaged<CFString>?
private typealias RegisterFunction = @convention(c) (DispatchQueue) -> Void
private typealias SendCommandFunction = @convention(c) (UInt32, CFDictionary?) -> Bool
private typealias CommandsCallback = @convention(block) (CFArray?) -> Void
// Queue and callback only. (Passing an origin first, as the ...ForOrigin variant takes, crashes the process.)
private typealias SupportedCommandsFunction = @convention(c) (DispatchQueue, @escaping CommandsCallback) -> Void
private typealias CommandIDFunction = @convention(c) (UnsafeRawPointer) -> UInt32
private typealias CommandEnabledFunction = @convention(c) (UnsafeRawPointer) -> Bool

private enum MediaRemote {
    static let handle = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_LAZY)

    static func function<T>(_ name: String, as type: T.Type) -> T? {
        guard let handle, let symbol = dlsym(handle, name) else { return nil }
        return unsafeBitCast(symbol, to: type)
    }

    /// MRMediaRemoteCommand values.
    static let commands: [String: UInt32] = ["toggle": 2, "next": 4, "previous": 5]
    static let nextTrack: UInt32 = 4
    static let previousTrack: UInt32 = 5
    static let seekToPlaybackPosition: UInt32 = 24

    /// The key under which a seek command carries its position, read from the framework's exported constant.
    static let playbackPositionKey: String? = {
        guard let handle, let symbol = dlsym(handle, "kMRMediaRemoteOptionPlaybackPosition") else { return nil }
        return symbol.assumingMemoryBound(to: Unmanaged<CFString>?.self).pointee?.takeUnretainedValue() as String?
    }()
}

/// Artwork goes through the pipe as base64 on one line; a larger picture is left out.
private let maximumArtworkBytes = 4 * 1_024 * 1_024
/// How long MediaRemote gets to call back before a read is given up.
private let readTimeout: TimeInterval = 2

private let outputLock = NSLock()
/// Reads run one at a time on this queue, so `previousArtwork` needs no lock of its own.
private let reader = DispatchQueue(label: "zenith.now-playing-adapter.reader")
private let callbacks = DispatchQueue(label: "zenith.now-playing-adapter.callbacks")
private var previousArtwork: Data?

private func emit(_ object: [String: Any]) {
    // JSONSerialization raises an Objective-C exception for NaN and infinity (a live stream's duration can be
    // either), which Swift cannot catch.
    let finite = object.filter { ($0.value as? Double)?.isFinite != false }
    let data = (try? JSONSerialization.data(withJSONObject: finite)) ?? Data(#"{"error":"json"}"#.utf8)
    outputLock.lock()
    defer { outputLock.unlock() }
    FileHandle.standardOutput.write(data + Data("\n".utf8))
}

/// Reads the current session. Returns nil when MediaRemote did not answer in time.
private func readSnapshot(deduplicatingArtwork: Bool) -> [String: Any]? {
    guard let getInfo = MediaRemote.function("MRMediaRemoteGetNowPlayingInfo", as: InfoFunction.self) else {
        return ["error": "MRMediaRemoteGetNowPlayingInfo unavailable"]
    }

    let group = DispatchGroup()
    let lock = NSLock()
    var result: [String: Any] = [:]
    var info: [String: Any] = [:]
    func set(_ key: String, _ value: Any?) {
        guard let value else { return }
        lock.lock()
        result[key] = value
        lock.unlock()
    }

    group.enter()
    getInfo(callbacks) { dictionary in
        lock.lock()
        info = (dictionary as? [String: Any]) ?? [:]
        lock.unlock()
        group.leave()
    }
    if let getPID = MediaRemote.function("MRMediaRemoteGetNowPlayingApplicationPID", as: PIDFunction.self) {
        group.enter()
        getPID(callbacks) { pid in
            if pid > 0 { set("pid", Int(pid)) }
            group.leave()
        }
    }
    if let getIsPlaying = MediaRemote.function("MRMediaRemoteGetNowPlayingApplicationIsPlaying", as: BoolFunction.self) {
        group.enter()
        getIsPlaying(callbacks) { isPlaying in
            set("playing", isPlaying)
            group.leave()
        }
    }
    // Safari plays in a helper (com.apple.WebKit.GPU); the client names the app the helper belongs to.
    if let getClient = MediaRemote.function("MRMediaRemoteGetNowPlayingClient", as: ClientFunction.self) {
        let bundleID = MediaRemote.function("MRNowPlayingClientGetBundleIdentifier", as: ClientStringFunction.self)
        let parentID = MediaRemote.function("MRNowPlayingClientGetParentAppBundleIdentifier", as: ClientStringFunction.self)
        group.enter()
        getClient(callbacks) { client in
            if let client {
                set("bundleID", bundleID?(client)?.takeUnretainedValue() as String?)
                set("parentBundleID", parentID?(client)?.takeUnretainedValue() as String?)
            }
            group.leave()
        }
    }

    // Which commands the player takes, so the island shows no button that does nothing (a video has no next track).
    // This one may not answer at all; it gets a short wait of its own and the keys are simply left out.
    let capabilities = DispatchGroup()
    if let getCommands = MediaRemote.function("MRMediaRemoteGetSupportedCommands", as: SupportedCommandsFunction.self),
       let commandID = MediaRemote.function("MRMediaRemoteCommandInfoGetCommand", as: CommandIDFunction.self),
       let commandEnabled = MediaRemote.function("MRMediaRemoteCommandInfoGetEnabled", as: CommandEnabledFunction.self) {
        capabilities.enter()
        getCommands(callbacks) { commands in
            if let commands {
                let infos = (0..<CFArrayGetCount(commands)).compactMap { CFArrayGetValueAtIndex(commands, $0) }
                func supports(_ command: UInt32) -> Bool {
                    infos.contains { commandID($0) == command && commandEnabled($0) }
                }
                set("canNext", supports(MediaRemote.nextTrack))
                set("canPrevious", supports(MediaRemote.previousTrack))
                set("canSeek", MediaRemote.playbackPositionKey != nil && supports(MediaRemote.seekToPlaybackPosition))
            }
            capabilities.leave()
        }
    }

    guard group.wait(timeout: .now() + readTimeout) == .success else { return nil }
    _ = capabilities.wait(timeout: .now() + 0.3)

    lock.lock()
    var snapshot = result
    let values = info
    lock.unlock()

    let title = values["kMRMediaRemoteNowPlayingInfoTitle"] as? String
    let artist = values["kMRMediaRemoteNowPlayingInfoArtist"] as? String
    guard snapshot["pid"] != nil || title != nil || artist != nil else {
        previousArtwork = nil
        return ["playing": false]
    }

    snapshot["title"] = title
    snapshot["artist"] = artist
    snapshot["album"] = values["kMRMediaRemoteNowPlayingInfoAlbum"] as? String
    snapshot["duration"] = (values["kMRMediaRemoteNowPlayingInfoDuration"] as? NSNumber)?.doubleValue

    let rate = (values["kMRMediaRemoteNowPlayingInfoPlaybackRate"] as? NSNumber)?.doubleValue ?? 0
    snapshot["rate"] = rate
    // Some players never update their rate, so their own playing state (read above) wins when there is one.
    let isPlaying = snapshot["playing"] as? Bool ?? (rate > 0)
    snapshot["playing"] = isPlaying

    if let elapsed = (values["kMRMediaRemoteNowPlayingInfoElapsedTime"] as? NSNumber)?.doubleValue {
        // The position was sampled at `Timestamp`; a playing song has moved on since.
        let age = (values["kMRMediaRemoteNowPlayingInfoTimestamp"] as? Date).map { max(0, Date().timeIntervalSince($0)) } ?? 0
        snapshot["elapsed"] = isPlaying ? elapsed + age * max(rate, 0) : elapsed
    }

    let artwork = values["kMRMediaRemoteNowPlayingInfoArtworkData"] as? Data
    if deduplicatingArtwork, let artwork, artwork == previousArtwork {
        snapshot["artworkSame"] = true
    } else if let artwork, !artwork.isEmpty, artwork.count <= maximumArtworkBytes {
        snapshot["artwork"] = artwork.base64EncodedString()
    }
    if deduplicatingArtwork { previousArtwork = artwork }
    return snapshot
}

/// Prints the current session once and returns.
@_cdecl("zenith_now_playing_get")
public func zenithNowPlayingGet() {
    reader.sync {
        emit(readSnapshot(deduplicatingArtwork: false) ?? ["error": "timeout"])
    }
}

/// Prints the session now and again whenever it changes, and takes playback commands on standard input.
/// Ends when standard input closes, which is also what happens when the app that started it dies.
@_cdecl("zenith_now_playing_watch")
public func zenithNowPlayingWatch() {
    guard let register = MediaRemote.function("MRMediaRemoteRegisterForNowPlayingNotifications", as: RegisterFunction.self) else {
        emit(["error": "notifications unavailable"])
        return
    }
    register(.main)

    func read() {
        guard let snapshot = readSnapshot(deduplicatingArtwork: true) else {
            // A callback that never came would leave the app showing a stale song. The app starts a new watcher.
            emit(["error": "timeout"])
            exit(1)
        }
        emit(snapshot)
    }

    // One change arrives as several notifications; wait for them to settle and read once.
    var pending: DispatchWorkItem?
    func scheduleRead() {
        pending?.cancel()
        let work = DispatchWorkItem { read() }
        pending = work
        reader.asyncAfter(deadline: .now() + 0.1, execute: work)
    }

    let names = [
        "kMRMediaRemoteNowPlayingInfoDidChangeNotification",
        "kMRMediaRemoteNowPlayingApplicationDidChangeNotification",
        "kMRMediaRemoteNowPlayingApplicationIsPlayingDidChangeNotification",
        "kMRMediaRemoteNowPlayingApplicationClientStateDidChange",
        "kMRMediaRemoteNowPlayingPlayerStateDidChange"
    ]
    let observers = names.map { name in
        NotificationCenter.default.addObserver(forName: Notification.Name(name), object: nil, queue: .main) { _ in
            scheduleRead()
        }
    }

    let sendCommand = MediaRemote.function("MRMediaRemoteSendCommand", as: SendCommandFunction.self)
    var unfinishedLine = Data()
    FileHandle.standardInput.readabilityHandler = { input in
        let data = input.availableData
        if data.isEmpty { exit(0) }
        DispatchQueue.main.async {
            unfinishedLine.append(data)
            while let newline = unfinishedLine.firstIndex(of: 0x0A) {
                let word = String(decoding: unfinishedLine[unfinishedLine.startIndex..<newline], as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                unfinishedLine.removeSubrange(unfinishedLine.startIndex...newline)
                guard !word.isEmpty else { continue }
                let parts = word.split(separator: " ")
                let name = String(parts[0])
                var sent = false
                if name == "seek" {
                    if parts.count == 2, let position = Double(parts[1]), position.isFinite, position >= 0,
                       let key = MediaRemote.playbackPositionKey {
                        sent = sendCommand?(MediaRemote.seekToPlaybackPosition, [key: position] as CFDictionary) ?? false
                    }
                } else if parts.count == 1, let command = MediaRemote.commands[name] {
                    sent = sendCommand?(command, nil) ?? false
                }
                emit(["command": name, "sent": sent])
            }
            // Nothing sensible is longer than a word; do not let a stream without newlines grow.
            if unfinishedLine.count > 256 { unfinishedLine.removeAll() }
        }
    }

    reader.async { read() }
    withExtendedLifetime(observers) { RunLoop.main.run() }
}
