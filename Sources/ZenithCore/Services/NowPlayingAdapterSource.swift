import Foundation

// MARK: - What the adapter reports

/// One reading of the system's Now Playing session, as `ZenithNowPlayingAdapter` printed it.
public struct NowPlayingSnapshot: Sendable, Equatable {
    public var processID: Int32?
    public var bundleIdentifier: String?
    /// The app a helper process plays for (Safari's audio lives in `com.apple.WebKit.GPU`).
    public var parentBundleIdentifier: String?
    public var title: String?
    public var artist: String?
    public var album: String?
    public var duration: TimeInterval
    /// Position at `receivedAt`.
    public var elapsed: TimeInterval
    public var rate: Double
    public var isPlaying: Bool
    public var artworkData: Data?
    /// Which commands the player takes; nil when it did not say.
    public var canSkipNext: Bool?
    public var canSkipPrevious: Bool?
    public var canSeek: Bool?
    public var receivedAt: Date

    public init(
        processID: Int32? = nil,
        bundleIdentifier: String? = nil,
        parentBundleIdentifier: String? = nil,
        title: String? = nil,
        artist: String? = nil,
        album: String? = nil,
        duration: TimeInterval = 0,
        elapsed: TimeInterval = 0,
        rate: Double = 1,
        isPlaying: Bool = true,
        artworkData: Data? = nil,
        canSkipNext: Bool? = nil,
        canSkipPrevious: Bool? = nil,
        canSeek: Bool? = nil,
        receivedAt: Date = Date()
    ) {
        self.processID = processID
        self.bundleIdentifier = bundleIdentifier
        self.parentBundleIdentifier = parentBundleIdentifier
        self.title = title
        self.artist = artist
        self.album = album
        self.duration = duration
        self.elapsed = elapsed
        self.rate = rate
        self.isPlaying = isPlaying
        self.artworkData = artworkData
        self.canSkipNext = canSkipNext
        self.canSkipPrevious = canSkipPrevious
        self.canSeek = canSeek
        self.receivedAt = receivedAt
    }

    /// The app to show: the one a helper belongs to, when the session names it.
    public var applicationBundleIdentifier: String? {
        parentBundleIdentifier ?? bundleIdentifier
    }

    /// Where the song is at `date`. The adapter only speaks when something changes, so a playing song is moved
    /// forward from its last reading.
    public func position(at date: Date) -> TimeInterval {
        guard isPlaying else { return elapsed }
        let moved = elapsed + max(0, date.timeIntervalSince(receivedAt)) * max(0, rate == 0 ? 1 : rate)
        return duration > 0 ? min(moved, duration) : moved
    }
}

public enum NowPlayingAdapterMessage: Sendable, Equatable {
    /// The session changed. `nil` means nothing is playing or paused anywhere.
    case snapshot(NowPlayingSnapshot?)
    /// The answer to a playback command: `sent` is false when the system refused it.
    case commandResult(MediaKey, sent: Bool)
    /// The adapter stopped answering (it could not start, or it quit). Readings before this are stale.
    case unavailable

