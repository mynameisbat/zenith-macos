import Testing
import Foundation
@testable import ZenithCore

/// Stands in for the system's answer to "which app is playing audio" and records what the service does about it.
final class PlaybackFixture: @unchecked Sendable {
    private let lock = NSLock()
    private var _playing: PlayingApplication?
    private var _osascriptOutput = ""
    private var _osascriptCalls = 0
    private var _keys: [MediaKey] = []
    private var _scripts: [String] = []

    var playing: PlayingApplication? {
        get { lock.withLock { _playing } }
        set { lock.withLock { _playing = newValue } }
    }
    var osascriptOutput: String {
        get { lock.withLock { _osascriptOutput } }
        set { lock.withLock { _osascriptOutput = newValue } }
    }
    var osascriptCalls: Int { lock.withLock { _osascriptCalls } }
    var keys: [MediaKey] { lock.withLock { _keys } }
    var scripts: [String] { lock.withLock { _scripts } }

    var runner: SystemCommandRunner {
        { [self] executable, _ in
            guard executable == "/usr/bin/osascript" else { return nil }
            return lock.withLock {
                _osascriptCalls += 1
                return SystemCommandResult(status: 0, output: _osascriptOutput)
            }
        }
    }

    struct Keys: MediaKeyPosting {
        let fixture: PlaybackFixture
        func post(_ key: MediaKey) -> Bool { fixture.lock.withLock { fixture._keys.append(key) }; return true }
    }
    var mediaKeys: MediaKeyPosting { Keys(fixture: self) }

    var scriptRunner: @Sendable (String) -> Void {
        { [self] source in lock.withLock { _scripts.append(source) } }
    }

    static let chrome = PlayingApplication(processID: 100, bundleIdentifier: "com.google.Chrome", name: "Google Chrome")
    static let safari = PlayingApplication(processID: 101, bundleIdentifier: "com.apple.Safari", name: "Safari")
    static let firefox = PlayingApplication(processID: 102, bundleIdentifier: "org.mozilla.firefox", name: "Firefox")
}

@Suite("Playback Detection Suite")
struct PlaybackDetectionTests {

    // MARK: - Assertion table

    @Test("PD-01: Chrome's and Safari's playback assertions are recognised; wake locks and daemons are not")
    func testAssertionTableParsing() {
        let table: [Int: [[String: Any]]] = [
            793: [["AssertName": "com.apple.audio.AC-07-75:output.context.preventuseridlesleep"]],      // coreaudiod: no marker
            3033: [["AssertName": "Playing audio"], ["AssertName": "Video Wake Lock"]],                   // Chrome
            3052: [["AssertName": "com.apple.WebCore: HTMLMediaElement playback"]],                      // Safari
            4000: [["AssertName": "Video Wake Lock"]],                                                   // muted autoplay video only
            555: [["AssertName": "Powerd - Prevent sleep while display is on"]]
        ]
        #expect(PlaybackAssertionProbe.playbackPIDs(in: table) == [3033, 3052])
        #expect(PlaybackAssertionProbe.playbackPIDs(in: [:]) == [])
    }

    // MARK: - Tab lookup

    @Test("PD-02: The tab script matches each browser family and never launches a browser that is not running")
    func testTabScripts() throws {
        let safari = try #require(BrowserTabProbe.script(forBundleIdentifier: "com.apple.Safari"))
        #expect(safari.contains("current tab of front window") && safari.contains("name of t"))
        let chrome = try #require(BrowserTabProbe.script(forBundleIdentifier: "com.google.Chrome"))
        #expect(chrome.contains("active tab of front window") && chrome.contains("title of t"))
        for script in [safari, chrome] {
            #expect(script.contains("is not running then return"))
            #expect(script.contains("with timeout of 3 seconds"))
        }
        for id in ["com.microsoft.edgemac", "com.brave.Browser", "company.thebrowser.Browser"] {
            #expect(BrowserTabProbe.supportsTabLookup(bundleIdentifier: id))
        }
        #expect(BrowserTabProbe.script(forBundleIdentifier: "org.mozilla.firefox") == nil)
    }

