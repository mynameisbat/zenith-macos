import Testing
import Foundation
import AppKit
import SwiftUI
@testable import ZenithCore

@Suite("Zenith Now Playing & Battery HUD Test Suite")
struct NowPlayingAndBatteryHUDTests {

    // MARK: - NowPlayingApp Enum Tests

    @Test("NP-01: NowPlayingApp properties for Apple Music, Spotify, YouTube, and Browsers")
    func testNowPlayingAppProperties() {
        let music = NowPlayingApp.appleMusic
        #expect(music.rawValue == "Music")
        #expect(music.displayName == "Apple Music")
        #expect(music.bundleIdentifier == "com.apple.Music")
        #expect(music.iconName == "music.note")

        let spotify = NowPlayingApp.spotify
        #expect(spotify.rawValue == "Spotify")
        #expect(spotify.displayName == "Spotify")
        #expect(spotify.bundleIdentifier == "com.spotify.client")
        #expect(spotify.iconName == "waveform")

        let youtube = NowPlayingApp.youtube
        #expect(youtube.rawValue == "YouTube")
        #expect(youtube.displayName == "YouTube")
        #expect(youtube.iconName == "play.rectangle.fill")

        let chrome = NowPlayingApp.chrome
        #expect(chrome.displayName == "Google Chrome")
        #expect(chrome.iconName == "globe")

        let safari = NowPlayingApp.safari
        #expect(safari.displayName == "Safari")
        #expect(safari.iconName == "safari.fill")

        let xTwitter = NowPlayingApp.xTwitter
        #expect(xTwitter.rawValue == "X")
        #expect(xTwitter.displayName == "X")

        // CaseIterable completeness
        #expect(NowPlayingApp.allCases.count >= 9)
        #expect(NowPlayingApp.allCases.contains(.appleMusic))
        #expect(NowPlayingApp.allCases.contains(.spotify))
        #expect(NowPlayingApp.allCases.contains(.youtube))
        #expect(NowPlayingApp.allCases.contains(.xTwitter))
        #expect(NowPlayingApp.allCases.contains(.chrome))
        #expect(NowPlayingApp.allCases.contains(.safari))

        // Resolver logic
        #expect(NowPlayingApp.resolve(bundleId: "com.google.Chrome", title: "Video on YouTube", artist: "Creator") == .youtube)
        #expect(NowPlayingApp.resolve(bundleId: "com.google.Chrome", title: "Post", artist: "Author", activeUrl: "https://x.com/home") == .xTwitter)
        #expect(NowPlayingApp.resolve(bundleId: "com.google.Chrome", title: "Video on Twitter", artist: "Author") == .xTwitter)
        #expect(NowPlayingApp.resolve(bundleId: "com.google.Chrome", title: "News", artist: "CNN") == .chrome)
        #expect(NowPlayingApp.resolve(bundleId: "com.apple.Safari", title: "Blog Post", artist: "Author") == .safari)
        #expect(NowPlayingApp.resolve(bundleId: "com.apple.Music", title: "Song", artist: "Singer") == .appleMusic)
        #expect(NowPlayingApp.resolve(bundleId: "com.spotify.client", title: "Pod", artist: "Host") == .spotify)
        #expect(NowPlayingApp.resolve(bundleId: "company.thebrowser.Browser", title: "Web", artist: nil) == .arc)
        #expect(NowPlayingApp.resolve(bundleId: "org.mozilla.firefox", title: "Web", artist: nil) == .firefox)
    }

    // MARK: - NowPlayingTrack Domain Model Tests

