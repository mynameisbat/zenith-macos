import Testing
import Foundation
import Combine
import CoreGraphics
import CoreVideo
import AVFoundation
import ImageIO
@testable import ZenithCore

// Screen recording without the screen or the microphone: the state machine, the choice of sounds, the mixer, the
// trim/GIF arithmetic, and the file writer fed with made-up frames and tones.

@Suite("ScreenRecordingTests")
struct ScreenRecordingTests {

    // MARK: - State machine

    @Test("REC-01: countdown, record, stop, finish")
    func stateMachineHappyPath() {
        typealias M = ScreenRecorderStateMachine
        var state = ScreenRecorderState.idle
        state = M.reduce(state, .start(countdown: 3))!
        #expect(state == .countingDown(3))
        state = M.reduce(state, .countdownTick)!
        #expect(state == .countingDown(2))
        state = M.reduce(state, .countdownTick)!
        state = M.reduce(state, .countdownTick)!
        #expect(state == .preparing)
        let date = Date(timeIntervalSince1970: 100)
        state = M.reduce(state, .backendStarted(date))!
        #expect(state == .recording(startedAt: date))
        #expect(state.isRecording && state.isBusy)
        state = M.reduce(state, .stop)!
        #expect(state == .stopping)
        let result = RecordingResult(url: URL(fileURLWithPath: "/tmp/a.mov"), duration: 3)
        state = M.reduce(state, .backendFinished(result))!
        #expect(state == .finished(result))
        #expect(!state.isBusy)
        // A new recording can start from a finished one.
        #expect(M.reduce(state, .start(countdown: 0)) == .preparing)
    }

    @Test("REC-02: cancel, failure and events that do not apply")
    func stateMachineEdges() {
        typealias M = ScreenRecorderStateMachine
        #expect(M.reduce(.idle, .start(countdown: 0)) == .preparing)
        #expect(M.reduce(.countingDown(2), .cancel) == .idle)
        #expect(M.reduce(.countingDown(2), .stop) == .idle)
        #expect(M.reduce(.preparing, .backendFailed("x")) == .failed("x"))
        #expect(M.reduce(.recording(startedAt: Date()), .backendFailed("y")) == .failed("y"))
        #expect(M.reduce(.preparing, .cancel) == .idle)
        // Ignored: nothing to stop, a second start while busy, a tick outside the countdown.
        #expect(M.reduce(.idle, .stop) == nil)
        #expect(M.reduce(.recording(startedAt: Date()), .start(countdown: 3)) == nil)
        #expect(M.reduce(.preparing, .countdownTick) == nil)
        #expect(M.reduce(.preparing, .stop) == nil)
        #expect(M.reduce(.idle, .backendFinished(RecordingResult(url: URL(fileURLWithPath: "/x"), duration: 1))) == nil)
    }

    // MARK: - Audio sources

    @Test("REC-03: which sounds are recorded and when the microphone is asked for")
    func audioPlan() {
        #expect(RecordingAudioPlan.resolve(systemAudio: false, microphone: false, access: .granted).sources.isEmpty)
        #expect(RecordingAudioPlan.resolve(systemAudio: true, microphone: false, access: .denied).sources == [.system])
        let both = RecordingAudioPlan.resolve(systemAudio: true, microphone: true, access: .granted)
        #expect(both.sources == [.system, .microphone])
        #expect(both.notice == nil)
        let denied = RecordingAudioPlan.resolve(systemAudio: true, microphone: true, access: .denied)
        #expect(denied.sources == [.system])
        #expect(denied.notice == .microphoneDenied)
        let unavailable = RecordingAudioPlan.resolve(systemAudio: false, microphone: true, access: .unavailable)
        #expect(unavailable.sources.isEmpty)
        #expect(unavailable.notice == .microphoneUnavailable)
        #expect(!(unavailable.notice?.message.isEmpty ?? true))

        #expect(RecordingAudioPlan.needsMicrophoneRequest(microphoneOn: true, access: .notDetermined))
        #expect(!RecordingAudioPlan.needsMicrophoneRequest(microphoneOn: false, access: .notDetermined))
        #expect(!RecordingAudioPlan.needsMicrophoneRequest(microphoneOn: true, access: .granted))
        #expect(!RecordingAudioPlan.needsMicrophoneRequest(microphoneOn: true, access: .denied))
        #expect(!RecordingAudioPlan.needsMicrophoneRequest(microphoneOn: true, access: .unavailable))
    }

