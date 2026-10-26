import Foundation
import AppKit
import Combine

/// Dynamic bridge to macOS private MediaRemote framework for universal browser (Chrome, Safari, Arc, Firefox, etc.)
/// and system media player tracking with zero background CPU polling.
final class MediaRemoteBridge: @unchecked Sendable {
    static let shared = MediaRemoteBridge()

    typealias MRRegisterFunction = @convention(c) (DispatchQueue) -> Void
    typealias MRGetInfoFunction = @convention(c) (DispatchQueue, @escaping (CFDictionary?) -> Void) -> Void
    typealias MRGetPIDFunction = @convention(c) (DispatchQueue, @escaping (pid_t) -> Void) -> Void
    typealias MRSendCommandFunction = @convention(c) (UInt32, AnyObject?) -> Bool

    private var registerFn: MRRegisterFunction?
    private var getInfoFn: MRGetInfoFunction?
    private var getPIDFn: MRGetPIDFunction?
    private var sendCommandFn: MRSendCommandFunction?
    private var isRegistered = false

    init() {
        if let handle = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_NOW) {
            if let symReg = dlsym(handle, "MRMediaRemoteRegisterForNowPlayingNotifications") {
                registerFn = unsafeBitCast(symReg, to: MRRegisterFunction.self)
            }
            if let symInfo = dlsym(handle, "MRMediaRemoteGetNowPlayingInfo") {
                getInfoFn = unsafeBitCast(symInfo, to: MRGetInfoFunction.self)
            }
            if let symPID = dlsym(handle, "MRMediaRemoteGetNowPlayingApplicationPID") {
                getPIDFn = unsafeBitCast(symPID, to: MRGetPIDFunction.self)
            }
            if let symSend = dlsym(handle, "MRMediaRemoteSendCommand") {
                sendCommandFn = unsafeBitCast(symSend, to: MRSendCommandFunction.self)
            }
        }
    }

    func registerForNotifications() {
        guard !isRegistered, let register = registerFn else { return }
        register(DispatchQueue.main)
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

            getInfo(DispatchQueue.main) { dict in
                guard let info = dict as? [String: Any] else {
                    Task { @MainActor in completion(nil) }
                    return
                }

                let title = info["kMRMediaRemoteNowPlayingInfoTitle"] as? String ?? ""
                guard !title.isEmpty else {
                    Task { @MainActor in completion(nil) }
                    return
                }

                let artist = info["kMRMediaRemoteNowPlayingInfoArtist"] as? String ?? appName ?? ""
                let album = info["kMRMediaRemoteNowPlayingInfoAlbum"] as? String
                let duration = info["kMRMediaRemoteNowPlayingInfoDuration"] as? Double ?? 0
                let elapsed = info["kMRMediaRemoteNowPlayingInfoElapsedTime"] as? Double ?? 0
                let rate = info["kMRMediaRemoteNowPlayingInfoPlaybackRate"] as? Double ?? 0
                let isPlaying = rate > 0
                let artworkData = info["kMRMediaRemoteNowPlayingInfoArtworkData"] as? Data

                let resolvedApp = NowPlayingApp.resolve(
                    bundleId: bundleId,
                    title: title,
                    artist: artist
                )

                let track = NowPlayingTrack(
                    app: resolvedApp,
                    title: title,
                    artist: artist.isEmpty ? resolvedApp.displayName : artist,
                    album: (album?.isEmpty ?? true) ? nil : album,
                    duration: duration,
                    position: elapsed,
                    isPlaying: isPlaying,
                    artworkData: artworkData
                )

                Task { @MainActor in
                    completion(track)
                }
            }
        }
    }

    @discardableResult
    func sendCommand(_ command: UInt32) -> Bool {
        guard let send = sendCommandFn else { return false }
        return send(command, nil)
    }
}

/// Concurrency-safe service coordinating Apple Music, Spotify, YouTube, and browser playback telemetry
/// and remote playback controls for Zenith Dynamic Island.
@MainActor
public final class NowPlayingService: ObservableObject {
    public static let shared = NowPlayingService()

    @Published public var currentTrack: NowPlayingTrack?
    @Published public var isMonitoring: Bool = false

    private var observers: [NSObjectProtocol] = []
    private var progressTimer: Task<Void, Never>?

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
        observers.append(musicObserver)

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
        observers.append(spotifyObserver)

        // 3. Observe universal browser & media player state changes via MediaRemote
        MediaRemoteBridge.shared.registerForNotifications()

        let mrInfoObserver = NotificationCenter.default.addObserver(
            forName: NSNotification.Name("kMRMediaRemoteNowPlayingInfoDidChangeNotification"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshMediaRemoteTrack()
            }
        }
        observers.append(mrInfoObserver)

        let mrPlayingObserver = NotificationCenter.default.addObserver(
            forName: NSNotification.Name("kMRMediaRemoteNowPlayingApplicationIsPlayingDidChangeNotification"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshMediaRemoteTrack()
            }
        }
        observers.append(mrPlayingObserver)

        // Initial check for currently running media players & browser media
        refreshMediaRemoteTrack()
        checkRunningPlayers()
    }

    /// Stops media observation and cleans up notification listeners.
    public func stopMonitoring() {
        let center = DistributedNotificationCenter.default()
        for obs in observers {
            center.removeObserver(obs)
            NotificationCenter.default.removeObserver(obs)
        }
        observers.removeAll()
        progressTimer?.cancel()
        progressTimer = nil
        self.isMonitoring = false
        self.currentTrack = nil
        ZenithIslandState.shared.nowPlayingTrack = nil
    }

    /// Refreshes track state from system MediaRemote framework.
    public func refreshMediaRemoteTrack() {
        MediaRemoteBridge.shared.queryNowPlaying { [weak self] track in
            guard let self = self else { return }
            if let track = track {
                if track.isPlaying || self.currentTrack?.id == track.id {
                    self.updateTrack(track)
                }
            } else if self.currentTrack?.app != .appleMusic && self.currentTrack?.app != .spotify {
                self.currentTrack = nil
                ZenithIslandState.shared.nowPlayingTrack = nil
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

        progressTimer?.cancel()
        if track.isPlaying {
            startProgressInterpolation()
        }
    }

    private func clearCurrentTrackIfApp(_ app: NowPlayingApp) {
        if currentTrack?.app == app {
            self.currentTrack = nil
            ZenithIslandState.shared.nowPlayingTrack = nil
            progressTimer?.cancel()
            progressTimer = nil
        }
    }

    // MARK: - Playback Progress Smooth Interpolation

    private func startProgressInterpolation() {
        progressTimer = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard let self = self, let track = self.currentTrack, track.isPlaying else { break }
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
            }
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

        if !musicRunning && !spotifyRunning {
            self.currentTrack = nil
            ZenithIslandState.shared.nowPlayingTrack = nil
        }
    }
}
