import Foundation
import AVFoundation
import CoreMedia
import CoreVideo

/// Writes the recording file: video frames as they arrive and one mixed stereo AAC track.
///
/// Times are host-clock seconds (what ScreenCaptureKit and `AVAudioEngine` both report). The first video frame is
/// time zero; sound from before it is dropped. Not thread-safe: the backend calls it from one serial queue, and
/// calls `finish` only after the stream and the microphone have stopped.
public final class RecordingAssetWriter: @unchecked Sendable {
    public static let audioSampleRate: Double = 48_000
    public static let audioChannels = 2

    private let writer: AVAssetWriter
    private let videoInput: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private let audioInput: AVAssetWriterInput?
    private var mixer: AudioTimelineMixer?
    private var audioFormat: CMAudioFormatDescription?
    private var pendingAudio: [CMSampleBuffer] = []

    /// Host time of the first video frame.
    public private(set) var timelineStart: Double?
    private var lastVideoTime: CMTime = .negativeInfinity
    private var lastAudioEnd: CMTime = .zero
    public private(set) var videoFrameCount = 0
    public let url: URL

    public init(
        url: URL,
        format: RecordingFileFormat,
        width: Int,
        height: Int,
        codec: RecordingVideoCodec,
        frameRate: Int,
        audioSources: [RecordingAudioSource]
    ) throws {
        self.url = url
        try? FileManager.default.removeItem(at: url)
        writer = try AVAssetWriter(outputURL: url, fileType: format == .mp4 ? .mp4 : .mov)

        let compression: [String: Any] = [
            AVVideoAverageBitRateKey: RecordingGeometry.averageBitRate(width: width, height: height, frameRate: frameRate, codec: codec),
            AVVideoExpectedSourceFrameRateKey: frameRate,
            AVVideoMaxKeyFrameIntervalKey: frameRate * 2
        ]
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: codec == .hevc ? AVVideoCodecType.hevc : AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: compression
        ]
        videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoInput.expectsMediaDataInRealTime = true
        adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: videoInput, sourcePixelBufferAttributes: nil)
        guard writer.canAdd(videoInput) else {
            throw ScreenRecordingError.writerFailed(String(localized: "The video cannot be written in this format."))
        }
        writer.add(videoInput)

        if audioSources.isEmpty {
            audioInput = nil
        } else {
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: Self.audioSampleRate,
                AVNumberOfChannelsKey: Self.audioChannels,
                AVEncoderBitRateKey: 160_000
            ]
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: settings)
            input.expectsMediaDataInRealTime = true
            guard writer.canAdd(input) else {
                throw ScreenRecordingError.writerFailed(String(localized: "The sound cannot be written in this format."))
            }
            writer.add(input)
            audioInput = input
            mixer = AudioTimelineMixer(sources: audioSources, channels: Self.audioChannels, sampleRate: Self.audioSampleRate)
            audioFormat = Self.makeAudioFormat()
        }
        guard writer.startWriting() else {
            throw ScreenRecordingError.writerFailed(writer.error?.localizedDescription ?? String(localized: "The recording file could not be created."))
        }
    }

    public var hasStarted: Bool { timelineStart != nil }

    /// Adds a video frame captured at `hostSeconds`. The first one starts the file's timeline.
    public func appendVideo(_ pixelBuffer: CVPixelBuffer, hostSeconds: Double) {
        guard writer.status == .writing else { return }
        if timelineStart == nil {
            timelineStart = hostSeconds
            writer.startSession(atSourceTime: .zero)
        }
        guard let start = timelineStart else { return }
        let time = CMTime(seconds: hostSeconds - start, preferredTimescale: 600_000)
        guard time > lastVideoTime, videoInput.isReadyForMoreMediaData else { return }
        if adaptor.append(pixelBuffer, withPresentationTime: time) {
            lastVideoTime = time
            videoFrameCount += 1
        }
    }

    /// Adds interleaved stereo 48 kHz samples of one source, the first of them heard at `hostSeconds`.
    public func appendAudio(_ source: RecordingAudioSource, interleavedStereo samples: [Float], hostSeconds: Double) {
        guard writer.status == .writing, mixer != nil, let start = timelineStart else { return }
        let frame = AudioTimelineMixer.frame(forSeconds: hostSeconds, timelineStart: start, sampleRate: Self.audioSampleRate)
        mixer?.append(source, samples: samples, startFrame: frame)
        drainMixer(final: false)
        flushPendingAudio()
    }

    /// Finishes the file. `endHostSeconds` is when the user stopped, so a still last picture lasts until then.
    public func finish(endHostSeconds: Double?) async throws -> RecordingResult {
        guard let start = timelineStart, videoFrameCount > 0 else {
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: url)
            throw ScreenRecordingError.noFramesRecorded
        }
        drainMixer(final: true)
        var attempts = 0
        while !pendingAudio.isEmpty, attempts < 200, writer.status == .writing {
            flushPendingAudio()
            if pendingAudio.isEmpty { break }
            attempts += 1
            try? await Task.sleep(for: .milliseconds(10))
        }
        videoInput.markAsFinished()
        audioInput?.markAsFinished()

        var end = max(lastVideoTime, lastAudioEnd)
        if let endHostSeconds {
            end = max(end, CMTime(seconds: endHostSeconds - start, preferredTimescale: 600_000))
        }
        writer.endSession(atSourceTime: end)
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            writer.finishWriting { continuation.resume() }
        }
        guard writer.status == .completed else {
            throw ScreenRecordingError.writerFailed(writer.error?.localizedDescription ?? String(localized: "The recording file could not be finished."))
        }
        return RecordingResult(url: url, duration: end.seconds)
    }

    /// Stops writing and deletes the unfinished file.
    public func cancel() {
        if writer.status == .writing { writer.cancelWriting() }
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: - Audio

    private func drainMixer(final: Bool) {
        guard var mixer else { return }
        while let chunk = mixer.drain(final: final) {
            if let buffer = makeAudioSampleBuffer(samples: chunk.samples, startFrame: chunk.startFrame) {
                pendingAudio.append(buffer)
            }
            if final { break }
        }
        self.mixer = mixer
    }

    private func flushPendingAudio() {
        guard let audioInput else { return }
        while let next = pendingAudio.first, audioInput.isReadyForMoreMediaData {
            pendingAudio.removeFirst()
            if audioInput.append(next) {
                let end = CMTimeAdd(CMSampleBufferGetPresentationTimeStamp(next), CMSampleBufferGetDuration(next))
                lastAudioEnd = max(lastAudioEnd, end)
            }
        }
    }

    private static func makeAudioFormat() -> CMAudioFormatDescription? {
        var asbd = AudioStreamBasicDescription(
            mSampleRate: audioSampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: UInt32(MemoryLayout<Float>.size * audioChannels),
            mFramesPerPacket: 1,
            mBytesPerFrame: UInt32(MemoryLayout<Float>.size * audioChannels),
            mChannelsPerFrame: UInt32(audioChannels),
            mBitsPerChannel: 32,
            mReserved: 0
        )
        var format: CMAudioFormatDescription?
        CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &asbd, layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &format)
        return format
    }

    private func makeAudioSampleBuffer(samples: [Float], startFrame: Int64) -> CMSampleBuffer? {
        guard let audioFormat, !samples.isEmpty, startFrame >= 0 else { return nil }
        let frames = samples.count / Self.audioChannels
        let byteCount = samples.count * MemoryLayout<Float>.size
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: byteCount, blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil, offsetToData: 0, dataLength: byteCount, flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block
        ) == kCMBlockBufferNoErr, let block else { return nil }
        let copied = samples.withUnsafeBytes { raw in
            CMBlockBufferReplaceDataBytes(with: raw.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: byteCount)
        }
        guard copied == kCMBlockBufferNoErr else { return nil }
        var sampleBuffer: CMSampleBuffer?
        let pts = CMTime(value: startFrame, timescale: CMTimeScale(Self.audioSampleRate))
        guard CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: audioFormat,
            sampleCount: frames, presentationTimeStamp: pts, packetDescriptions: nil, sampleBufferOut: &sampleBuffer
        ) == noErr else { return nil }
        return sampleBuffer
    }
}

