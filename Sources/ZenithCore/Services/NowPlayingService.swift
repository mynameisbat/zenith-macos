import Foundation
import AppKit
import Combine
import CoreAudio

/// Dynamic bridge to macOS private MediaRemote framework for universal browser (Chrome, Safari, Arc, Firefox, etc.)
/// and system media player tracking with zero background CPU polling.
final class MediaRemoteBridge: @unchecked Sendable {
    static let shared = MediaRemoteBridge()

    typealias MRRegisterFunction = @convention(c) (DispatchQueue) -> Void
    typealias MRSetWantsFunction = @convention(c) (Bool) -> Void
    typealias MRGetInfoFunction = @convention(c) (DispatchQueue, @escaping (CFDictionary?) -> Void) -> Void
    typealias MRGetPIDFunction = @convention(c) (DispatchQueue, @escaping (pid_t) -> Void) -> Void
    typealias MRGetIsPlayingFunction = @convention(c) (DispatchQueue, @escaping (Bool) -> Void) -> Void
    typealias MRSendCommandFunction = @convention(c) (UInt32, AnyObject?) -> Bool

    private var registerFn: MRRegisterFunction?
    private var setWantsFn: MRSetWantsFunction?
    private var getInfoFn: MRGetInfoFunction?
    private var getPIDFn: MRGetPIDFunction?
    private var getIsPlayingFn: MRGetIsPlayingFunction?
    private var sendCommandFn: MRSendCommandFunction?
    private var isRegistered = false

