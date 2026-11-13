import Testing
import Foundation
@testable import ZenithCore

/// Records what the service does to control playback.
final class PlaybackFixture: @unchecked Sendable {
    private let lock = NSLock()
    private var _keys: [MediaKey] = []
    private var _keysAllowed = true
    private var _scripts: [String] = []

    var keys: [MediaKey] { lock.withLock { _keys } }
    /// False stands in for a missing Accessibility permission: the key press is dropped.
    var keysAllowed: Bool {
        get { lock.withLock { _keysAllowed } }
        set { lock.withLock { _keysAllowed = newValue } }
    }
    var scripts: [String] { lock.withLock { _scripts } }

    struct Keys: MediaKeyPosting {
        let fixture: PlaybackFixture
        func post(_ key: MediaKey) -> Bool {
            fixture.lock.withLock {
                fixture._keys.append(key)
                return fixture._keysAllowed
            }
        }
    }
    var mediaKeys: MediaKeyPosting { Keys(fixture: self) }

    var scriptRunner: @Sendable (String) -> Void {
        { [self] source in lock.withLock { _scripts.append(source) } }
    }
}

@Suite("Now Playing Adapter Suite")
struct NowPlayingAdapterTests {

    private func line(_ json: String) -> Data { Data(json.utf8) }

    // MARK: - The adapter's lines

    @Test("NPA-01: A line with a track becomes a snapshot; text is trimmed and empty fields are dropped")
    func testSnapshotParsing() throws {
        let now = Date(timeIntervalSince1970: 1_000)
        let artwork = Data([1, 2, 3, 4])
        let json = """
        {"pid":4242,"bundleID":"com.apple.WebKit.GPU","parentBundleID":"com.apple.Safari","title":"  Great Song ",\
        "artist":"Someone","album":"","duration":200.5,"elapsed":12.25,"rate":1,"playing":true,\
        "artwork":"\(artwork.base64EncodedString())"}
        """
        let message = try #require(NowPlayingAdapterMessage.parse(line: line(json), previousArtwork: nil, now: now))
        guard case .snapshot(let parsed) = message, let snapshot = parsed else {
            Issue.record("expected a snapshot, got \(message)")
            return
        }
        #expect(snapshot.processID == 4242)
        #expect(snapshot.applicationBundleIdentifier == "com.apple.Safari")
        #expect(snapshot.title == "Great Song" && snapshot.artist == "Someone" && snapshot.album == nil)
        #expect(snapshot.duration == 200.5 && snapshot.elapsed == 12.25 && snapshot.isPlaying)
        #expect(snapshot.artworkData == artwork && snapshot.receivedAt == now)
    }

