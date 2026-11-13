import Foundation

/// Mixes the system sound and the microphone into one stereo track, so every player (a browser, Slack, VLC) hears
/// both, not only the first audio track of the file.
///
/// Each source hands over interleaved Float32 samples with the timeline frame of their first sample (computed from
/// the host clock). The mixer lines them up on one timeline, sums them and hands back finished stretches. It is a plain
/// value with no locking: the recorder uses it from one serial queue.
public struct AudioTimelineMixer: Sendable {
    public let channels: Int
    public let sampleRate: Double
    /// How far one source may run ahead of a silent one before the silent one is treated as silence.
    public let maxLagFrames: Int64
    /// A chunk that starts within this many frames of where the source's last chunk ended is joined to it, so clock
    /// jitter does not leave clicks (tiny gaps or overlaps) in the sound.
    public let joinToleranceFrames: Int64

    public let sources: [RecordingAudioSource]
    /// Samples not yet mixed, per source, starting at `mixedUpTo`.
    private var pending: [RecordingAudioSource: [Float]] = [:]
    /// The timeline frame where each source's written samples end.
    private var ends: [RecordingAudioSource: Int64] = [:]
    /// Everything before this frame has been handed out.
    public private(set) var mixedUpTo: Int64 = 0

    public init(
        sources: [RecordingAudioSource],
        channels: Int = 2,
        sampleRate: Double = 48_000,
        maxLag: Double = 0.5,
        joinTolerance: Double = 0.05
    ) {
        self.sources = sources
        self.channels = max(1, channels)
        self.sampleRate = sampleRate
        self.maxLagFrames = Int64(maxLag * sampleRate)
        self.joinToleranceFrames = Int64(joinTolerance * sampleRate)
        for source in sources {
            pending[source] = []
        }
    }

    /// The timeline frame for a host-clock time, given the time of frame 0.
    public static func frame(forSeconds seconds: Double, timelineStart: Double, sampleRate: Double) -> Int64 {
        Int64(((seconds - timelineStart) * sampleRate).rounded())
    }

    /// Adds `samples` (interleaved, `channels` per frame) of `source` starting at timeline frame `startFrame`.
    public mutating func append(_ source: RecordingAudioSource, samples: [Float], startFrame: Int64) {
        guard pending[source] != nil, !samples.isEmpty else { return }
        let frameCount = Int64(samples.count / channels)
        guard frameCount > 0 else { return }

        // Join a chunk that arrives a hair early or late to the end of the previous one.
        var start = startFrame
        if let end = ends[source], abs(start - end) <= joinToleranceFrames {
            start = end
        }

        var chunk = samples[0..<Int(frameCount) * channels]
        if start < mixedUpTo {
            let drop = mixedUpTo - start
            guard drop < frameCount else { return }  // entirely in the past
            chunk = chunk.dropFirst(Int(drop) * channels)
            start = mixedUpTo
        }

        let offset = Int(start - mixedUpTo) * channels
        var buffer = pending[source] ?? []
        let needed = offset + chunk.count
        if buffer.count < needed {
            buffer.append(contentsOf: repeatElement(0, count: needed - buffer.count))
        }
        buffer.replaceSubrange(offset..<needed, with: chunk)
        pending[source] = buffer
        ends[source] = max(ends[source] ?? 0, start + Int64(chunk.count / channels))
    }

    /// Mixes and hands out the stretch every source has reached. A source that has fallen more than `maxLag` behind
    /// the others counts as silent. With `final`, everything written is handed out.
    public mutating func drain(final: Bool = false) -> (startFrame: Int64, samples: [Float])? {
        let reached = sources.map { ends[$0] ?? mixedUpTo }
        guard let leader = reached.max(), let slowest = reached.min() else { return nil }
        var readyEnd = final ? leader : slowest
        if !final, leader - readyEnd > maxLagFrames {
            readyEnd = leader - maxLagFrames
        }
        guard readyEnd > mixedUpTo else { return nil }

        let count = Int(readyEnd - mixedUpTo) * channels
        var mixed = [Float](repeating: 0, count: count)
        for source in sources {
            guard var buffer = pending[source], !buffer.isEmpty else { continue }
            let available = min(count, buffer.count)
            for i in 0..<available {
                mixed[i] += buffer[i]
            }
            buffer.removeFirst(available)
            pending[source] = buffer
        }
        if sources.count > 1 {
            for i in 0..<count {
                mixed[i] = min(1, max(-1, mixed[i]))
            }
        }
        let start = mixedUpTo
        mixedUpTo = readyEnd
        return (start, mixed)
    }
}

/// Puts planar channels into one interleaved stereo array (mono is copied to both sides; channels past the second
/// are dropped).
public enum PCMInterleaver {
    public static func interleavedStereo(_ channels: [UnsafeBufferPointer<Float>], frameCount: Int) -> [Float] {
        guard let left = channels.first, frameCount > 0 else { return [] }
        let right = channels.count > 1 ? channels[1] : left
        let n = min(frameCount, left.count, right.count)
        var out = [Float](repeating: 0, count: n * 2)
        for i in 0..<n {
            out[2 * i] = left[i]
            out[2 * i + 1] = right[i]
        }
        return out
    }

    /// The same for arrays (tests and small buffers).
    public static func interleavedStereo(_ channels: [[Float]]) -> [Float] {
        guard let first = channels.first else { return [] }
        let frames = channels.map(\.count).min() ?? first.count
        return channels.withUnsafeBufferPointers { pointers in
            interleavedStereo(pointers, frameCount: frames)
        }
    }
}

private extension Array where Element == [Float] {
    func withUnsafeBufferPointers<R>(_ body: ([UnsafeBufferPointer<Float>]) -> R) -> R {
        var pointers: [UnsafeBufferPointer<Float>] = []
        func recurse(_ index: Int) -> R {
            if index == count { return body(pointers) }
            return self[index].withUnsafeBufferPointer { pointer in
                pointers.append(pointer)
                return recurse(index + 1)
            }
        }
        return recurse(0)
    }
}