    init() {
        if let handle = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_NOW) {
            if let symReg = dlsym(handle, "MRMediaRemoteRegisterForNowPlayingNotifications") {
                registerFn = unsafeBitCast(symReg, to: MRRegisterFunction.self)
            }
            if let symWants = dlsym(handle, "MRMediaRemoteSetWantsNowPlayingNotifications") {
                setWantsFn = unsafeBitCast(symWants, to: MRSetWantsFunction.self)
            }
            if let symInfo = dlsym(handle, "MRMediaRemoteGetNowPlayingInfo") {
                getInfoFn = unsafeBitCast(symInfo, to: MRGetInfoFunction.self)
            }
            if let symPID = dlsym(handle, "MRMediaRemoteGetNowPlayingApplicationPID") {
                getPIDFn = unsafeBitCast(symPID, to: MRGetPIDFunction.self)
            }
            if let symPlaying = dlsym(handle, "MRMediaRemoteGetNowPlayingApplicationIsPlaying") {
                getIsPlayingFn = unsafeBitCast(symPlaying, to: MRGetIsPlayingFunction.self)
            }
            if let symSend = dlsym(handle, "MRMediaRemoteSendCommand") {
                sendCommandFn = unsafeBitCast(symSend, to: MRSendCommandFunction.self)
            }
        }
    }

    func registerForNotifications() {
        guard !isRegistered else { return }
        registerFn?(DispatchQueue.main)
        setWantsFn?(true)
        isRegistered = true
    }

    func queryNowPlaying(completion: @escaping @MainActor (NowPlayingTrack?) -> Void) {
        guard let getPID = getPIDFn, let getInfo = getInfoFn else {
            Task { @MainActor in completion(nil) }
            return
        }

        getPID(DispatchQueue.main) { pid in
            let app = NSRunningApplication(processIdentifier: pid)
            let bundleId = app?.bundleIdentifier
            let appName = app?.localizedName

            // Query active tab URL if it's a browser (Chrome, Safari, Arc)
            let activeUrl = Self.fetchActiveBrowserUrl(bundleId: bundleId)

            getInfo(DispatchQueue.main) { dict in
                guard let info = dict as? [String: Any] else {
                    Task { @MainActor in completion(nil) }
                    return
                }

                let rawTitle = (info["kMRMediaRemoteNowPlayingInfoTitle"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
                let rawArtist = (info["kMRMediaRemoteNowPlayingInfoArtist"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
                let album = info["kMRMediaRemoteNowPlayingInfoAlbum"] as? String
                let duration = (info["kMRMediaRemoteNowPlayingInfoDuration"] as? NSNumber)?.doubleValue ?? 0
                let elapsed = (info["kMRMediaRemoteNowPlayingInfoElapsedTime"] as? NSNumber)?.doubleValue ?? 0
                let rate = (info["kMRMediaRemoteNowPlayingInfoPlaybackRate"] as? NSNumber)?.doubleValue ?? 0
                let artworkData = info["kMRMediaRemoteNowPlayingInfoArtworkData"] as? Data

                let resolvedApp = NowPlayingApp.resolve(
                    bundleId: bundleId,
                    title: rawTitle,
                    artist: rawArtist,
                    activeUrl: activeUrl
                )

                let title = (rawTitle?.isEmpty == false) ? rawTitle! : (appName ?? resolvedApp.displayName)
                let artist = (rawArtist?.isEmpty == false) ? rawArtist! : resolvedApp.displayName

                // Verify playback status
                let isRatePlaying = rate > 0
                if isRatePlaying {
                    let track = NowPlayingTrack(
                        app: resolvedApp,
                        title: title,
                        artist: artist,
                        album: (album?.isEmpty ?? true) ? nil : album,
                        duration: duration,
                        position: elapsed,
                        isPlaying: true,
                        artworkData: artworkData
                    )
                    Task { @MainActor in completion(track) }
                } else if let getIsPlaying = self.getIsPlayingFn {
                    getIsPlaying(DispatchQueue.main) { isSysPlaying in
                        let track = NowPlayingTrack(
                            app: resolvedApp,
                            title: title,
                            artist: artist,
                            album: (album?.isEmpty ?? true) ? nil : album,
                            duration: duration,
                            position: elapsed,
                            isPlaying: isSysPlaying,
                            artworkData: artworkData
                        )
                        Task { @MainActor in completion(track) }
                    }
                } else {
                    let track = NowPlayingTrack(
                        app: resolvedApp,
                        title: title,
                        artist: artist,
                        album: (album?.isEmpty ?? true) ? nil : album,
                        duration: duration,
                        position: elapsed,
                        isPlaying: false,
                        artworkData: artworkData
                    )
                    Task { @MainActor in completion(track) }
                }
            }
        }
    }

    private static func fetchActiveBrowserUrl(bundleId: String?) -> String? {
        guard let bundleId = bundleId else { return nil }
        if bundleId.contains("com.google.Chrome") {
            let script = NSAppleScript(source: "tell application \"Google Chrome\" to return URL of active tab of front window")
            var err: NSDictionary?
            return script?.executeAndReturnError(&err).stringValue
        } else if bundleId.contains("com.apple.Safari") {
            let script = NSAppleScript(source: "tell application \"Safari\" to return URL of current tab of front window")
            var err: NSDictionary?
            return script?.executeAndReturnError(&err).stringValue
        } else if bundleId.contains("thebrowser") || bundleId.contains("arc") {
            let script = NSAppleScript(source: "tell application \"Arc\" to return URL of active tab of front window")
            var err: NSDictionary?
            return script?.executeAndReturnError(&err).stringValue
        }
        return nil
    }

    @discardableResult
    func sendCommand(_ command: UInt32) -> Bool {
        guard let send = sendCommandFn else { return false }
        return send(command, nil)
    }
}

/// Concurrency-safe service coordinating Apple Music, Spotify, YouTube, X, and browser playback telemetry
/// and remote playback controls for Zenith Dynamic Island.
@MainActor
public final class NowPlayingService: ObservableObject {
    public static let shared = NowPlayingService()

    @Published public var currentTrack: NowPlayingTrack?
    @Published public var isMonitoring: Bool = false

    private var distributedObservers: [NSObjectProtocol] = []
    private var workspaceObservers: [NSObjectProtocol] = []
    private var adaptiveTicker: Task<Void, Never>?

    // CoreAudio hardware listener
    private var coreAudioDeviceID: AudioDeviceID = 0
    private var coreAudioPropertyAddress: AudioObjectPropertyAddress?
    private var coreAudioListenerBlock: AudioObjectPropertyListenerBlock?

    public init() {}

    /// Starts observing system-wide media playback notifications with zero background polling.
    public func startMonitoring() {
        guard !isMonitoring else { return }
        self.isMonitoring = true

        let center = DistributedNotificationCenter.default()

        // 1. Observe Apple Music playback state changes
        let musicObserver = center.addObserver(
            forName: NSNotification.Name("com.apple.Music.playerInfo"),
            object: nil,
            queue: nil
        ) { [weak self] notification in
            let playerState = notification.userInfo?["Player State"] as? String ?? ""
            let name = notification.userInfo?["Name"] as? String
            let artist = notification.userInfo?["Artist"] as? String
            let album = notification.userInfo?["Album"] as? String
            let totalTime = (notification.userInfo?["Total Time"] as? NSNumber)?.doubleValue ?? 0.0
            let position = (notification.userInfo?["Player Position"] as? NSNumber)?.doubleValue ?? 0.0

            Task { @MainActor [weak self] in
                self?.processAppleMusicTrack(
                    playerState: playerState,
                    name: name,
                    artist: artist,
                    album: album,
                    durationMs: totalTime,
                    positionSec: position
                )
            }
        }
        distributedObservers.append(musicObserver)

        // 2. Observe Spotify playback state changes
        let spotifyObserver = center.addObserver(
            forName: NSNotification.Name("com.spotify.client.PlaybackStateChanged"),
            object: nil,
            queue: nil
        ) { [weak self] notification in
            let playerState = notification.userInfo?["Player State"] as? String ?? ""
            let name = notification.userInfo?["Name"] as? String
            let artist = notification.userInfo?["Artist"] as? String
            let album = notification.userInfo?["Album"] as? String
            let duration = (notification.userInfo?["Duration"] as? NSNumber)?.doubleValue ?? 0.0
            let position = (notification.userInfo?["Playback Position"] as? NSNumber)?.doubleValue ?? 0.0

            Task { @MainActor [weak self] in
                self?.processSpotifyTrack(
                    playerState: playerState,
                    name: name,
                    artist: artist,
                    album: album,
                    durationMs: duration,
                    positionSec: position
                )
            }
        }
        distributedObservers.append(spotifyObserver)

        // 3. Register CoreAudio hardware listener for instant audio start/stop detection
        setupCoreAudioListener()

        // 4. Register Workspace observer for frontmost app changes
        let appObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshMediaRemoteTrack()
            }
        }
        workspaceObservers.append(appObserver)

        // 5. Register MediaRemote notifications
        MediaRemoteBridge.shared.registerForNotifications()

        // 6. Start adaptive ticker (ticks every 1s when media playing, 2s when idle)
        startAdaptiveTicker()

        // Initial check for currently running media players & browser media
        refreshMediaRemoteTrack()
        checkRunningPlayers()
    }

    /// Stops media observation and cleans up notification listeners.
    public func stopMonitoring() {
        let center = DistributedNotificationCenter.default()
        for obs in distributedObservers {
            center.removeObserver(obs)
        }
        distributedObservers.removeAll()

        for obs in workspaceObservers {
            NSWorkspace.shared.notificationCenter.removeObserver(obs)
        }
        workspaceObservers.removeAll()

        teardownCoreAudioListener()
        adaptiveTicker?.cancel()
        adaptiveTicker = nil
        self.isMonitoring = false
        self.currentTrack = nil
        ZenithIslandState.shared.nowPlayingTrack = nil
    }

    /// Refreshes track state from system MediaRemote framework.
    public func refreshMediaRemoteTrack() {
        MediaRemoteBridge.shared.queryNowPlaying { [weak self] track in
            guard let self = self else { return }
            if let track = track {
                if track.isPlaying {
                    self.updateTrack(track)
                } else if self.currentTrack?.id == track.id {
                    self.updateTrack(track)
                } else if self.currentTrack?.app != .appleMusic && self.currentTrack?.app != .spotify {
                    self.currentTrack = nil
                    ZenithIslandState.shared.nowPlayingTrack = nil
                }
            } else if self.currentTrack?.app != .appleMusic && self.currentTrack?.app != .spotify {
                self.currentTrack = nil
                ZenithIslandState.shared.nowPlayingTrack = nil
            }
        }
    }

    // MARK: - CoreAudio Hardware Output Listener

    private func setupCoreAudioListener() {
        var defaultOutputDeviceID = AudioDeviceID(0)
        var propertySize = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &propertySize,
            &defaultOutputDeviceID
        )

        guard status == noErr, defaultOutputDeviceID != 0 else { return }
        self.coreAudioDeviceID = defaultOutputDeviceID

        var isRunningAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        self.coreAudioPropertyAddress = isRunningAddress

        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor [weak self] in
                self?.refreshMediaRemoteTrack()
            }
        }
        self.coreAudioListenerBlock = block

        AudioObjectAddPropertyListenerBlock(
            defaultOutputDeviceID,
            &isRunningAddress,
            DispatchQueue.main,
            block
        )
    }

    private func teardownCoreAudioListener() {
        if coreAudioDeviceID != 0, var address = coreAudioPropertyAddress, let block = coreAudioListenerBlock {
            AudioObjectRemovePropertyListenerBlock(
                coreAudioDeviceID,
                &address,
                DispatchQueue.main,
                block
            )
        }
        coreAudioListenerBlock = nil
        coreAudioPropertyAddress = nil
        coreAudioDeviceID = 0
    }

    // MARK: - Adaptive Media Ticker

    private func startAdaptiveTicker() {
        adaptiveTicker?.cancel()
        adaptiveTicker = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                let isPlaying = self?.currentTrack?.isPlaying == true
                let delayNanos: UInt64 = isPlaying ? 1_000_000_000 : 2_000_000_000
                try? await Task.sleep(nanoseconds: delayNanos)
                guard let self = self, !Task.isCancelled else { break }

                if let track = self.currentTrack, track.isPlaying && (track.app == .appleMusic || track.app == .spotify) {
                    let newPos = min(track.position + 1.0, track.duration)
                    let updated = NowPlayingTrack(
                        app: track.app,
                        title: track.title,
                        artist: track.artist,
                        album: track.album,
                        duration: track.duration,
                        position: newPos,
                        isPlaying: track.isPlaying,
                        artworkData: track.artworkData
                    )
                    self.currentTrack = updated
                    ZenithIslandState.shared.nowPlayingTrack = updated
                } else {
                    self.refreshMediaRemoteTrack()
                }
            }
        }
    }

    // MARK: - Notification Processors

    public func processAppleMusicTrack(
        playerState: String,
        name: String?,
        artist: String?,
        album: String?,
        durationMs: Double,
        positionSec: Double
    ) {
        let isPlaying = playerState.caseInsensitiveCompare("Playing") == .orderedSame

        guard let title = name, !title.isEmpty else {
            if !isPlaying {
                clearCurrentTrackIfApp(.appleMusic)
            }
            return
        }

        let resolvedArtist = artist ?? "Apple Music"
        let duration = durationMs / 1000.0

        let track = NowPlayingTrack(
            app: .appleMusic,
            title: title,
            artist: resolvedArtist,
            album: album,
            duration: duration,
            position: positionSec,
            isPlaying: isPlaying,
            artworkData: currentTrack?.app == .appleMusic ? currentTrack?.artworkData : nil
        )

        updateTrack(track)
        if isPlaying && track.artworkData == nil {
            fetchAppleMusicArtwork()
        }
    }

    public func processSpotifyTrack(
        playerState: String,
        name: String?,
        artist: String?,
        album: String?,
        durationMs: Double,
        positionSec: Double
    ) {
        let isPlaying = playerState.caseInsensitiveCompare("Playing") == .orderedSame

        guard let title = name, !title.isEmpty else {
            if !isPlaying {
                clearCurrentTrackIfApp(.spotify)
            }
            return
        }

        let resolvedArtist = artist ?? "Spotify"
        let duration = durationMs / 1000.0

        let track = NowPlayingTrack(
            app: .spotify,
            title: title,
            artist: resolvedArtist,
            album: album,
            duration: duration,
            position: positionSec,
            isPlaying: isPlaying,
            artworkData: currentTrack?.app == .spotify ? currentTrack?.artworkData : nil
        )

        updateTrack(track)
    }

    private func updateTrack(_ track: NowPlayingTrack) {
        self.currentTrack = track
        ZenithIslandState.shared.nowPlayingTrack = track
    }

    private func clearCurrentTrackIfApp(_ app: NowPlayingApp) {
        if currentTrack?.app == app {
            self.currentTrack = nil
            ZenithIslandState.shared.nowPlayingTrack = nil
        }
    }

    // MARK: - Remote Media Controls

    /// Toggles play/pause state for the active media application or browser video.
    public func togglePlayPause() {
        if MediaRemoteBridge.shared.sendCommand(2) {
            return
        }
        guard let app = currentTrack?.app ?? preferredActiveApp else { return }
        runAppleScript("tell application \"\(app.rawValue)\" to playpause")
    }

    /// Skips to the next track.
    public func nextTrack() {
        if MediaRemoteBridge.shared.sendCommand(4) {
            return
        }
        guard let app = currentTrack?.app ?? preferredActiveApp else { return }
        runAppleScript("tell application \"\(app.rawValue)\" to next track")
    }

    /// Rewinds or skips to the previous track.
    public func previousTrack() {
        if MediaRemoteBridge.shared.sendCommand(5) {
            return
        }
        guard let app = currentTrack?.app ?? preferredActiveApp else { return }
        runAppleScript("tell application \"\(app.rawValue)\" to previous track")
    }

    private var preferredActiveApp: NowPlayingApp? {
        if !NSRunningApplication.runningApplications(withBundleIdentifier: NowPlayingApp.spotify.bundleIdentifier).isEmpty {
            return .spotify
        }
        if !NSRunningApplication.runningApplications(withBundleIdentifier: NowPlayingApp.appleMusic.bundleIdentifier).isEmpty {
            return .appleMusic
        }
        return nil
    }

    private func runAppleScript(_ source: String) {
        Task.detached(priority: .userInitiated) {
            let script = NSAppleScript(source: source)
            var errorInfo: NSDictionary?
            script?.executeAndReturnError(&errorInfo)
        }
    }

    private func fetchAppleMusicArtwork() {
        Task.detached(priority: .utility) { [weak self] in
            let scriptSource = "tell application \"Music\" to get raw data of artwork 1 of current track"
            let script = NSAppleScript(source: scriptSource)
            var errorInfo: NSDictionary?
            if let desc = script?.executeAndReturnError(&errorInfo), desc.descriptorType == typeType || desc.data.count > 100 {
                let data = desc.data
                await MainActor.run {
                    guard let self = self, let current = self.currentTrack, current.app == .appleMusic else { return }
                    let updated = NowPlayingTrack(
                        app: current.app,
                        title: current.title,
                        artist: current.artist,
                        album: current.album,
                        duration: current.duration,
                        position: current.position,
                        isPlaying: current.isPlaying,
                        artworkData: data
                    )
                    self.currentTrack = updated
                    ZenithIslandState.shared.nowPlayingTrack = updated
                }
            }
        }
    }

    private func checkRunningPlayers() {
        let musicRunning = !NSRunningApplication.runningApplications(withBundleIdentifier: NowPlayingApp.appleMusic.bundleIdentifier).isEmpty
        let spotifyRunning = !NSRunningApplication.runningApplications(withBundleIdentifier: NowPlayingApp.spotify.bundleIdentifier).isEmpty

        if !musicRunning && !spotifyRunning && currentTrack == nil {
            ZenithIslandState.shared.nowPlayingTrack = nil
        }
    }
}