    @Test("NP-02: NowPlayingTrack initialization, clamping, and progress calculation")
    func testNowPlayingTrackProgress() {
        // Standard track
        let track = NowPlayingTrack(
            app: .appleMusic,
            title: "Midnight City",
            artist: "M83",
            album: "Hurry Up, We're Dreaming",
            duration: 240,
            position: 120,
            isPlaying: true
        )

        #expect(track.id == "Music:M83:Midnight City")
        #expect(track.title == "Midnight City")
        #expect(track.artist == "M83")
        #expect(track.album == "Hurry Up, We're Dreaming")
        #expect(track.duration == 240)
        #expect(track.position == 120)
        #expect(track.isPlaying == true)
        #expect(track.progress == 0.5)
        #expect(track.formattedPosition == "2:00")
        #expect(track.formattedDuration == "4:00")

        // Zero duration track (e.g. live stream)
        let zeroDurationTrack = NowPlayingTrack(
            app: .spotify,
            title: "Live Stream",
            artist: "Radio",
            duration: 0,
            position: 15,
            isPlaying: true
        )
        #expect(zeroDurationTrack.progress == 0.0)
        #expect(zeroDurationTrack.formattedDuration == "0:00")

        // Clamping overflow position
        let overflowTrack = NowPlayingTrack(
            app: .spotify,
            title: "Short Track",
            artist: "Artist",
            duration: 60,
            position: 999,
            isPlaying: true
        )
        #expect(overflowTrack.position == 60)
        #expect(overflowTrack.progress == 1.0)
        #expect(overflowTrack.formattedPosition == "1:00")

        // Negative values clamped to 0
        let negativeTrack = NowPlayingTrack(
            app: .appleMusic,
            title: "Neg",
            artist: "Neg",
            duration: -10,
            position: -5
        )
        #expect(negativeTrack.duration == 0)
        #expect(negativeTrack.position == 0)
        #expect(negativeTrack.formattedPosition == "0:00")
    }

    @Test("NP-03: NowPlayingTrack time formatting precision")
    func testTrackTimeFormatting() {
        let t1 = NowPlayingTrack(app: .spotify, title: "A", artist: "B", duration: 65, position: 5)
        #expect(t1.formattedPosition == "0:05")
        #expect(t1.formattedDuration == "1:05")

        let t2 = NowPlayingTrack(app: .spotify, title: "A", artist: "B", duration: 3661, position: 600)
        #expect(t2.formattedPosition == "10:00")
        #expect(t2.formattedDuration == "61:01")
    }

    @Test("NP-04: NowPlayingTrack equality logic with position jitter tolerance")
    func testTrackEquality() {
        let track1 = NowPlayingTrack(
            app: .appleMusic,
            title: "Song",
            artist: "Artist",
            duration: 200,
            position: 10.0,
            isPlaying: true
        )

        // Same track with position within 2.0s jitter tolerance should be equal
        let track1Jitter = NowPlayingTrack(
            app: .appleMusic,
            title: "Song",
            artist: "Artist",
            duration: 200,
            position: 11.2,
            isPlaying: true
        )
        #expect(track1 == track1Jitter)

        // Position difference > 2.0s should not be equal
        let track1Advanced = NowPlayingTrack(
            app: .appleMusic,
            title: "Song",
            artist: "Artist",
            duration: 200,
            position: 15.0,
            isPlaying: true
        )
        #expect(track1 != track1Advanced)

        // Play/Pause state change should not be equal
        let track1Paused = NowPlayingTrack(
            app: .appleMusic,
            title: "Song",
            artist: "Artist",
            duration: 200,
            position: 10.0,
            isPlaying: false
        )
        #expect(track1 != track1Paused)

        // Different song should not be equal
        let track2 = NowPlayingTrack(
            app: .appleMusic,
            title: "Another Song",
            artist: "Artist",
            duration: 200,
            position: 10.0,
            isPlaying: true
        )
        #expect(track1 != track2)
    }

    // MARK: - Dynamic Island Geometry with Now Playing