    @Test("NPA-02: Nothing playing, errors, command answers and junk are told apart")
    func testOtherLines() {
        #expect(NowPlayingAdapterMessage.parse(line: line(#"{"playing":false}"#), previousArtwork: nil) == .snapshot(nil))
        #expect(NowPlayingAdapterMessage.parse(line: line(#"{"error":"timeout"}"#), previousArtwork: nil) == .unavailable)
        #expect(NowPlayingAdapterMessage.parse(line: line(#"{"command":"toggle","sent":true}"#), previousArtwork: nil)
                == .commandResult(.playPause, sent: true))
        #expect(NowPlayingAdapterMessage.parse(line: line(#"{"command":"next","sent":false}"#), previousArtwork: nil)
                == .commandResult(.next, sent: false))
        #expect(NowPlayingAdapterMessage.parse(line: line(#"{"command":"eject","sent":true}"#), previousArtwork: nil) == nil)
        #expect(NowPlayingAdapterMessage.parse(line: line("not json"), previousArtwork: nil) == nil)
        #expect(NowPlayingAdapterMessage.parse(line: line("[1,2]"), previousArtwork: nil) == nil)
    }

    @Test("NPA-03: An unchanged picture is taken from the previous snapshot, and a missing one clears it")
    func testArtworkReuse() {
        let previous = Data([9, 9, 9])
        let same = NowPlayingAdapterMessage.parse(
            line: line(#"{"pid":1,"title":"A","playing":true,"artworkSame":true}"#), previousArtwork: previous)
        let none = NowPlayingAdapterMessage.parse(
            line: line(#"{"pid":1,"title":"A","playing":true}"#), previousArtwork: previous)
        guard case .snapshot(let withArtwork) = same, case .snapshot(let withoutArtwork) = none else {
            Issue.record("expected two snapshots")
            return
        }
        #expect(withArtwork?.artworkData == previous)
        #expect(withoutArtwork != nil && withoutArtwork?.artworkData == nil)
    }

    @Test("NPA-04: Every media key has a command word that parses back to it")
    func testCommandWords() {
        for key in [MediaKey.playPause, .next, .previous] {
            #expect(MediaKey(adapterCommand: key.adapterCommand) == key)
        }
        #expect(MediaKey(adapterCommand: "") == nil)
    }

    @Test("NPA-05: Bytes are cut into lines across chunks, and an over-long line is dropped without losing the next")
    func testLineFramer() {
        var framer = NowPlayingLineFramer(maximumLineLength: 10)
        #expect(framer.append(Data("ab".utf8)).isEmpty)
        #expect(framer.append(Data("c\nde\n\nf".utf8)) == [Data("abc".utf8), Data("de".utf8)])
        #expect(framer.append(Data("g\n".utf8)) == [Data("fg".utf8)])

        // Too long, in one chunk and spread over several.
        #expect(framer.append(Data("01234567890123\nok\n".utf8)) == [Data("ok".utf8)])
        #expect(framer.append(Data("0123456".utf8)).isEmpty)
        #expect(framer.append(Data("7890123".utf8)).isEmpty)
        #expect(framer.append(Data("still the long one\nfine\n".utf8)) == [Data("fine".utf8)])
    }

    @Test("NPA-06: A playing song moves forward from its reading and stops at its end; a paused one stays")
    func testPositionExtrapolation() {
        let start = Date(timeIntervalSince1970: 500)
        let playing = NowPlayingSnapshot(title: "A", duration: 100, elapsed: 10, rate: 1, isPlaying: true, receivedAt: start)
        #expect(playing.position(at: start.addingTimeInterval(5)) == 15)
        #expect(playing.position(at: start.addingTimeInterval(500)) == 100)
        #expect(playing.position(at: start.addingTimeInterval(-5)) == 10)      // a clock that went back

        let fast = NowPlayingSnapshot(title: "A", duration: 100, elapsed: 10, rate: 2, isPlaying: true, receivedAt: start)
        #expect(fast.position(at: start.addingTimeInterval(5)) == 20)

        // Some players report playing with a rate of 0; the song still moves.
        let noRate = NowPlayingSnapshot(title: "A", duration: 0, elapsed: 10, rate: 0, isPlaying: true, receivedAt: start)
        #expect(noRate.position(at: start.addingTimeInterval(5)) == 15)

        let paused = NowPlayingSnapshot(title: "A", duration: 100, elapsed: 10, rate: 1, isPlaying: false, receivedAt: start)
        #expect(paused.position(at: start.addingTimeInterval(60)) == 10)
    }

    // MARK: - From a reading to a track

    @Test("NPA-07: The track takes the session's own title and the app it names")
    func testAdapterTrack() throws {
        let now = Date()
        let snapshot = NowPlayingSnapshot(
            processID: 100, bundleIdentifier: "com.google.Chrome", title: "Great Song", artist: "A Channel",
            duration: 200, elapsed: 30, isPlaying: true, receivedAt: now)

        let track = try #require(NowPlayingService.adapterTrack(for: snapshot, bundleIdentifier: "com.google.Chrome", now: now))
        #expect(track.app == .chrome && track.title == "Great Song" && track.artist == "A Channel")
        #expect(track.duration == 200 && track.position == 30 && track.isPlaying)

        var untitled = snapshot
        untitled.title = nil
        #expect(NowPlayingService.adapterTrack(for: untitled, bundleIdentifier: "com.google.Chrome", now: now) == nil)

        var noArtist = snapshot
        noArtist.artist = nil
        #expect(NowPlayingService.adapterTrack(for: noArtist, bundleIdentifier: "org.mozilla.firefox", now: now)?
            .artist == "Firefox")
    }

    // MARK: - The service

    @MainActor
    private func makeService(
        _ fixture: PlaybackFixture,
        source: MockNowPlayingSource
    ) -> (NowPlayingService, ZenithIslandState) {
        let island = ZenithIslandState()
        let service = NowPlayingService(
            islandState: island,
            mediaKeys: fixture.mediaKeys,
            scriptRunner: fixture.scriptRunner,
            nowPlayingSource: source
        )
        return (service, island)
    }

    private static func firefoxSong(title: String = "Great Song", playing: Bool = true) -> NowPlayingSnapshot {
        NowPlayingSnapshot(
            processID: 102, bundleIdentifier: "org.mozilla.firefox", title: title, artist: "A Band",
            duration: 180, elapsed: 20, isPlaying: playing)
    }

    @Test("NPA-08: A reading from the adapter is shown with its own title, for a browser that has no AppleScript too")
    @MainActor
    func testSnapshotReachesIsland() {
        let fixture = PlaybackFixture()
        let (service, island) = makeService(fixture, source: MockNowPlayingSource())

        service.handleAdapterMessage(.snapshot(Self.firefoxSong()))
        #expect(island.nowPlayingTrack?.title == "Great Song")
        #expect(island.nowPlayingTrack?.artist == "A Band")
        #expect(island.nowPlayingTrack?.app == .firefox)
        #expect(island.nowPlayingTrack?.duration == 180)
    }

    @Test("NPA-09: Pausing keeps the same song on the island as paused; a different paused song is not brought up")
    @MainActor
    func testPausedReadings() {
        let fixture = PlaybackFixture()
        let (service, island) = makeService(fixture, source: MockNowPlayingSource())

        service.handleAdapterMessage(.snapshot(Self.firefoxSong()))
        service.handleAdapterMessage(.snapshot(Self.firefoxSong(playing: false)))
        #expect(island.nowPlayingTrack?.title == "Great Song")
        #expect(island.nowPlayingTrack?.isPlaying == false)

        // Another song sitting paused: nothing to show.
        service.handleAdapterMessage(.snapshot(Self.firefoxSong(title: "Old Song", playing: false)))
        #expect(island.nowPlayingTrack == nil)
    }

    @Test("NPA-10: When the session ends or loses its title, the track goes")
    @MainActor
    func testEmptyReadingClearsTheTrack() {
        let fixture = PlaybackFixture()
        let (service, island) = makeService(fixture, source: MockNowPlayingSource())

        service.handleAdapterMessage(.snapshot(Self.firefoxSong()))
        service.handleAdapterMessage(.snapshot(nil))
        #expect(island.nowPlayingTrack == nil && service.currentTrack == nil)

        service.handleAdapterMessage(.snapshot(Self.firefoxSong()))
        var untitled = Self.firefoxSong()
        untitled.title = nil
        service.handleAdapterMessage(.snapshot(untitled))
        #expect(island.nowPlayingTrack == nil)
    }

    @Test("NPA-11: A reading with nothing to show never removes a track Music or Spotify reported themselves")
    @MainActor
    func testMusicAppsKeepTheirTrack() {
        let fixture = PlaybackFixture()
        let (service, island) = makeService(fixture, source: MockNowPlayingSource())

        service.processSpotifyTrack(playerState: "Playing", name: "Song", artist: "Artist", album: nil, durationMs: 200_000, positionSec: 5)
        service.handleAdapterMessage(.snapshot(nil))
        #expect(island.nowPlayingTrack?.app == .spotify)
        service.handleAdapterMessage(.snapshot(Self.firefoxSong(title: "Old Song", playing: false)))
        #expect(island.nowPlayingTrack?.app == .spotify)
        service.handleAdapterMessage(.unavailable)
        #expect(island.nowPlayingTrack?.title == "Song")

        // A browser that starts playing does take over, as the system's session says.
        service.handleAdapterMessage(.snapshot(Self.firefoxSong()))
        #expect(island.nowPlayingTrack?.app == .firefox)
    }

    @Test("NPA-12: Controls go through the adapter for its tracks, and to AppleScript for Music as before")
    @MainActor
    func testControlsUseTheAdapter() {
        let fixture = PlaybackFixture()
        let source = MockNowPlayingSource()
        let (service, _) = makeService(fixture, source: source)

        // Nothing playing: nothing is sent (a media key would launch Music).
        service.togglePlayPause()
        #expect(source.sentKeys.isEmpty && fixture.keys.isEmpty && fixture.scripts.isEmpty)

        service.handleAdapterMessage(.snapshot(Self.firefoxSong()))
        service.togglePlayPause()
        service.nextTrack()
        service.previousTrack()
        #expect(source.sentKeys == [.playPause, .next, .previous])
        #expect(fixture.keys.isEmpty)

        service.processAppleMusicTrack(playerState: "Playing", name: "Song", artist: "Artist", album: nil,
                                       durationMs: 200_000, positionSec: 0)
        service.togglePlayPause()
        #expect(source.sentKeys.count == 3)
        #expect(fixture.scripts == ["tell application \"Music\" to playpause"])
    }

    @Test("NPA-13: A command the adapter cannot take, or the system refuses, falls back to the media key")
    @MainActor
    func testControlFallback() {
        let fixture = PlaybackFixture()
        let source = MockNowPlayingSource()
        let (service, island) = makeService(fixture, source: source)
        service.handleAdapterMessage(.snapshot(Self.firefoxSong()))

        // The system answered that it sent nothing.
        service.togglePlayPause()
        #expect(fixture.keys.isEmpty)
        service.handleAdapterMessage(.commandResult(.playPause, sent: false))
        #expect(fixture.keys == [.playPause])
        service.handleAdapterMessage(.commandResult(.next, sent: true))
        #expect(fixture.keys == [.playPause])

        // The watcher is gone.
        source.acceptsCommands = false
        service.nextTrack()
        #expect(fixture.keys == [.playPause, .next])

        // And the key itself needs Accessibility, which is still explained.
        fixture.keysAllowed = false
        service.previousTrack()
        #expect(island.activeAlert?.title == "Allow Accessibility")
    }

    @Test("NPA-14: When the adapter stops answering, its track is not kept, and messages after a stop are ignored")
    @MainActor
    func testUnavailableAdapter() {
        let fixture = PlaybackFixture()
        let source = MockNowPlayingSource()
        let (service, island) = makeService(fixture, source: source)
        service.handleAdapterMessage(.snapshot(Self.firefoxSong()))
        #expect(island.nowPlayingTrack?.title == "Great Song")

        service.handleAdapterMessage(.unavailable)
        #expect(island.nowPlayingTrack == nil)

        service.stopMonitoring()
        service.handleAdapterMessage(.snapshot(Self.firefoxSong()))
        #expect(island.nowPlayingTrack == nil)
    }

    @Test("NPA-15: The adapter library is looked for in the bundle's Frameworks, then beside the executable")
    func testLibraryLocation() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("npa-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let app = root.appendingPathComponent("Fake.app")
        let macOS = app.appendingPathComponent("Contents/MacOS")
        let frameworks = app.appendingPathComponent("Contents/Frameworks")
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: frameworks, withIntermediateDirectories: true)
        try Data().write(to: macOS.appendingPathComponent("Fake"))
        try Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <plist version="1.0"><dict><key>CFBundleExecutable</key><string>Fake</string>\
        <key>CFBundleIdentifier</key><string>test.zenith.fake</string></dict></plist>
        """.utf8).write(to: app.appendingPathComponent("Contents/Info.plist"))
        let bundle = try #require(Bundle(url: app))

        #expect(PerlNowPlayingSource.libraryLocation(bundle: bundle, fileManager: .default) == nil)

        let beside = macOS.appendingPathComponent(PerlNowPlayingSource.libraryName)
        try Data().write(to: beside)
        #expect(PerlNowPlayingSource.libraryLocation(bundle: bundle, fileManager: .default)?.lastPathComponent
                == PerlNowPlayingSource.libraryName)
        #expect(PerlNowPlayingSource.libraryLocation(bundle: bundle, fileManager: .default)?
            .deletingLastPathComponent().lastPathComponent == "MacOS")

        try Data().write(to: frameworks.appendingPathComponent(PerlNowPlayingSource.libraryName))
        #expect(PerlNowPlayingSource.libraryLocation(bundle: bundle, fileManager: .default)?
            .deletingLastPathComponent().lastPathComponent == "Frameworks")
    }

    // MARK: - What the player takes

    @Test("NPA-16: The adapter's command flags reach the track; a player that says nothing keeps its buttons")
    func testCapabilityFlags() throws {
        let now = Date()
        let line = Data(#"{"pid":1,"title":"A","duration":100,"playing":true,"canNext":false,"canPrevious":false,"canSeek":true}"#.utf8)
        guard case .snapshot(let parsed) = NowPlayingAdapterMessage.parse(line: line, previousArtwork: nil, now: now),
              let snapshot = parsed else {
            Issue.record("expected a snapshot")
            return
        }
        let video = try #require(NowPlayingService.adapterTrack(for: snapshot, bundleIdentifier: "com.google.Chrome", now: now))
        #expect(!video.canSkipNext && !video.canSkipPrevious && video.canSeek)

        let silent = try #require(NowPlayingService.adapterTrack(
            for: NowPlayingSnapshot(title: "A", duration: 100), bundleIdentifier: nil, now: now))
        #expect(silent.canSkipNext && silent.canSkipPrevious && !silent.canSeek)

        // Seeking needs a length to seek within.
        let live = try #require(NowPlayingService.adapterTrack(
            for: NowPlayingSnapshot(title: "A", duration: 0, canSeek: true), bundleIdentifier: nil, now: now))
        #expect(!live.canSeek)
    }

    @Test("NPA-17: Skips the player does not take are not sent at all")
    @MainActor
    func testUnsupportedSkipsAreNotSent() {
        let fixture = PlaybackFixture()
        let source = MockNowPlayingSource()
        let (service, _) = makeService(fixture, source: source)
        var video = Self.firefoxSong()
        video.canSkipNext = false
        video.canSkipPrevious = false
        service.handleAdapterMessage(.snapshot(video))

        service.nextTrack()
        service.previousTrack()
        service.togglePlayPause()
        #expect(source.sentKeys == [.playPause])
        #expect(fixture.keys.isEmpty)
    }

    @Test("NPA-18: Seeking goes through the adapter, is clamped to the track, and shows at once")
    @MainActor
    func testSeekThroughAdapter() {
        let fixture = PlaybackFixture()
        let source = MockNowPlayingSource()
        let (service, island) = makeService(fixture, source: source)

        var song = Self.firefoxSong()                // 180 s long
        service.handleAdapterMessage(.snapshot(song))
        service.seek(to: 60)                         // this player did not say it can seek
        #expect(source.seeks.isEmpty)

        song.canSeek = true
        service.handleAdapterMessage(.snapshot(song))
        service.seek(to: 60)
        service.seek(to: 999)
        service.seek(to: -5)
        #expect(source.seeks == [60, 180, 0])
        #expect(island.nowPlayingTrack?.position == 0)
        #expect(fixture.scripts.isEmpty)
    }

    @Test("NPA-19: Music and Spotify are sought over AppleScript, with a decimal point whatever the locale")
    @MainActor
    func testSeekMusicApps() {
        let fixture = PlaybackFixture()
        let source = MockNowPlayingSource()
        let (service, island) = makeService(fixture, source: source)

        service.processSpotifyTrack(playerState: "Playing", name: "Song", artist: "Artist", album: nil,
                                    durationMs: 200_000, positionSec: 5)
        #expect(island.nowPlayingTrack?.canSeek == true)
        service.seek(to: 42.5)
        #expect(fixture.scripts == ["tell application \"Spotify\" to set player position to 42.50"])
        #expect(island.nowPlayingTrack?.position == 42.5)
        #expect(source.seeks.isEmpty)
    }

    // MARK: - The real thing (opt-in)

    /// Starts the real perl watcher on the adapter library named by `ZENITH_E2E_NOW_PLAYING_LIB` (for example
    /// `.build/debug/libZenithNowPlayingAdapter.dylib`). It only reads the session and sends no command.
    @Test("NPA-E2E: perl loads the adapter and reports the system's session",
          .enabled(if: ProcessInfo.processInfo.environment["ZENITH_E2E_NOW_PLAYING_LIB"] != nil))
    func testRealWatcher() async throws {
        let path = try #require(ProcessInfo.processInfo.environment["ZENITH_E2E_NOW_PLAYING_LIB"])
        let source = PerlNowPlayingSource(libraryURL: URL(fileURLWithPath: path))
        let (stream, continuation) = AsyncStream.makeStream(of: NowPlayingAdapterMessage.self)
        source.start { continuation.yield($0) }
        defer { source.stop() }

        let timeout = Task {
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            continuation.finish()
        }
        var first: NowPlayingAdapterMessage?
        for await message in stream {
            first = message
            break
        }
        timeout.cancel()

        let message = try #require(first, "the watcher printed nothing within 5 s")
        guard case .snapshot(let snapshot) = message else {
            Issue.record("expected a snapshot first, got \(message)")
            return
        }
        if let snapshot {
            print("NPA-E2E: pid \(snapshot.processID ?? 0), app \(snapshot.applicationBundleIdentifier ?? "?"), "
                + "title \(snapshot.title?.count ?? 0) chars, duration \(snapshot.duration), "
                + "playing \(snapshot.isPlaying), artwork \(snapshot.artworkData?.count ?? 0) bytes")
        } else {
            print("NPA-E2E: nothing is playing")
        }
    }
}
