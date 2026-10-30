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

    private var registerFn: MRRegisterFunction?
    private var setWantsFn: MRSetWantsFunction?
    private var getInfoFn: MRGetInfoFunction?
    private var getPIDFn: MRGetPIDFunction?
    private var getIsPlayingFn: MRGetIsPlayingFunction?
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

            // The front tab's URL (what tells YouTube or X from a plain browser) comes from a cache that is
            // refreshed in the background, so this callback never waits on an AppleScript round trip.
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

    private static let tabURLCache = TabURLCache()

    private static func fetchActiveBrowserUrl(bundleId: String?) -> String? {
        guard let bundleId = bundleId, BrowserTabProbe.supportsTabLookup(bundleIdentifier: bundleId) else { return nil }
        return tabURLCache.url(for: bundleId)
    }

    /// Last known front-tab URL per browser, refreshed at most every few seconds on a background queue.
    private final class TabURLCache: @unchecked Sendable {
        private let lock = NSLock()
        private var entries: [String: (url: String?, fetchedAt: Date)] = [:]
        private var inFlight: Set<String> = []

        func url(for bundleId: String) -> String? {
            lock.lock()
            let entry = entries[bundleId]
            let isStale = entry.map { Date().timeIntervalSince($0.fetchedAt) > 5 } ?? true
            let shouldRefresh = isStale && !inFlight.contains(bundleId)
            if shouldRefresh { inFlight.insert(bundleId) }
            lock.unlock()

            if shouldRefresh {
                DispatchQueue.global(qos: .utility).async { [self] in
                    let url = BrowserTabProbe.activeTab(bundleIdentifier: bundleId, runner: SystemCommand.processRunner)?.url
                    lock.lock()
                    entries[bundleId] = (url, Date())
                    inFlight.remove(bundleId)
                    lock.unlock()
                }
            }
            return entry?.url
        }
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

    private let islandState: ZenithIslandState
    private let playingApplicationProvider: @Sendable () -> PlayingApplication?
    private let commandRunner: SystemCommandRunner
    private let mediaKeys: MediaKeyPosting
    private let scriptRunner: @Sendable (String) -> Void

    /// Front-tab lookups are slow (an AppleScript round trip), so the last result is reused for a few seconds and
    /// at most one lookup is ever in flight.
    private var tabCache: (bundleId: String, tab: BrowserTab?, fetchedAt: Date)?
    private var pendingTabFetch: Task<Void, Never>?
    private static let tabCacheLifetime: TimeInterval = 4

    // CoreAudio hardware listener
    private var coreAudioDeviceID: AudioDeviceID = 0
    private var coreAudioPropertyAddress: AudioObjectPropertyAddress?
    private var coreAudioListenerBlock: AudioObjectPropertyListenerBlock?

    /// Watches which device is the default output, so the listener above follows it (AirPods, a dock, HDMI…).
    private var defaultDeviceAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    private var defaultDeviceListenerBlock: AudioObjectPropertyListenerBlock?

    /// - Parameters:
    ///   - islandState: Where the current track is published.
    ///   - playingApplicationProvider: Which app is playing audio; tests supply a stand-in for the system's answer.
    ///   - commandRunner: Runs `osascript` for tab lookups.
    ///   - mediaKeys: Posts play/next/previous key presses for apps that are not controlled by AppleScript.
    ///   - scriptRunner: Runs AppleScript commands for Music and Spotify.
    public init(
        islandState: ZenithIslandState = .shared,
        playingApplicationProvider: @escaping @Sendable () -> PlayingApplication? = {
            PlaybackAssertionProbe.playingApplication(excluding: [
                NowPlayingApp.appleMusic.bundleIdentifier,
                NowPlayingApp.spotify.bundleIdentifier
            ])
        },
        commandRunner: @escaping SystemCommandRunner = SystemCommand.processRunner,
        mediaKeys: MediaKeyPosting = SystemMediaKeys(),
        scriptRunner: @escaping @Sendable (String) -> Void = NowPlayingService.executeAppleScript
    ) {
        self.islandState = islandState
        self.playingApplicationProvider = playingApplicationProvider
        self.commandRunner = commandRunner
        self.mediaKeys = mediaKeys
        self.scriptRunner = scriptRunner
    }

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
        clearTrack()
    }

    /// Refreshes the current track: first from the system's Now Playing (MediaRemote, which only answers on macOS
    /// before 15.4), then from which app is playing audio.
    public func refreshMediaRemoteTrack() {
        MediaRemoteBridge.shared.queryNowPlaying { [weak self] track in
            guard let self = self else { return }
            if let track = track, track.isPlaying || self.currentTrack?.id == track.id {
                self.updateTrack(track)
                return
            }
            self.refreshFromPlaybackAssertions()
        }
    }

    /// Detects audio from an app that publishes no track information of its own (browsers above all).
    func refreshFromPlaybackAssertions() {
        // Apple Music and Spotify report precisely through their own notifications; audio from another app must not
        // replace a track they are playing.
        if let current = currentTrack, current.isPlaying, current.app == .appleMusic || current.app == .spotify {
            return
        }

        guard let playing = playingApplicationProvider() else {
            // Audio stopped: drop a track that came from detection (never one of Music/Spotify's own).
            if let current = currentTrack, current.app != .appleMusic, current.app != .spotify {
                clearTrack()
            }
            return
        }

        let bundleId = playing.bundleIdentifier ?? ""
        let cachedTab: BrowserTab?
        if let cache = tabCache, cache.bundleId == bundleId {
            cachedTab = cache.tab
        } else {
            cachedTab = nil
        }
        updateTrackIfChanged(Self.browserTrack(for: playing, tab: cachedTab))

        refreshTabIfNeeded(for: playing)
    }

    private func refreshTabIfNeeded(for playing: PlayingApplication) {
        guard let bundleId = playing.bundleIdentifier,
              BrowserTabProbe.supportsTabLookup(bundleIdentifier: bundleId),
              pendingTabFetch == nil else { return }
        if let cache = tabCache, cache.bundleId == bundleId,
           Date().timeIntervalSince(cache.fetchedAt) < Self.tabCacheLifetime {
            return
        }

        let runner = commandRunner
        pendingTabFetch = Task.detached(priority: .utility) { [weak self] in
            let tab = BrowserTabProbe.activeTab(bundleIdentifier: bundleId, runner: runner)
            await MainActor.run { [weak self] in
                guard let self = self else { return }
                self.pendingTabFetch = nil
                self.tabCache = (bundleId, tab, Date())
                // Show the title right away, but only if this browser is still the one playing.
                if let current = self.currentTrack, current.isPlaying, current.app != .appleMusic, current.app != .spotify,
                   let playing = self.playingApplicationProvider(), playing.bundleIdentifier == bundleId {
                    self.updateTrackIfChanged(Self.browserTrack(for: playing, tab: tab))
                }
            }
        }
    }

    /// Waits for the tab lookup in flight, if any. For tests.
    func waitForTabLookup() async {
        await pendingTabFetch?.value
    }

    /// The track shown for audio from an app that reports nothing itself. Without a readable tab on a media site it
    /// says only which app is playing, rather than passing off an unrelated tab's title as the media.
    nonisolated static func browserTrack(for playing: PlayingApplication, tab: BrowserTab?) -> NowPlayingTrack {
        if let tab = tab, BrowserTabProbe.isMediaSite(url: tab.url) {
            let resolved = NowPlayingApp.resolve(bundleId: playing.bundleIdentifier, title: nil, artist: nil, activeUrl: tab.url)
            let cleaned = BrowserTabProbe.cleanTitle(tab.title)
            let title: String
            if cleaned.isEmpty || BrowserTabProbe.genericTitles.contains(cleaned.lowercased()) {
                title = resolved == .xTwitter ? "Video on X" : "\(resolved.displayName) video"
            } else {
                title = cleaned
            }
            let artist = (resolved == .youtube || resolved == .xTwitter) ? resolved.displayName : playing.name
            return NowPlayingTrack(app: resolved, title: title, artist: artist, duration: 0, position: 0, isPlaying: true)
        }

        let resolved = NowPlayingApp.resolve(bundleId: playing.bundleIdentifier, title: nil, artist: nil)
        return NowPlayingTrack(app: resolved, title: playing.name, artist: "Playing audio", duration: 0, position: 0, isPlaying: true)
    }

    // MARK: - CoreAudio Hardware Output Listener

    private func setupCoreAudioListener() {
        // First, follow changes of the default output device; then listen on the device that is current now.
        let deviceChanged: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor [weak self] in
                self?.defaultOutputDeviceChanged()
            }
        }
        defaultDeviceListenerBlock = deviceChanged
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &defaultDeviceAddress,
            DispatchQueue.main,
            deviceChanged
        )

        registerOutputDeviceListener()
    }

    /// The listener was attached to whichever device was default at launch and stayed there after the output changed,
    /// so audio start/stop on the new device went unnoticed until the next poll.
    private func defaultOutputDeviceChanged() {
        unregisterOutputDeviceListener()
        registerOutputDeviceListener()
        refreshMediaRemoteTrack()
    }

    private func registerOutputDeviceListener() {
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
        unregisterOutputDeviceListener()
        if let block = defaultDeviceListenerBlock {
            AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject),
                &defaultDeviceAddress,
                DispatchQueue.main,
                block
            )
            defaultDeviceListenerBlock = nil
        }
    }

    private func unregisterOutputDeviceListener() {
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
                    self.updateTrack(updated)
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
        islandState.nowPlayingTrack = track
    }

    /// Publishes a track only when it differs, so the island is not redrawn on every poll.
    private func updateTrackIfChanged(_ track: NowPlayingTrack) {
        if currentTrack != track {
            updateTrack(track)
        }
    }

    private func clearTrack() {
        self.currentTrack = nil
        islandState.nowPlayingTrack = nil
    }

    private func clearCurrentTrackIfApp(_ app: NowPlayingApp) {
        if currentTrack?.app == app {
            clearTrack()
        }
    }

    // MARK: - Remote Media Controls

    /// Toggles play/pause state for the active media application or browser video.
    public func togglePlayPause() {
        send(.playPause, musicCommand: "playpause")
    }

    /// Skips to the next track.
    public func nextTrack() {
        send(.next, musicCommand: "next track")
    }

    /// Rewinds or skips to the previous track.
    public func previousTrack() {
        send(.previous, musicCommand: "previous track")
    }

    /// Music and Spotify are told directly over AppleScript. Anything else (a browser tab) gets the hardware media
    /// key, which macOS delivers to the app that is playing without raising it or typing into a focused field.
    private func send(_ key: MediaKey, musicCommand: String) {
        switch currentTrack?.app ?? preferredActiveApp {
        case .some(let app) where app == .appleMusic || app == .spotify:
            scriptRunner("tell application \"\(app.rawValue)\" to \(musicCommand)")
        case .some:
            mediaKeys.post(key)
        case .none:
            // Nothing is playing: a media key now would only make macOS launch Music.
            break
        }
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

    /// Runs AppleScript off the calling thread.
    public nonisolated static func executeAppleScript(_ source: String) {
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
                    self.updateTrack(updated)
                }
            }
        }
    }

    private func checkRunningPlayers() {
        let musicRunning = !NSRunningApplication.runningApplications(withBundleIdentifier: NowPlayingApp.appleMusic.bundleIdentifier).isEmpty
        let spotifyRunning = !NSRunningApplication.runningApplications(withBundleIdentifier: NowPlayingApp.spotify.bundleIdentifier).isEmpty

        if !musicRunning && !spotifyRunning && currentTrack == nil {
            islandState.nowPlayingTrack = nil
        }
    }
}