    // MARK: - Recorder with a mock backend

    private func request(_ plan: RecordingAudioPlan) -> RecordingRequest {
        RecordingRequest(
            target: .display(displayID: 1),
            audio: plan,
            outputURL: URL(fileURLWithPath: "/tmp/zenith-test.mov"),
            pointSize: CGSize(width: 800, height: 600)
        )
    }

    @MainActor
    @Test("REC-04: the recorder counts down, starts the backend with the chosen sounds, and finishes")
    func recorderFlow() async {
        let backend = MockScreenRecordingBackend()
        let microphone = MockMicrophoneAuthorizer(access: .notDetermined)
        let sleeps = Counter()
        let recorder = ScreenRecorder(backend: backend, microphone: microphone, sleep: { _ in sleeps.increment() })
        var states: [ScreenRecorderState] = []
        recorder.onStateChange = { states.append($0) }

        await recorder.start(countdown: 3, systemAudio: true, microphone: false) { self.request($0) }
        #expect(sleeps.value == 3)
        #expect(microphone.requestCount == 0, "the microphone is never asked for when it is off")
        #expect(backend.requests.count == 1)
        #expect(backend.requests.first?.audio.sources == [.system])
        #expect(Array(states.prefix(4)) == [.countingDown(3), .countingDown(2), .countingDown(1), .preparing])
        #expect(recorder.state.isRecording)

        await recorder.stop()
        #expect(backend.stopCount == 1)
        guard case .finished(let result) = recorder.state else {
            Issue.record("expected finished, got \(recorder.state)")
            return
        }
        #expect(result.url.lastPathComponent == "zenith-test.mov")
        recorder.acknowledgeResult()
        #expect(recorder.state == .idle)
    }

    @MainActor
    @Test("REC-05: the microphone is asked for once, only when switched on and never asked before")
    func recorderMicrophone() async {
        let backend = MockScreenRecordingBackend()
        let microphone = MockMicrophoneAuthorizer(access: .notDetermined, grantsWhenAsked: true)
        let recorder = ScreenRecorder(backend: backend, microphone: microphone, sleep: { _ in })
        await recorder.start(countdown: 0, systemAudio: false, microphone: true) { self.request($0) }
        #expect(microphone.requestCount == 1)
        #expect(backend.requests.first?.audio.sources == [.microphone])
        await recorder.stop()
        recorder.acknowledgeResult()

        // Already granted: no second prompt.
        await recorder.start(countdown: 0, systemAudio: false, microphone: true) { self.request($0) }
        #expect(microphone.requestCount == 1)

        // Refused, and a build that cannot ask: recorded without the microphone, with a notice, never asked.
        let refused = MockMicrophoneAuthorizer(access: .notDetermined, grantsWhenAsked: false)
        let r2 = ScreenRecorder(backend: MockScreenRecordingBackend(), microphone: refused, sleep: { _ in })
        let plan = await r2.resolveAudio(systemAudio: true, microphone: true)
        #expect(plan.sources == [.system])
        #expect(plan.notice == .microphoneDenied)

        let cannotAsk = MockMicrophoneAuthorizer(access: .unavailable)
        let r3 = ScreenRecorder(backend: MockScreenRecordingBackend(), microphone: cannotAsk, sleep: { _ in })
        let plan3 = await r3.resolveAudio(systemAudio: false, microphone: true)
        #expect(cannotAsk.requestCount == 0)
        #expect(plan3.notice == .microphoneUnavailable)
    }