    /// Parses one line of the adapter's output. `previousArtwork` is the picture of the last snapshot, which the
    /// adapter refers to instead of sending it again. Returns nil for a line that is not understood.
    public static func parse(line: Data, previousArtwork: Data?, now: Date = Date()) -> NowPlayingAdapterMessage? {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { return nil }

        if object["error"] != nil { return .unavailable }

        if let command = object["command"] as? String {
            guard let key = MediaKey(adapterCommand: command) else { return nil }
            return .commandResult(key, sent: object["sent"] as? Bool ?? false)
        }

        func text(_ key: String) -> String? {
            let value = (object[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            return value?.isEmpty == false ? value : nil
        }
        func number(_ key: String) -> Double? {
            guard let value = (object[key] as? NSNumber)?.doubleValue, value.isFinite else { return nil }
            return value
        }

        let processID = (object["pid"] as? NSNumber)?.int32Value
        let title = text("title")
        let artist = text("artist")
        guard processID != nil || title != nil || artist != nil else { return .snapshot(nil) }

        let artwork: Data?
        if object["artworkSame"] as? Bool == true {
            artwork = previousArtwork
        } else {
            artwork = (object["artwork"] as? String).flatMap { Data(base64Encoded: $0) }
        }

        return .snapshot(NowPlayingSnapshot(
            processID: processID,
            bundleIdentifier: text("bundleID"),
            parentBundleIdentifier: text("parentBundleID"),
            title: title,
            artist: artist,
            album: text("album"),
            duration: max(0, number("duration") ?? 0),
            elapsed: max(0, number("elapsed") ?? 0),
            rate: number("rate") ?? 0,
            isPlaying: object["playing"] as? Bool ?? false,
            artworkData: artwork,
            canSkipNext: object["canNext"] as? Bool,
            canSkipPrevious: object["canPrevious"] as? Bool,
            canSeek: object["canSeek"] as? Bool,
            receivedAt: now
        ))
    }
}

extension MediaKey {
    /// The word the adapter takes on its standard input for this key.
    var adapterCommand: String {
        switch self {
        case .playPause: return "toggle"
        case .next: return "next"
        case .previous: return "previous"
        }
    }

    init?(adapterCommand: String) {
        switch adapterCommand {
        case "toggle": self = .playPause
        case "next": self = .next
        case "previous": self = .previous
        default: return nil
        }
    }
}

/// Cuts a byte stream into lines. A line longer than `maximumLineLength` is dropped whole, so a misbehaving
/// process cannot make the buffer grow without end.
struct NowPlayingLineFramer {
    private var buffer = Data()
    private var isDiscarding = false
    let maximumLineLength: Int

    init(maximumLineLength: Int = 8 * 1_024 * 1_024) {
        self.maximumLineLength = maximumLineLength
    }

    mutating func append(_ data: Data) -> [Data] {
        var lines: [Data] = []
        var rest = data[...]
        while let newline = rest.firstIndex(of: 0x0A) {
            let piece = rest[rest.startIndex..<newline]
            rest = rest[rest.index(after: newline)...]
            if isDiscarding {
                isDiscarding = false
            } else if buffer.count + piece.count <= maximumLineLength {
                buffer.append(piece)
                if !buffer.isEmpty { lines.append(buffer) }
            }
            buffer = Data()
        }
        if !isDiscarding {
            if buffer.count + rest.count > maximumLineLength {
                buffer = Data()
                isDiscarding = true
            } else {
                buffer.append(rest)
            }
        }
        return lines
    }
}

// MARK: - Where the readings come from

/// A live feed of the system's Now Playing session. `NowPlayingService` takes one in `init`; tests use
/// `MockNowPlayingSource`.
public protocol NowPlayingSource: AnyObject, Sendable {
    /// Starts the feed. `onMessage` may be called on any thread.
    func start(onMessage: @escaping @Sendable (NowPlayingAdapterMessage) -> Void)
    func stop()
    /// Asks the system to pass a playback command to the playing app. Returns whether it could be handed over; the
    /// system's own answer arrives later as `.commandResult`.
    @discardableResult
    func send(_ key: MediaKey) -> Bool
    /// Asks the playing app to move to `position` seconds. Returns whether it could be handed over.
    @discardableResult
    func seek(to position: TimeInterval) -> Bool
}

/// Reads Now Playing through `/usr/bin/perl` loading `libZenithNowPlayingAdapter.dylib`.
///
/// macOS 15.4+ answers MediaRemote only for processes Apple signed; perl is one, Zenith is not. One perl process
/// stays up while monitoring is on and prints a line per change, so nothing is polled. It ends by itself when its
/// standard input closes, which covers the app being killed.
public final class PerlNowPlayingSource: NowPlayingSource, @unchecked Sendable {
    static let libraryName = "libZenithNowPlayingAdapter.dylib"
    static let perlPath = "/usr/bin/perl"

    /// Loads the library named by the first argument and calls its `zenith_now_playing_<mode>` entry point.
    static let loaderScript = """
    use strict; use warnings; use DynaLoader; $| = 1;
    my ($library, $mode) = @ARGV;
    my $handle = DynaLoader::dl_load_file($library, 0) or die DynaLoader::dl_error();
    my $symbol = DynaLoader::dl_find_symbol($handle, "zenith_now_playing_$mode") or die DynaLoader::dl_error();
    DynaLoader::dl_install_xsub("main::zenith_now_playing_run", $symbol);
    zenith_now_playing_run();
    """

    /// After this many starts in a row that never produced a reading, the source gives up until the next `start`.
    static let maximumFailedStarts = 5

    private let libraryURL: URL
    private let queue = DispatchQueue(label: "zenith.now-playing-source")

    // All of the following are touched only on `queue`.
    private var onMessage: (@Sendable (NowPlayingAdapterMessage) -> Void)?
    private var process: Process?
    private var commandPipe: FileHandle?
    private var framer = NowPlayingLineFramer()
    private var lastArtwork: Data?
    private var failedStarts = 0
    private var generation = 0

    public init(libraryURL: URL) {
        self.libraryURL = libraryURL
    }

    /// The source for this app, or nil when the adapter library is not next to it (a `swift run` that built only
    /// the executable) or perl is missing.
    public static func bundled(bundle: Bundle = .main, fileManager: FileManager = .default) -> PerlNowPlayingSource? {
        guard fileManager.isExecutableFile(atPath: perlPath),
              let library = libraryLocation(bundle: bundle, fileManager: fileManager) else { return nil }
        return PerlNowPlayingSource(libraryURL: library)
    }

    /// `Contents/Frameworks` in the app bundle, or beside the executable for a SwiftPM build.
    static func libraryLocation(bundle: Bundle, fileManager: FileManager) -> URL? {
        let candidates = [
            bundle.privateFrameworksURL,
            bundle.executableURL?.resolvingSymlinksInPath().deletingLastPathComponent()
        ]
        return candidates
            .compactMap { $0?.appendingPathComponent(libraryName) }
            .first { fileManager.fileExists(atPath: $0.path) }
    }

    public func start(onMessage: @escaping @Sendable (NowPlayingAdapterMessage) -> Void) {
        queue.async { [self] in
            guard process == nil else { return }
            self.onMessage = onMessage
            failedStarts = 0
            launch()
        }
    }

    public func stop() {
        queue.async { [self] in
            generation += 1
            onMessage = nil
            shutDownProcess()
        }
    }

    @discardableResult
    public func send(_ key: MediaKey) -> Bool {
        write(key.adapterCommand)
    }

    @discardableResult
    public func seek(to position: TimeInterval) -> Bool {
        guard position.isFinite, position >= 0 else { return false }
        return write("seek " + String(format: "%.3f", locale: Locale(identifier: "en_US_POSIX"), position))
    }

    private func write(_ command: String) -> Bool {
        queue.sync {
            guard let pipe = commandPipe, process?.isRunning == true else { return false }
            do {
                try pipe.write(contentsOf: Data((command + "\n").utf8))
                return true
            } catch {
                return false
            }
        }
    }

    private func launch() {
        generation += 1
        let launchGeneration = generation
        framer = NowPlayingLineFramer()
        lastArtwork = nil

        let process = Process()
        let output = Pipe()
        let input = Pipe()
        process.executableURL = URL(fileURLWithPath: Self.perlPath)
        process.arguments = ["-e", Self.loaderScript, libraryURL.path, "watch"]
        // The user's PERL5LIB / PERL5OPT must not reach a script that only needs perl's own DynaLoader.
        process.environment = ["PATH": "/usr/bin:/bin"]
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice

        // Writing a command just as perl exits must be an error, never a SIGPIPE that ends the app.
        _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)

        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            self?.queue.async { [weak self] in self?.receive(data, generation: launchGeneration) }
        }
        process.terminationHandler = { [weak self] _ in
            self?.queue.async { [weak self] in self?.processEnded(generation: launchGeneration) }
        }

        do {
            try process.run()
            self.process = process
            self.commandPipe = input.fileHandleForWriting
        } catch {
            output.fileHandleForReading.readabilityHandler = nil
            processEnded(generation: launchGeneration)
        }
    }

    private func receive(_ data: Data, generation: Int) {
        guard generation == self.generation else { return }
        for line in framer.append(data) {
            guard let message = NowPlayingAdapterMessage.parse(line: line, previousArtwork: lastArtwork) else { continue }
            if case .snapshot(let snapshot) = message {
                lastArtwork = snapshot?.artworkData
                failedStarts = 0
            }
            onMessage?(message)
        }
    }

    private func processEnded(generation: Int) {
        guard generation == self.generation else { return }
        shutDownProcess()
        onMessage?(.unavailable)

        failedStarts += 1
        guard failedStarts < Self.maximumFailedStarts else { return }
        let delay = min(pow(2, Double(failedStarts - 1)), 30)
        queue.asyncAfter(deadline: .now() + delay) { [self] in
            guard generation == self.generation, onMessage != nil, process == nil else { return }
            launch()
        }
    }

    private func shutDownProcess() {
        try? commandPipe?.close()   // the adapter exits when its standard input closes
        commandPipe = nil
        if let process, process.isRunning { process.terminate() }
        process = nil
    }

    deinit {
        try? commandPipe?.close()
        if let process, process.isRunning { process.terminate() }
    }
}
