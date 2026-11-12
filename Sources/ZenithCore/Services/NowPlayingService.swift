import Foundation
import AppKit
import Combine

/// Concurrency-safe service coordinating Apple Music, Spotify, YouTube, X, and browser playback telemetry
/// and remote playback controls for Zenith Dynamic Island.
@MainActor
public final class NowPlayingService: ObservableObject {
    public static let shared = NowPlayingService(nowPlayingSource: PerlNowPlayingSource.bundled())

    @Published public var currentTrack: NowPlayingTrack?
    @Published public var isMonitoring: Bool = false

    private var distributedObservers: [NSObjectProtocol] = []
    private var adaptiveTicker: Task<Void, Never>?

    private let islandState: ZenithIslandState
    private let mediaKeys: MediaKeyPosting
    private let scriptRunner: @Sendable (String) -> Void

    /// The system's Now Playing read through the perl adapter: the only source for anything but Music and Spotify,
    /// which also report through their own notifications.
    private let nowPlayingSource: NowPlayingSource?
    private var adapterIsLive = false
    private var adapterSnapshot: NowPlayingSnapshot?
    /// False after `stopMonitoring`, so a message that was already on its way does not bring a track back.
    private var acceptsAdapterMessages = true

    /// - Parameters:
    ///   - islandState: Where the current track is published.
    ///   - mediaKeys: Posts play/next/previous key presses when the adapter cannot pass the command on.
    ///   - scriptRunner: Runs AppleScript commands for Music and Spotify.
    ///   - nowPlayingSource: The system's Now Playing feed; nil (the default) leaves only Music and Spotify.
    public init(
        islandState: ZenithIslandState = .shared,
        mediaKeys: MediaKeyPosting = SystemMediaKeys(),
        scriptRunner: @escaping @Sendable (String) -> Void = NowPlayingService.executeAppleScript,
        nowPlayingSource: NowPlayingSource? = nil
    ) {
        self.islandState = islandState
        self.mediaKeys = mediaKeys
        self.scriptRunner = scriptRunner
        self.nowPlayingSource = nowPlayingSource
    }

    /// Starts observing Music's and Spotify's notifications and the system's Now Playing feed. Nothing is polled.
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

        // 3. The system's Now Playing, for every other app
        acceptsAdapterMessages = true
        nowPlayingSource?.start { [weak self] message in
            Task { @MainActor [weak self] in
                self?.handleAdapterMessage(message)
            }
        }