    @Test("NP-05: ZenithIslandGeometry nowPlayingIdleFrame calculation")
    func testNowPlayingGeometry() {
        let screen = NSScreen.main ?? NSScreen.screens.first
        let geometry = ZenithIslandGeometry(screen: screen)

        #expect(geometry.nowPlayingIdleWidth > geometry.idleWidth)
        #expect(geometry.nowPlayingIdleHeight >= geometry.idleHeight)

        let idleFrame = geometry.windowFrame(isExpanded: false)
        let npFrame = geometry.nowPlayingIdleFrame

        let expectedScreenFrame = screen?.frame ?? CGRect(x: 0, y: 0, width: 1920, height: 1080)

        // Centered horizontally
        #expect(abs(npFrame.midX - expectedScreenFrame.midX) < 1.0)

        // Touching top edge
        #expect(abs(npFrame.maxY - expectedScreenFrame.maxY) < 1.0)

        // Now Playing idle capsule should be wider than standard idle capsule
        #expect(npFrame.width > idleFrame.width)
    }

    // MARK: - ZenithIslandState Tab and Now Playing Integration

    @Test("NP-06: ZenithIslandState activeTab and nowPlayingTrack binding")
    @MainActor
    func testIslandStateNowPlaying() {
        let state = ZenithIslandState.shared

        // Initial tab is nowPlaying
        state.activeTab = .nowPlaying
        #expect(state.activeTab == .nowPlaying)

        // Can switch to shelf
        state.activeTab = .shelf
        #expect(state.activeTab == .shelf)

        // Setting nowPlayingTrack
        let sampleTrack = NowPlayingTrack(
            app: .spotify,
            title: "Starboy",
            artist: "The Weeknd",
            duration: 230,
            position: 45,
            isPlaying: true
        )
        state.nowPlayingTrack = sampleTrack
        #expect(state.nowPlayingTrack?.title == "Starboy")
        #expect(state.nowPlayingTrack?.artist == "The Weeknd")

        // Clearing nowPlayingTrack
        state.nowPlayingTrack = nil
        #expect(state.nowPlayingTrack == nil)
    }

    // MARK: - Battery HUD & PowerSourceMonitorService Tests

    @Test("BAT-01: PowerSourceMonitorService lifecycle and initial state")
    @MainActor
    func testPowerSourceMonitorLifecycle() {
        let service = PowerSourceMonitorService.shared

        #expect(!service.isMonitoring)
        service.startMonitoring()
        #expect(service.isMonitoring)

        // Calling start again when already running should be idempotent
        service.startMonitoring()
        #expect(service.isMonitoring)

        // Stop monitoring
        service.stopMonitoring()
        #expect(!service.isMonitoring)
    }

    @Test("BAT-02: PowerSourceMonitorService evaluatePowerSourceChange triggers")
    @MainActor
    func testPowerSourceMonitorEvaluation() {
        let service = PowerSourceMonitorService.shared
        // Safe evaluation without crash regardless of hardware battery presence
        service.evaluatePowerSourceChange()

        let battery = HardwareTelemetryService.shared.readBatteryTelemetry()
        if battery.hasBattery {
            #expect(service.lastKnownBattery != nil)
            #expect(service.lastKnownBattery?.percentage == battery.percentage)
        }
    }

    @Test("BAT-03: IslandAlert tintColor resolution for battery alerts")
    func testIslandAlertTintColor() {
        let defaultAlert = IslandAlert(
            icon: "bell.fill",
            title: "Test",
            subtitle: "Subtitle"
        )
        #expect(defaultAlert.tintColor == nil)
        #expect(defaultAlert.resolvedColor == Color(red: 0.98, green: 0.45, blue: 0.09))

        let customColor = Color(red: 0.12, green: 0.84, blue: 0.38)
        let greenAlert = IslandAlert(
            icon: "bolt.fill",
            title: "Charging",
            subtitle: "Connected",
            tintColor: customColor
        )
        #expect(greenAlert.tintColor == customColor)
        #expect(greenAlert.resolvedColor == customColor)
    }
}