    @MainActor
    @Test("REC-06: a failing start, a cancelled countdown and a stream that ends by itself")
    func recorderFailures() async {
        let failing = MockScreenRecordingBackend()
        failing.startError = ScreenRecordingError.permissionDenied
        let r1 = ScreenRecorder(backend: failing, microphone: MockMicrophoneAuthorizer(access: .granted), sleep: { _ in })
        await r1.start(countdown: 0, systemAudio: false, microphone: false) { self.request($0) }
        guard case .failed = r1.state else {
            Issue.record("expected failed, got \(r1.state)")
            return
        }

        // Cancel during the countdown: the backend never starts.
        let backend = MockScreenRecordingBackend()
        let box = RecorderBox()
        let r2 = ScreenRecorder(backend: backend, microphone: MockMicrophoneAuthorizer(access: .granted), sleep: { _ in
            await MainActor.run { box.recorder?.cancel() }
        })
        box.recorder = r2
        await r2.start(countdown: 3, systemAudio: true, microphone: false) { self.request($0) }
        #expect(backend.requests.isEmpty)
        #expect(r2.state == .idle)

        // A request that cannot be made (e.g. the folder is not writable) goes back to idle.
        let r3 = ScreenRecorder(backend: MockScreenRecordingBackend(), microphone: MockMicrophoneAuthorizer(access: .granted), sleep: { _ in })
        await r3.start(countdown: 0, systemAudio: false, microphone: false) { _ in nil }
        #expect(r3.state == .idle)

        // The recorded window closes: what was recorded is kept.
        let ending = MockScreenRecordingBackend()
        let r4 = ScreenRecorder(backend: ending, microphone: MockMicrophoneAuthorizer(access: .granted), sleep: { _ in })
        await r4.start(countdown: 0, systemAudio: false, microphone: false) { self.request($0) }
        ending.simulateUnexpectedStop()
        for _ in 0..<50 where ending.stopCount == 0 {
            try? await Task.sleep(for: .milliseconds(10))
        }
        for _ in 0..<50 where !(r4.state.isBusy == false) {
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(ending.stopCount == 1)
        if case .finished = r4.state {} else { Issue.record("expected finished, got \(r4.state)") }
    }

    // MARK: - Geometry, names, window picking

    @Test("REC-07: pixel sizes are even and fit the encoder")
    func geometry() {
        let retina = RecordingGeometry.outputPixelSize(pointSize: CGSize(width: 301, height: 199), scale: 2, maximumDimension: 4096)
        #expect(retina.width == 602 && retina.height == 398)
        let odd = RecordingGeometry.outputPixelSize(pointSize: CGSize(width: 101, height: 51), scale: 1, maximumDimension: 4096)
        #expect(odd.width % 2 == 0 && odd.height % 2 == 0)
        // A 5K display in H.264 is scaled to 4096 wide, keeping 16:9.
        let fiveK = RecordingGeometry.outputPixelSize(pointSize: CGSize(width: 2560, height: 1440), scale: 2, maximumDimension: RecordingVideoCodec.h264.maximumDimension)
        #expect(fiveK.width == 4096)
        #expect(abs(Double(fiveK.width) / Double(fiveK.height) - 16.0 / 9.0) < 0.01)
        let hevc = RecordingGeometry.outputPixelSize(pointSize: CGSize(width: 2560, height: 1440), scale: 2, maximumDimension: RecordingVideoCodec.hevc.maximumDimension)
        #expect(hevc.width == 5120 && hevc.height == 2880)
        let tiny = RecordingGeometry.outputPixelSize(pointSize: CGSize(width: 0.2, height: 0), scale: 0, maximumDimension: 4096)
        #expect(tiny.width >= 2 && tiny.height >= 2)
        #expect(RecordingGeometry.averageBitRate(width: 10, height: 10, frameRate: 30, codec: .h264) == 2_000_000)
        #expect(RecordingGeometry.averageBitRate(width: 3840, height: 2160, frameRate: 60, codec: .hevc) < RecordingGeometry.averageBitRate(width: 3840, height: 2160, frameRate: 60, codec: .h264))
    }

    @Test("REC-08: file names follow macOS screenshots and never overwrite")
    func fileNames() throws {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let name = RecordingFileNamer.fileName(date: date, format: .mp4, timeZone: TimeZone(identifier: "UTC")!)
        #expect(name == "Zenith Recording 2023-11-14 at 22.13.20.mp4")

        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("zenith-rec-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let first = RecordingFileNamer.uniqueURL(in: folder, fileName: "Clip.mov")
        #expect(first.lastPathComponent == "Clip.mov")
        FileManager.default.createFile(atPath: first.path, contents: Data())
        #expect(RecordingFileNamer.uniqueURL(in: folder, fileName: "Clip.mov").lastPathComponent == "Clip 2.mov")
        #expect(RecordingExporter.siblingURL(for: first, suffix: "trimmed", pathExtension: "mov").lastPathComponent == "Clip (trimmed).mov")
        #expect(RecordingExporter.siblingURL(for: first, suffix: nil, pathExtension: "gif").lastPathComponent == "Clip.gif")
    }

    @Test("REC-09: a click picks the front-most ordinary window that is not Zenith's")
    func windowPicking() {
        let windows = [
            OnScreenWindowInfo(windowID: 1, ownerPID: 99, layer: 0, bounds: CGRect(x: 0, y: 0, width: 500, height: 500)),     // Zenith
            OnScreenWindowInfo(windowID: 2, ownerPID: 10, layer: 25, bounds: CGRect(x: 0, y: 0, width: 800, height: 30)),     // menu bar item
            OnScreenWindowInfo(windowID: 3, ownerPID: 11, layer: 0, bounds: CGRect(x: 100, y: 100, width: 20, height: 20)),   // tiny
            OnScreenWindowInfo(windowID: 4, ownerPID: 12, layer: 0, bounds: CGRect(x: 50, y: 50, width: 400, height: 300), alpha: 0),
            OnScreenWindowInfo(windowID: 5, ownerPID: 13, layer: 0, bounds: CGRect(x: 0, y: 0, width: 600, height: 600)),
            OnScreenWindowInfo(windowID: 6, ownerPID: 14, layer: 0, bounds: CGRect(x: 0, y: 0, width: 900, height: 900))
        ]
        #expect(WindowPicker.window(at: CGPoint(x: 110, y: 110), in: windows, excludingPID: 99)?.windowID == 5)
        #expect(WindowPicker.window(at: CGPoint(x: 800, y: 800), in: windows, excludingPID: 99)?.windowID == 6)
        #expect(WindowPicker.window(at: CGPoint(x: 2000, y: 2000), in: windows, excludingPID: 99) == nil)

        let dict: [String: Any] = [
            kCGWindowNumber as String: NSNumber(value: 42),
            kCGWindowOwnerPID as String: NSNumber(value: 7),
            kCGWindowLayer as String: NSNumber(value: 0),
            kCGWindowBounds as String: CGRect(x: 1, y: 2, width: 3, height: 4).dictionaryRepresentation
        ]
        #expect(OnScreenWindowInfo(dictionary: dict) == OnScreenWindowInfo(windowID: 42, ownerPID: 7, layer: 0, bounds: CGRect(x: 1, y: 2, width: 3, height: 4)))
        #expect(OnScreenWindowInfo(dictionary: [:]) == nil)
    }

    // MARK: - Mixer

    @Test("REC-10: the mixer lines sources up on one timeline and sums them")
    func mixerSums() {
        var mixer = AudioTimelineMixer(sources: [.system, .microphone], channels: 1, sampleRate: 1000, maxLag: 0.5, joinTolerance: 0.005)
        mixer.append(.system, samples: Array(repeating: 0.25, count: 100), startFrame: 0)
        mixer.append(.microphone, samples: Array(repeating: 0.5, count: 90), startFrame: 10)
        let chunk = mixer.drain()
        #expect(chunk?.startFrame == 0)
        #expect(chunk?.samples.count == 100)
        #expect(chunk?.samples[5] == 0.25)       // before the microphone starts
        #expect(chunk?.samples[50] == 0.75)      // both
        #expect(mixer.drain() == nil)

        // Loud sources are clipped, not wrapped.
        mixer.append(.system, samples: Array(repeating: 0.8, count: 10), startFrame: 100)
        mixer.append(.microphone, samples: Array(repeating: 0.8, count: 10), startFrame: 100)
        #expect(mixer.drain()?.samples.allSatisfy { $0 == 1 } == true)
    }

    @Test("REC-11: one source alone passes through unchanged and waits for nobody")
    func mixerSingleSource() {
        var mixer = AudioTimelineMixer(sources: [.system], channels: 2, sampleRate: 1000)
        let samples: [Float] = (0..<20).map { Float($0) / 100 }
        mixer.append(.system, samples: samples, startFrame: 0)
        let chunk = mixer.drain()
        #expect(chunk?.samples == samples)
        #expect(mixer.mixedUpTo == 10)
    }

    @Test("REC-12: jitter is joined, a silent source stops holding the other back, late sound is dropped")
    func mixerTiming() {
        var mixer = AudioTimelineMixer(sources: [.system, .microphone], channels: 1, sampleRate: 1000, maxLag: 0.5, joinTolerance: 0.005)
        // 3 frames late: joined to the end of the previous chunk, so there is no gap.
        mixer.append(.system, samples: Array(repeating: 0.1, count: 100), startFrame: 0)
        mixer.append(.system, samples: Array(repeating: 0.1, count: 100), startFrame: 103)
        // The microphone has sent nothing: after 0.5 s (500 frames) of lead nothing is ready yet...
        #expect(mixer.drain() == nil)
        mixer.append(.system, samples: Array(repeating: 0.1, count: 600), startFrame: 200)
        // ...past it, the system sound is handed out with the microphone counted as silence.
        let lagged = mixer.drain()
        #expect(lagged?.samples.count == 300)
        #expect(lagged?.samples.allSatisfy { $0 == Float(0.1) } == true)

        // Microphone sound for a stretch already handed out is dropped; the rest is kept.
        mixer.append(.microphone, samples: Array(repeating: 0.5, count: 400), startFrame: 0)
        let final = mixer.drain(final: true)
        #expect(final?.startFrame == 300)
        #expect(final?.samples.count == 500)
        #expect(abs((final?.samples.first ?? 0) - 0.6) < 1e-6)   // frames 300..<400 have both
        #expect(final?.samples.last == Float(0.1))
        #expect(mixer.mixedUpTo == 800)
    }

    @Test("REC-13: mono becomes stereo, stereo is interleaved")
    func interleave() {
        #expect(PCMInterleaver.interleavedStereo([[1, 2, 3]]) == [1, 1, 2, 2, 3, 3])
        #expect(PCMInterleaver.interleavedStereo([[1, 2], [5, 6], [9, 9]]) == [1, 5, 2, 6])
        #expect(PCMInterleaver.interleavedStereo([]) == [])
    }

    // MARK: - Trim and GIF arithmetic

    @Test("REC-14: trim ranges are kept inside the clip, in order and not too short")
    func trimRanges() {
        #expect(TrimRange.clamped(start: 1, end: 3, duration: 5) == TrimRange(start: 1, end: 3))
        #expect(TrimRange.clamped(start: -2, end: 9, duration: 5) == TrimRange(start: 0, end: 5))
        #expect(TrimRange.clamped(start: 4, end: 2, duration: 5) == TrimRange(start: 2, end: 4))
        let tiny = TrimRange.clamped(start: 4.99, end: 5, duration: 5)!
        #expect(abs(tiny.length - TrimRange.minimumLength) < 1e-9)
        #expect(tiny.end <= 5)
        #expect(TrimRange.clamped(start: 0, end: 1, duration: 0) == nil)
        #expect(TrimRange.clamped(start: .nan, end: .infinity, duration: 2) == TrimRange(start: 0, end: 2))
        #expect(TrimRange(start: 0, end: 5).isWholeClip(duration: 5))
        #expect(!TrimRange(start: 0.5, end: 5).isWholeClip(duration: 5))
    }

    @Test("REC-15: GIF frames are evenly spaced, capped for long clips, and never upscaled")
    func gifPlan() {
        let options = GIFExportOptions(maxWidth: 640, framesPerSecond: 10, maxFrames: 600)
        let plan = GIFFramePlan.make(range: TrimRange(start: 1, end: 3), options: options)
        #expect(plan.times.count == 20)
        #expect(plan.times.first == 1)
        #expect(plan.times.allSatisfy { $0 >= 1 && $0 < 3 })
        #expect(abs(plan.frameDelay - 0.1) < 1e-9)

        let long = GIFFramePlan.make(range: TrimRange(start: 0, end: 600), options: GIFExportOptions(framesPerSecond: 20, maxFrames: 300))
        #expect(long.times.count == 300)
        #expect(abs(long.frameDelay - 2.0) < 1e-9)

        #expect(GIFExportOptions(maxWidth: 10_000, framesPerSecond: 99).maxWidth == 1280)
        #expect(GIFExportOptions(maxWidth: 1, framesPerSecond: 1).framesPerSecond == 5)
        #expect(GIFFramePlan.outputSize(source: CGSize(width: 1920, height: 1080), maxWidth: 640) == CGSize(width: 640, height: 360))
        #expect(GIFFramePlan.outputSize(source: CGSize(width: 320, height: 200), maxWidth: 640) == CGSize(width: 320, height: 200))
    }

    // MARK: - Settings and permissions

    @MainActor
    @Test("REC-16: settings default to Movies, 30 fps, H.264 .mov with a countdown, microphone off")
    func settings() throws {
        let suite = "zenith-recording-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let home = URL(fileURLWithPath: "/Users/someone", isDirectory: true)
        let settings = ScreenRecordingSettings(userDefaults: defaults, homeDirectory: home)
        #expect(settings.microphone == false)
        #expect(settings.systemAudio)
        #expect(settings.frameRate == .fps30)
        #expect(settings.codec == .h264 && settings.format == .mov)
        #expect(settings.countdown)
        #expect(settings.saveFolder.path == "/Users/someone/Movies")

        var changes = 0
        let token = settings.objectWillChange.sink { changes += 1 }
        settings.frameRate = .fps60
        settings.saveLocation = .desktop
        settings.microphone = true
        #expect(changes == 3)
        _ = token
        #expect(settings.saveFolder.path == "/Users/someone/Desktop")
        let reloaded = ScreenRecordingSettings(userDefaults: defaults, homeDirectory: home)
        #expect(reloaded.frameRate == .fps60 && reloaded.microphone)

        // A custom folder that no longer exists falls back to Movies.
        #expect(ScreenRecordingSettings.folder(for: .custom, custom: URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)"), home: home).path == "/Users/someone/Movies")
        settings.resetToDefaults()
        #expect(settings.saveLocation == .movies && !settings.microphone)
    }

    @MainActor
    @Test("REC-17: the Permissions page lists the microphone, on only while the switch is on")
    func permissions() {
        let suite = "zenith-recording-perm-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = ScreenRecordingSettings(userDefaults: defaults)
        let activity = LiveFeatureActivity(widgets: IslandWidgetSettings(userDefaults: defaults, island: nil), recording: settings)
        #expect(activity.activity(for: .recordingMicrophone) == .off)
        settings.microphone = true
        #expect(activity.activity(for: .recordingMicrophone) == .on)
        #expect(activity.activity(for: .screenRecording) == .alwaysAvailable)
        #expect(ZenithPermissionFeature.recordingMicrophone.permission == .microphone)
        #expect(ZenithPermissionFeature.screenRecording.permission == .screenRecording)
        #expect(ZenithPermissionFeature.scrollingCapture.permission == .accessibility)
        #expect(ZenithPermissionKind.microphone.settingsURL.absoluteString.hasSuffix("Privacy_Microphone"))

        let mock = MockPermissionsService(screenRecordingGranted: true)
        mock.microphoneState = .notDetermined
        let model = ZenithPermissionsModel(permissions: mock, activity: activity, opener: RecordingSettingsOpener())
        #expect(model.statuses.first { $0.kind == .microphone }?.verdict == .neededButMissing)
        mock.microphoneState = .granted
        settings.microphone = false
        model.refresh()
        #expect(model.statuses.first { $0.kind == .microphone }?.verdict == .grantedButUnused)
        #expect(mock.requestScreenRecordingCallCount == 0)
    }

    // MARK: - Writing a real file from made-up samples

    @Test("REC-18: the writer makes one video and one mixed audio track; trim and GIF export read it back")
    func writerTrimAndGIF() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("zenith-rec-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("clip.mov")

        let writer = try RecordingAssetWriter(url: url, format: .mov, width: 128, height: 96, codec: .h264, frameRate: 30, audioSources: [.microphone, .system])
        let start = 1000.0
        // Sound from before the first picture is dropped (there is no timeline yet).
        writer.appendAudio(.system, interleavedStereo: [Float](repeating: 0.1, count: 2048), hostSeconds: start - 1)
        #expect(!writer.hasStarted)

        var audioClock = 0
        for i in 0..<60 {
            let pixelBuffer = try #require(Self.solidPixelBuffer(width: 128, height: 96, gray: UInt8((i * 4) % 256)))
            writer.appendVideo(pixelBuffer, hostSeconds: start + Double(i) / 30)
            // About 1/30 s of sound per frame from each source.
            while Double(audioClock) / 48_000 < Double(i + 1) / 30 {
                let tone = (0..<1024).flatMap { n -> [Float] in
                    let v = Float(sin(Double(audioClock + n) * 2 * .pi * 440 / 48_000) * 0.3)
                    return [v, v]
                }
                writer.appendAudio(.system, interleavedStereo: tone, hostSeconds: start + Double(audioClock) / 48_000)
                writer.appendAudio(.microphone, interleavedStereo: tone, hostSeconds: start + 0.004 + Double(audioClock) / 48_000)
                audioClock += 1024
            }
            try await Task.sleep(for: .milliseconds(2))
        }
        let result = try await writer.finish(endHostSeconds: start + 2.0)
        #expect(abs(result.duration - 2.0) < 0.05)
        #expect(writer.videoFrameCount > 30)

        let asset = AVURLAsset(url: url)
        #expect(try await asset.loadTracks(withMediaType: .video).count == 1)
        #expect(try await asset.loadTracks(withMediaType: .audio).count == 1, "both sources are mixed into one track")
        let duration = try await asset.load(.duration).seconds
        #expect(abs(duration - 2.0) < 0.1)
        #expect(try await RecordingExporter.videoSize(of: url) == CGSize(width: 128, height: 96))

        // Trim to the middle second.
        let trimmed = RecordingExporter.siblingURL(for: url, suffix: "trimmed", pathExtension: "mov")
        try await RecordingExporter.trim(url, range: TrimRange(start: 0.5, end: 1.5), to: trimmed)
        let trimmedDuration = try await RecordingExporter.duration(of: trimmed)
        #expect(abs(trimmedDuration - 1.0) < 0.1)
        #expect(FileManager.default.fileExists(atPath: url.path), "the original is kept")

        // GIF at 10 fps over the whole clip: 20 frames, no wider than the source.
        let gif = RecordingExporter.siblingURL(for: url, suffix: nil, pathExtension: "gif")
        let options = GIFExportOptions(maxWidth: 640, framesPerSecond: 10)
        try await RecordingExporter.exportGIF(url, range: TrimRange(start: 0, end: 2), options: options, to: gif)
        let source = try #require(CGImageSourceCreateWithURL(gif as CFURL, nil))
        #expect(CGImageSourceGetCount(source) == GIFFramePlan.make(range: TrimRange(start: 0, end: 2), options: options).times.count)
        let first = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(first.width == 128)
    }

    @Test("REC-19: a recording without a single frame is an error and leaves no file")
    func writerWithoutFrames() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("zenith-empty-\(UUID().uuidString).mp4")
        let writer = try RecordingAssetWriter(url: url, format: .mp4, width: 64, height: 64, codec: .h264, frameRate: 30, audioSources: [])
        await #expect(throws: ScreenRecordingError.noFramesRecorded) {
            _ = try await writer.finish(endHostSeconds: nil)
        }
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    // MARK: - Helpers

    static func solidPixelBuffer(width: Int, height: Int, gray: UInt8) -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        let attrs: [String: Any] = [kCVPixelBufferIOSurfacePropertiesKey as String: [:]]
        guard CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, attrs as CFDictionary, &buffer) == kCVReturnSuccess,
              let buffer else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        if let base = CVPixelBufferGetBaseAddress(buffer) {
            memset(base, Int32(gray), CVPixelBufferGetBytesPerRow(buffer) * height)
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        return buffer
    }
}

/// A thread-safe counter for `@Sendable` closures.
final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() { lock.withLock { count += 1 } }
    var value: Int { lock.withLock { count } }
}

@MainActor
final class RecorderBox {
    var recorder: ScreenRecorder?
}