    @Test("PD-03: The script's two-line output becomes a tab; anything else does not")
    func testTabParsing() {
        #expect(BrowserTabProbe.parseTab("Cool Video - YouTube\nhttps://www.youtube.com/watch?v=abc\n")
                == BrowserTab(title: "Cool Video - YouTube", url: "https://www.youtube.com/watch?v=abc"))
        #expect(BrowserTabProbe.parseTab("") == nil)
        #expect(BrowserTabProbe.parseTab("Only a title") == nil)
        #expect(BrowserTabProbe.parseTab("Title\n\n") == nil)
    }

    @Test("PD-04: Titles are cleaned and only known media sites count")
    func testTitleCleaningAndMediaSites() {
        #expect(BrowserTabProbe.cleanTitle("(3) Great Song - YouTube") == "Great Song")
        #expect(BrowserTabProbe.cleanTitle("Home / X") == "Home")
        #expect(BrowserTabProbe.cleanTitle("  Plain  ") == "Plain")
        #expect(BrowserTabProbe.isMediaSite(url: "https://www.youtube.com/watch?v=1"))
        #expect(BrowserTabProbe.isMediaSite(url: "https://music.youtube.com/"))
        #expect(BrowserTabProbe.isMediaSite(url: "https://x.com/home"))
        #expect(!BrowserTabProbe.isMediaSite(url: "https://notyoutube.com/"))
        #expect(!BrowserTabProbe.isMediaSite(url: "https://docs.example.com/"))
        #expect(!BrowserTabProbe.isMediaSite(url: "not a url"))
    }

    // MARK: - Building the track

    @Test("PD-05: A YouTube tab becomes a YouTube track; a generic X tab says it is a video on X")
    func testBrowserTrackFromTab() {
        let youtube = NowPlayingService.browserTrack(
            for: PlaybackFixture.chrome,
            tab: BrowserTab(title: "(2) Great Song - YouTube", url: "https://www.youtube.com/watch?v=1")
        )
        #expect(youtube.app == .youtube && youtube.title == "Great Song" && youtube.artist == "YouTube")
        #expect(youtube.isPlaying && youtube.duration == 0)

        let x = NowPlayingService.browserTrack(
            for: PlaybackFixture.safari,
            tab: BrowserTab(title: "Home / X", url: "https://x.com/home")
        )
        #expect(x.app == .xTwitter && x.title == "Video on X" && x.artist == "X")
    }

    @Test("PD-06: Without a readable media tab, the track names the app instead of an unrelated tab")
    func testBrowserTrackWithoutMediaTab() {
        let unrelated = NowPlayingService.browserTrack(
            for: PlaybackFixture.chrome,
            tab: BrowserTab(title: "Quarterly report", url: "https://docs.example.com/report")
        )
        #expect(unrelated.title == "Google Chrome" && unrelated.artist == "Playing audio" && unrelated.app == .chrome)

        let noTab = NowPlayingService.browserTrack(for: PlaybackFixture.firefox, tab: nil)
        #expect(noTab.title == "Firefox" && noTab.app == .firefox)
    }

    // MARK: - The service

    @MainActor
    private func makeService(_ fixture: PlaybackFixture) -> (NowPlayingService, ZenithIslandState) {
        let island = ZenithIslandState()
        let service = NowPlayingService(
            islandState: island,
            playingApplicationProvider: { fixture.playing },
            commandRunner: fixture.runner,
            mediaKeys: fixture.mediaKeys,
            scriptRunner: fixture.scriptRunner
        )
        return (service, island)
    }

    @Test("PD-07: Audio in Chrome shows up on the island, first as the app and then with the tab's title")
    @MainActor
    func testChromeAudioAppearsWithTabTitle() async {
        let fixture = PlaybackFixture()
        fixture.playing = PlaybackFixture.chrome
        fixture.osascriptOutput = "Great Song - YouTube\nhttps://www.youtube.com/watch?v=1\n"
        let (service, island) = makeService(fixture)

        service.refreshFromPlaybackAssertions()
        #expect(island.nowPlayingTrack?.isPlaying == true)
        #expect(island.nowPlayingTrack?.title == "Google Chrome")      // visible at once, before the lookup returns

        await service.waitForTabLookup()
        #expect(island.nowPlayingTrack?.title == "Great Song")
        #expect(island.nowPlayingTrack?.app == .youtube)
    }

    @Test("PD-08: Safari audio is detected and its tab is read")
    @MainActor
    func testSafariAudioIsDetected() async {
        let fixture = PlaybackFixture()
        fixture.playing = PlaybackFixture.safari
        fixture.osascriptOutput = "Clip\nhttps://www.youtube.com/watch?v=2\n"
        let (service, island) = makeService(fixture)

        service.refreshFromPlaybackAssertions()
        await service.waitForTabLookup()
        #expect(island.nowPlayingTrack?.title == "Clip")
        #expect(island.nowPlayingTrack?.app == .youtube)
    }

    @Test("PD-09: The tab is looked up once and reused, not re-read on every poll")
    @MainActor
    func testTabLookupIsCached() async {
        let fixture = PlaybackFixture()
        fixture.playing = PlaybackFixture.chrome
        fixture.osascriptOutput = "Great Song - YouTube\nhttps://www.youtube.com/watch?v=1\n"
        let (service, _) = makeService(fixture)

        for _ in 0..<5 {
            service.refreshFromPlaybackAssertions()
            await service.waitForTabLookup()
        }
        #expect(fixture.osascriptCalls == 1)
    }

    @Test("PD-10: A browser without AppleScript support is shown by name and never queried")
    @MainActor
    func testUnsupportedBrowserIsNotQueried() async {
        let fixture = PlaybackFixture()
        fixture.playing = PlaybackFixture.firefox
        let (service, island) = makeService(fixture)

        service.refreshFromPlaybackAssertions()
        await service.waitForTabLookup()
        #expect(island.nowPlayingTrack?.title == "Firefox")
        #expect(fixture.osascriptCalls == 0)
    }

    @Test("PD-11: When the audio stops, a detected track is removed")
    @MainActor
    func testTrackClearsWhenAudioStops() {
        let fixture = PlaybackFixture()
        fixture.playing = PlaybackFixture.firefox
        let (service, island) = makeService(fixture)

        service.refreshFromPlaybackAssertions()
        #expect(island.nowPlayingTrack != nil)

        fixture.playing = nil
        service.refreshFromPlaybackAssertions()
        #expect(island.nowPlayingTrack == nil && service.currentTrack == nil)
    }

    @Test("PD-12: Browser audio never replaces a track Apple Music or Spotify is playing, but does replace a paused one")
    @MainActor
    func testBrowserAudioDoesNotOverrideMusicApps() {
        let fixture = PlaybackFixture()
        fixture.playing = PlaybackFixture.firefox
        let (service, island) = makeService(fixture)

        service.processSpotifyTrack(playerState: "Playing", name: "Song", artist: "Artist", album: nil, durationMs: 200, positionSec: 5)
        service.refreshFromPlaybackAssertions()
        #expect(island.nowPlayingTrack?.app == .spotify)

        // Spotify stops reporting and the browser keeps playing.
        service.processSpotifyTrack(playerState: "Paused", name: "Song", artist: "Artist", album: nil, durationMs: 200, positionSec: 5)
        service.refreshFromPlaybackAssertions()
        #expect(island.nowPlayingTrack?.app == .firefox)

        // When the browser goes quiet, the (paused) Spotify track is not wiped out by detection.
        fixture.playing = nil
        service.processSpotifyTrack(playerState: "Playing", name: "Song 2", artist: "Artist", album: nil, durationMs: 200, positionSec: 0)
        service.refreshFromPlaybackAssertions()
        #expect(island.nowPlayingTrack?.title == "Song 2")
    }

    @Test("PD-13: Controls use the media key for browsers and AppleScript for Music/Spotify, and do nothing when idle")
    @MainActor
    func testControlRouting() {
        let fixture = PlaybackFixture()
        fixture.playing = PlaybackFixture.chrome
        let (service, _) = makeService(fixture)

        // Nothing playing: nothing is sent (a media key would launch Music).
        service.togglePlayPause()
        #expect(fixture.keys.isEmpty && fixture.scripts.isEmpty)

        // Browser audio: hardware media keys, no script, no focus change.
        service.refreshFromPlaybackAssertions()
        service.togglePlayPause()
        service.nextTrack()
        service.previousTrack()
        #expect(fixture.keys == [.playPause, .next, .previous])
        #expect(fixture.scripts.isEmpty)

        // Spotify: told directly.
        service.processSpotifyTrack(playerState: "Playing", name: "Song", artist: "Artist", album: nil, durationMs: 200, positionSec: 0)
        service.togglePlayPause()
        service.nextTrack()
        #expect(fixture.keys.count == 3)
        #expect(fixture.scripts == [
            "tell application \"Spotify\" to playpause",
            "tell application \"Spotify\" to next track"
        ])
    }
}
