import AppKit
import AVKit
import SwiftUI
import ZenithCore

/// What the result window shows and is doing.
@MainActor
final class RecordingResultModel: ObservableObject {
    @Published var url: URL
    @Published var duration: TimeInterval
    @Published var isWorking = false
    @Published var progress: Double?
    @Published var message: String?
    @Published var lastExport: URL?

    init(url: URL, duration: TimeInterval) {
        self.url = url
        self.duration = duration
    }
}

/// After a recording: plays it, and offers Show in Finder, Trim and Export as GIF. Trimming and GIF export write new
/// files beside the recording; the recording itself is never changed.
@MainActor
final class RecordingResultWindowController: NSObject, NSWindowDelegate {
    static let shared = RecordingResultWindowController()

    private var window: NSWindow?
    private var playerView: AVPlayerView?
    private var model: RecordingResultModel?
    private var gifOptions = GIFExportOptions()
    private var task: Task<Void, Never>?

    func present(_ result: RecordingResult, gifOptions: GIFExportOptions) {
        self.gifOptions = gifOptions
        let model = RecordingResultModel(url: result.url, duration: result.duration)
        self.model = model

        let player = AVPlayerView()
        player.controlsStyle = .inline
        player.showsFullScreenToggleButton = true
        player.player = AVPlayer(url: result.url)
        playerView = player

        let bar = NSHostingView(rootView: RecordingResultBar(
            model: model,
            onReveal: { [weak self] in self?.reveal() },
            onTrim: { [weak self] in self?.trim() },
            onGIF: { [weak self] in self?.exportGIF() },
            onDone: { [weak self] in self?.close() }
        ))

        let container = NSView()
        player.translatesAutoresizingMaskIntoConstraints = false
        bar.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(player)
        container.addSubview(bar)
        NSLayoutConstraint.activate([
            player.topAnchor.constraint(equalTo: container.topAnchor),
            player.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            player.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            bar.topAnchor.constraint(equalTo: player.bottomAnchor),
            bar.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            bar.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])

        let window = self.window ?? {
            let w = NSWindow(
                contentRect: CGRect(x: 0, y: 0, width: 720, height: 500),
                styleMask: [.titled, .closable, .resizable, .miniaturizable],
                backing: .buffered,
                defer: false
            )
            w.isReleasedWhenClosed = false
            w.delegate = self
            w.minSize = CGSize(width: 520, height: 360)
            w.center()
            return w
        }()
        window.title = result.url.lastPathComponent
        window.representedURL = result.url
        window.contentView = container
        self.window = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        task?.cancel()
        playerView?.player?.pause()
        playerView?.player = nil
    }

    private func close() {
        window?.close()
    }

    private func reveal() {
        guard let model else { return }
        NSWorkspace.shared.activateFileViewerSelecting([model.lastExport ?? model.url])
    }

    // MARK: - Trim

    private func trim() {
        guard let playerView, let model, !model.isWorking, playerView.canBeginTrimming else { return }
        playerView.beginTrimming { [weak self] result in
            guard result == .okButton else { return }
            Task { @MainActor in self?.finishTrim() }
        }
    }

    private func finishTrim() {
        guard let model, let item = playerView?.player?.currentItem else { return }
        let start = item.reversePlaybackEndTime.isNumeric ? item.reversePlaybackEndTime.seconds : 0
        let end = item.forwardPlaybackEndTime.isNumeric ? item.forwardPlaybackEndTime.seconds : model.duration
        let duration = item.duration.isNumeric ? item.duration.seconds : model.duration
        guard let range = TrimRange.clamped(start: start, end: end, duration: duration), !range.isWholeClip(duration: duration) else { return }

        let source = model.url
        let destination = RecordingExporter.siblingURL(for: source, suffix: String(localized: "trimmed"), pathExtension: source.pathExtension)
        model.isWorking = true
        model.progress = nil
        model.message = String(localized: "Trimming…")
        task = Task { [weak self] in
            do {
                try await RecordingExporter.trim(source, range: range, to: destination)
                guard let self, let model = self.model else { return }
                model.url = destination
                model.duration = range.length
                model.lastExport = destination
                model.message = String(localized: "Saved \(destination.lastPathComponent)")
                self.playerView?.player = AVPlayer(url: destination)
                self.window?.title = destination.lastPathComponent
                self.window?.representedURL = destination
            } catch {
                self?.model?.message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
            self?.model?.isWorking = false
        }
    }

    // MARK: - GIF

    private func exportGIF() {
        guard let model, !model.isWorking else { return }
        let item = playerView?.player?.currentItem
        let duration = item.map { $0.duration.isNumeric ? $0.duration.seconds : model.duration } ?? model.duration
        guard let range = TrimRange.clamped(start: 0, end: duration, duration: duration) else { return }
        let source = model.url
        let destination = RecordingExporter.siblingURL(for: source, suffix: nil, pathExtension: "gif")
        let options = gifOptions
        model.isWorking = true
        model.progress = 0
        model.message = String(localized: "Making GIF…")
        task = Task { [weak self] in
            do {
                try await RecordingExporter.exportGIF(source, range: range, options: options, to: destination) { fraction in
                    Task { @MainActor in self?.model?.progress = fraction }
                }
                self?.model?.lastExport = destination
                self?.model?.message = String(localized: "Saved \(destination.lastPathComponent)")
            } catch {
                try? FileManager.default.removeItem(at: destination)
                self?.model?.message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
            self?.model?.isWorking = false
            self?.model?.progress = nil
        }
    }
}

struct RecordingResultBar: View {
    @ObservedObject var model: RecordingResultModel
    let onReveal: () -> Void
    let onTrim: () -> Void
    let onGIF: () -> Void
    let onDone: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: model.url.lastPathComponent)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let message = model.message {
                    Text(verbatim: message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                } else {
                    Text(verbatim: model.url.deletingLastPathComponent().path)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
            }
            Spacer(minLength: 8)
            if model.isWorking {
                if let progress = model.progress {
                    ProgressView(value: progress).frame(width: 80)
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            Button("Show in Finder", action: onReveal)
            Button("Trim…", action: onTrim)
                .disabled(model.isWorking)
                .help("Drag the yellow handles to keep only part of the recording. A trimmed copy is saved beside it.")
            Button("Export as GIF", action: onGIF)
                .disabled(model.isWorking)
            Button("Done", action: onDone)
                .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}
