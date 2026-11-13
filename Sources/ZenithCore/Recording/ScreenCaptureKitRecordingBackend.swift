import Foundation
import AVFoundation
import CoreMedia
import CoreGraphics
import ScreenCaptureKit

/// The real recorder: ScreenCaptureKit for the picture and the system sound (macOS 13+), `AVAudioEngine` for the
/// microphone (every supported macOS), `RecordingAssetWriter` for the file. Zenith's own windows are left out of the
/// picture, except the ones the request names (the click rings).
public final class ScreenCaptureKitRecordingBackend: NSObject, ScreenRecordingBackend, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    /// Every sample (picture, system sound, microphone) is handled on this queue, so the writer needs no lock.
    private let queue = DispatchQueue(label: "app.zenith.recording", qos: .userInitiated)
    private let lock = NSLock()

    private var stream: SCStream?
    private var writer: RecordingAssetWriter?
    private var microphone: MicrophoneCapture?
    private var systemConverter: StereoPCMConverter?
    private var systemConverterFormat: AVAudioFormat?
    private var streamStopped = false

    private var _onUnexpectedStop: (@Sendable (Error) -> Void)?
    public var onUnexpectedStop: (@Sendable (Error) -> Void)? {
        get { lock.withLock { _onUnexpectedStop } }
        set { lock.withLock { _onUnexpectedStop = newValue } }
    }

    public override init() {
        super.init()
    }

    public func start(_ request: RecordingRequest) async throws {
        guard CGPreflightScreenCaptureAccess() else { throw ScreenRecordingError.permissionDenied }
        guard lock.withLock({ stream == nil && writer == nil }) else { throw ScreenRecordingError.alreadyRecording }

        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        let filter = try Self.makeFilter(for: request, content: content)

        let size = request.outputPixelSize
        let config = SCStreamConfiguration()
        config.width = size.width
        config.height = size.height
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(request.frameRate.rawValue))
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.showsCursor = request.showsCursor
        config.queueDepth = 6
        config.scalesToFit = true
        if case .region(_, let rect) = request.target {
            config.sourceRect = rect
        }
        if #available(macOS 15, *), case .window = request.target {
            // A window recording cannot include the click rings (they are separate windows); macOS 15 draws its own.
            config.showMouseClicks = request.highlightsClicks
        }
        if request.audio.capturesSystemAudio {
            config.capturesAudio = true
            config.excludesCurrentProcessAudio = true
            config.sampleRate = Int(RecordingAssetWriter.audioSampleRate)
            config.channelCount = RecordingAssetWriter.audioChannels
        }

        let writer = try RecordingAssetWriter(
            url: request.outputURL,
            format: request.format,
            width: size.width,
            height: size.height,
            codec: request.codec,
            frameRate: request.frameRate.rawValue,
            audioSources: Array(request.audio.sources).sorted { $0.rawValue < $1.rawValue }
        )

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        do {
            try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
            if request.audio.capturesSystemAudio {
                try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
            }
        } catch {
            writer.cancel()
            throw ScreenRecordingError.streamFailed(error.localizedDescription)
        }

        lock.withLock {
            self.writer = writer
            self.stream = stream
            self.streamStopped = false
            self.systemConverter = nil
            self.systemConverterFormat = nil
        }

        do {
            try await stream.startCapture()
        } catch {
            lock.withLock {
                self.stream = nil
                self.writer = nil
            }
            writer.cancel()
            throw ScreenRecordingError.streamFailed(error.localizedDescription)
        }

        if request.audio.capturesMicrophone {
            let capture = MicrophoneCapture { [weak self] samples, hostSeconds in
                guard let self else { return }
                self.queue.async {
                    self.lock.withLock { self.writer }?.appendAudio(.microphone, interleavedStereo: samples, hostSeconds: hostSeconds)
                }
            }
            // A missing or busy microphone does not stop the recording; the picture and system sound go on.
            if (try? capture.start()) != nil {
                lock.withLock { microphone = capture }
            } else {
                NSLog("[Zenith] Recording: the microphone could not be started; recording without it.")
            }
        }
    }

    public func stop() async throws -> RecordingResult {
        let endHostSeconds = CMClockGetTime(CMClockGetHostTimeClock()).seconds
        let (stream, writer, microphone, alreadyStopped) = lock.withLock { (self.stream, self.writer, self.microphone, self.streamStopped) }
        guard let writer else { throw ScreenRecordingError.notRecording }

        microphone?.stop()
        if let stream, !alreadyStopped {
            try? await stream.stopCapture()
        }
        // Wait for samples already queued.
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async { continuation.resume() }
        }
        lock.withLock {
            self.stream = nil
            self.writer = nil
            self.microphone = nil
            self.streamStopped = true
        }
        return try await writer.finish(endHostSeconds: endHostSeconds)
    }

    public func cancel() async {
        let (stream, writer, microphone, alreadyStopped) = lock.withLock { (self.stream, self.writer, self.microphone, self.streamStopped) }
        microphone?.stop()
        if let stream, !alreadyStopped {
            try? await stream.stopCapture()
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async { continuation.resume() }
        }
        lock.withLock {
            self.stream = nil
            self.writer = nil
            self.microphone = nil
            self.streamStopped = true
        }
        writer?.cancel()
    }

    // MARK: - Filter

    static func makeFilter(for request: RecordingRequest, content: SCShareableContent) throws -> SCContentFilter {
        switch request.target {
        case .window(let windowID):
            guard let window = content.windows.first(where: { $0.windowID == windowID }) else {
                throw ScreenRecordingError.targetNotFound
            }
            return SCContentFilter(desktopIndependentWindow: window)
        case .display(let displayID), .region(let displayID, _):
            guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
                throw ScreenRecordingError.targetNotFound
            }
            let ownPID = ProcessInfo.processInfo.processIdentifier
            let ownApps = content.applications.filter { $0.processID == ownPID }
            let included = content.windows.filter { request.includedOwnWindowIDs.contains($0.windowID) }
            return SCContentFilter(display: display, excludingApplications: ownApps, exceptingWindows: included)
        }
    }

    // MARK: - SCStreamOutput

    public func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard sampleBuffer.isValid, let writer = lock.withLock({ self.writer }) else { return }
        switch type {
        case .screen:
            guard Self.isCompleteFrame(sampleBuffer), let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
            writer.appendVideo(pixelBuffer, hostSeconds: CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds)
        case .audio:
            guard writer.hasStarted, let pcm = StereoPCMConverter.pcmBuffer(from: sampleBuffer) else { return }
            if systemConverter == nil || systemConverterFormat != pcm.format {
                systemConverter = StereoPCMConverter(inputFormat: pcm.format)
                systemConverterFormat = pcm.format
            }
            guard let samples = systemConverter?.convert(pcm), !samples.isEmpty else { return }
            writer.appendAudio(.system, interleavedStereo: samples, hostSeconds: CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds)
        default:
            break
        }
    }

    /// ScreenCaptureKit also sends "nothing changed" buffers without a picture; only complete frames are written.
    private static func isCompleteFrame(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let first = attachments.first,
              let rawStatus = first[.status] as? Int,
              let status = SCFrameStatus(rawValue: rawStatus) else { return false }
        return status == .complete
    }

    // MARK: - SCStreamDelegate

    public func stream(_ stream: SCStream, didStopWithError error: Error) {
        let callback: (@Sendable (Error) -> Void)? = lock.withLock {
            guard self.stream === stream else { return nil }
            self.streamStopped = true
            return _onUnexpectedStop
        }
        NSLog("[Zenith] Recording stream stopped: \(error.localizedDescription)")
        callback?(error)
    }
}