// MARK: - PCM conversion

/// Turns any PCM buffer (the microphone's format, ScreenCaptureKit's) into interleaved stereo Float32 at 48 kHz.
/// Not thread-safe; one per source, used from that source's thread.
public final class StereoPCMConverter {
    private let inputFormat: AVAudioFormat
    private let workFormat: AVAudioFormat
    private let converter: AVAudioConverter?

    public init?(inputFormat: AVAudioFormat) {
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else { return nil }
        self.inputFormat = inputFormat
        let channels = AVAudioChannelCount(min(2, inputFormat.channelCount))
        guard let work = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: RecordingAssetWriter.audioSampleRate, channels: channels, interleaved: false) else {
            return nil
        }
        workFormat = work
        if inputFormat.commonFormat == .pcmFormatFloat32, !inputFormat.isInterleaved,
           inputFormat.sampleRate == work.sampleRate, inputFormat.channelCount <= 2 {
            converter = nil
        } else {
            guard let made = AVAudioConverter(from: inputFormat, to: work) else { return nil }
            made.downmix = inputFormat.channelCount > 2
            converter = made
        }
    }

    public func convert(_ buffer: AVAudioPCMBuffer) -> [Float] {
        guard buffer.frameLength > 0 else { return [] }
        let source: AVAudioPCMBuffer
        if let converter {
            let ratio = workFormat.sampleRate / inputFormat.sampleRate
            let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
            guard let out = AVAudioPCMBuffer(pcmFormat: workFormat, frameCapacity: capacity) else { return [] }
            let feeder = OneShotFeeder(buffer)
            var error: NSError?
            converter.convert(to: out, error: &error) { _, status in
                feeder.next(status)
            }
            guard error == nil else { return [] }
            source = out
        } else {
            source = buffer
        }
        guard let data = source.floatChannelData else { return [] }
        let frames = Int(source.frameLength)
        let channels = (0..<Int(source.format.channelCount)).map { UnsafeBufferPointer(start: data[$0], count: frames) }
        return PCMInterleaver.interleavedStereo(channels, frameCount: frames)
    }

    /// Copies the PCM in a ScreenCaptureKit audio sample buffer into an `AVAudioPCMBuffer`.
    public static func pcmBuffer(from sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let description = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(description),
              let format = AVAudioFormat(streamDescription: asbd) else { return nil }
        let frames = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
        guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return nil }
        buffer.frameLength = frames
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(sampleBuffer, at: 0, frameCount: Int32(frames), into: buffer.mutableAudioBufferList)
        return status == noErr ? buffer : nil
    }
}

/// Hands one buffer to `AVAudioConverter`, then says there is no more for now.
private final class OneShotFeeder: @unchecked Sendable {
    private var buffer: AVAudioPCMBuffer?
    init(_ buffer: AVAudioPCMBuffer) { self.buffer = buffer }

    func next(_ status: UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioBuffer? {
        if let buffer {
            self.buffer = nil
            status.pointee = .haveData
            return buffer
        }
        status.pointee = .noDataNow
        return nil
    }
}