        // 4. Move the position of a playing track forward once a second
        startAdaptiveTicker()
    }

    /// Stops media observation and cleans up notification listeners.
    public func stopMonitoring() {
        let center = DistributedNotificationCenter.default()
        for obs in distributedObservers {
            center.removeObserver(obs)
        }
        distributedObservers.removeAll()

        nowPlayingSource?.stop()
        acceptsAdapterMessages = false
        adapterIsLive = false
        adapterSnapshot = nil
        adaptiveTicker?.cancel()
        adaptiveTicker = nil
        self.isMonitoring = false
        clearTrack()
    }

    // MARK: - Now Playing adapter

    /// Takes one message from the adapter feed. Internal so tests can deliver messages without a thread hop.
    func handleAdapterMessage(_ message: NowPlayingAdapterMessage) {
        guard acceptsAdapterMessages else { return }
        switch message {
        case .snapshot(let snapshot):
            adapterIsLive = true
            adapterSnapshot = snapshot
            applyAdapterSnapshot()
        case .commandResult(let key, let sent):
            // The system took no command for this player; the hardware key is the other way to reach it.
            if !sent { postMediaKey(key) }
        case .unavailable:
            adapterIsLive = false
            adapterSnapshot = nil
            applyAdapterSnapshot()
        }
    }

    /// Shows the adapter's last reading, moved forward to now. A reading with nothing to show (no session, no
    /// title, or another song sitting paused) removes a track that came from the adapter. A track Music or Spotify
    /// reported themselves is theirs to remove.
    private func applyAdapterSnapshot() {
        let bundleId = adapterSnapshot.flatMap { snapshot in
            snapshot.applicationBundleIdentifier
                ?? snapshot.processID.flatMap { NSRunningApplication(processIdentifier: $0)?.bundleIdentifier }
        }
        guard let snapshot = adapterSnapshot,
              let track = Self.adapterTrack(for: snapshot, bundleIdentifier: bundleId, now: Date()),
              track.isPlaying || currentTrack?.id == track.id else {
            if let current = currentTrack, current.app != .appleMusic, current.app != .spotify {
                clearTrack()
            }
            return
        }
        if track.isPlaying {
            // `updateTrackIfChanged` ignores a position that moved by a second, and the progress bar is driven by
            // exactly that.
            updateTrack(track)
        } else {
            updateTrackIfChanged(track)
        }
    }

    /// The track for a reading of the system's Now Playing session, or nil when it names no title.
    nonisolated static func adapterTrack(
        for snapshot: NowPlayingSnapshot,
        bundleIdentifier: String?,
        now: Date
    ) -> NowPlayingTrack? {
        guard let title = snapshot.title else { return nil }
        let app = NowPlayingApp.resolve(bundleId: bundleIdentifier, title: title, artist: snapshot.artist)
        return NowPlayingTrack(
            app: app,
            title: title,
            artist: snapshot.artist ?? app.displayName,
            album: snapshot.album,
            duration: snapshot.duration,
            position: snapshot.position(at: now),
            isPlaying: snapshot.isPlaying,
            artworkData: snapshot.artworkData,
            // A player that does not say what it takes keeps its buttons, and gets no seeking.
            canSkipNext: snapshot.canSkipNext ?? true,
            canSkipPrevious: snapshot.canSkipPrevious ?? true,
            canSeek: (snapshot.canSeek ?? false) && snapshot.duration > 0
        )
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
                    self.updateTrack(track.replacing(position: min(track.position + 1.0, track.duration)))
                } else if self.adapterIsLive {
                    self.applyAdapterSnapshot()
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
            artworkData: currentTrack?.app == .appleMusic ? currentTrack?.artworkData : nil,
            canSeek: duration > 0
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
            artworkData: currentTrack?.app == .spotify ? currentTrack?.artworkData : nil,
            canSeek: duration > 0
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
        guard currentTrack?.canSkipNext != false else { return }
        send(.next, musicCommand: "next track")
    }

    /// Rewinds or skips to the previous track.
    public func previousTrack() {
        guard currentTrack?.canSkipPrevious != false else { return }
        send(.previous, musicCommand: "previous track")
    }

    /// Moves the current track to `position` seconds, if its player takes a position. Music and Spotify are told
    /// over AppleScript, anything else through the adapter. The island shows the new position at once.
    public func seek(to position: TimeInterval) {
        guard let track = currentTrack, track.canSeek, track.duration > 0, position.isFinite else { return }
        let target = min(max(0, position), track.duration)
        if track.app == .appleMusic || track.app == .spotify {
            let seconds = String(format: "%.2f", locale: Locale(identifier: "en_US_POSIX"), target)
            scriptRunner("tell application \"\(track.app.rawValue)\" to set player position to \(seconds)")
        } else {
            guard adapterIsLive, nowPlayingSource?.seek(to: target) == true else { return }
            // Until the player reports its new position, count on from here rather than from the old reading.
            adapterSnapshot?.elapsed = target
            adapterSnapshot?.receivedAt = Date()
        }
        updateTrack(track.replacing(position: target))
    }

    /// Music and Spotify are told directly over AppleScript. Anything else (a browser tab) is sent the command
    /// through the adapter, and the hardware media key only when that is not possible.
    private func send(_ key: MediaKey, musicCommand: String) {
        switch currentTrack?.app ?? preferredActiveApp {
        case .some(let app) where app == .appleMusic || app == .spotify:
            scriptRunner("tell application \"\(app.rawValue)\" to \(musicCommand)")
        case .some:
            // The adapter hands the command to the playing app through MediaRemote, which needs no permission.
            // If the system refuses it, `.commandResult` arrives and the hardware key is posted then.
            if adapterIsLive, adapterSnapshot != nil, nowPlayingSource?.send(key) == true { return }
            postMediaKey(key)
        case .none:
            // Nothing is playing: a media key now would only make macOS launch Music.
            break
        }
    }

    private func postMediaKey(_ key: MediaKey) {
        // macOS drops a synthetic key from an app without Accessibility permission, with no error. Say so,
        // otherwise the buttons just seem dead.
        if !mediaKeys.post(key) {
            islandState.triggerAlert(
                icon: "hand.raised.fill",
                title: String(localized: "Allow Accessibility"),
                subtitle: String(localized: "Privacy & Security › Accessibility › Zenith"),
                duration: 4,
                tintColor: .orange
            )
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
        // This task runs on the main actor; only the AppleScript call leaves it, and it hands back plain data.
        // (Capturing `self` into a detached task and hopping back with `MainActor.run` is rejected by the Swift 6.1
        // compiler as a possible data race.)
        Task { [weak self] in
            let data = await Task.detached(priority: .utility) { Self.readAppleMusicArtwork() }.value
            guard let self, let data, let current = self.currentTrack, current.app == .appleMusic else { return }
            self.updateTrack(current.replacing(artworkData: .some(data)))
        }
    }

    /// Asks Music for the current track's artwork. Blocks on an Apple Event, so call it off the main thread.
    nonisolated private static func readAppleMusicArtwork() -> Data? {
        let script = NSAppleScript(source: "tell application \"Music\" to get raw data of artwork 1 of current track")
        var errorInfo: NSDictionary?
        guard let desc = script?.executeAndReturnError(&errorInfo),
              desc.descriptorType == typeType || desc.data.count > 100 else { return nil }
        return desc.data
    }
}