// MARK: - Microphone

/// The microphone through `AVAudioEngine`, delivered as interleaved stereo 48 kHz with host-clock times.
final class MicrophoneCapture: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private let onSamples: @Sendable ([Float], Double) -> Void
    private var converter: StereoPCMConverter?

    init(onSamples: @escaping @Sendable ([Float], Double) -> Void) {
        self.onSamples = onSamples
    }

    func start() throws {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        // No input device: the format is empty and installing a tap would raise an exception.
        guard format.sampleRate > 0, format.channelCount > 0, let converter = StereoPCMConverter(inputFormat: format) else {
            throw ScreenRecordingError.streamFailed(RecordingAudioNotice.noMicrophoneDevice.message)
        }
        self.converter = converter
        let onSamples = self.onSamples
        input.installTap(onBus: 0, bufferSize: 2048, format: format) { buffer, time in
            let samples = converter.convert(buffer)
            guard !samples.isEmpty else { return }
            let hostSeconds: Double
            if time.isHostTimeValid {
                hostSeconds = AVAudioTime.seconds(forHostTime: time.hostTime)
            } else {
                hostSeconds = CMClockGetTime(CMClockGetHostTimeClock()).seconds - Double(buffer.frameLength) / format.sampleRate
            }
            onSamples(samples, hostSeconds)
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw error
        }
    }

    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }
}

// MARK: - Microphone permission

/// Reads the microphone permission without asking, and asks only when told to. Without
/// `NSMicrophoneUsageDescription` in the Info.plist (`swift run`) asking would end the process, so it reports
/// `.unavailable` and never asks.
public struct AVMicrophoneAuthorizer: MicrophoneAuthorizing {
    public init() {}

    public static var canAsk: Bool {
        Bundle.main.object(forInfoDictionaryKey: "NSMicrophoneUsageDescription") != nil
    }

    public func currentAccess() -> MicrophoneAccess {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return .granted
        case .denied, .restricted: return .denied
        case .notDetermined: return Self.canAsk ? .notDetermined : .unavailable
        @unknown default: return .denied
        }
    }

    public func requestAccess() async -> Bool {
        guard Self.canAsk else { return false }
        return await AVCaptureDevice.requestAccess(for: .audio)
    }
}
