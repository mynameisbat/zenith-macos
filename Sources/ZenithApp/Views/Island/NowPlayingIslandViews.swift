import SwiftUI
import AppKit
import ZenithCore

// MARK: - Closed-island wings
//
// The equalizer moves for as long as a track plays, so its motion is handed to Core Animation: it is one set of layer
// animations that the render server runs. No timer or Task loop ticks and no SwiftUI body is
// evaluated per frame; the SwiftUI views below only start or stop the animations when the playing state changes.

/// Runs layer changes without Core Animation's implicit 0.25 s animations, which standalone sublayers have.
@MainActor
private func withoutLayerActions(_ body: () -> Void) {
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    body()
    CATransaction.commit()
}

/// A layer-backed view whose layers move only while a track plays, the view is in a window and Reduce Motion is off.
@MainActor
class IslandWingLayerView: NSView {
    var isPlaying = false {
        didSet { if isPlaying != oldValue { updateMotion() } }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(displayOptionsChanged(_:)),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    var reducesMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    var shouldMove: Bool { isPlaying && window != nil && !reducesMotion }

    override var isOpaque: Bool { false }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyContentsScale()
        updateMotion()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        applyContentsScale()
    }

    @objc private func displayOptionsChanged(_ notification: Notification) {
        updateMotion()
    }

    /// Starts or stops the animations to match `shouldMove`. Subclasses override it.
    func updateMotion() {}

    /// Called when SwiftUI removes the view (the island opened, the track ended).
    func tearDown() {
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        isPlaying = false
    }

    private func applyContentsScale() {
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        func apply(_ layer: CALayer) {
            layer.contentsScale = scale
            layer.sublayers?.forEach(apply)
        }
        withoutLayerActions { layer?.sublayers?.forEach(apply) }
    }
}

/// The closed island's picture of what plays: the artwork (or the app's symbol on a faint tile) in a 22 pt tile with
/// rounded corners. It is still: a track that plays is told by the equalizer on the other side.
@MainActor
final class ArtworkThumbnailLayerView: IslandWingLayerView {
    static let side: CGFloat = 22
    static let cornerRadius: CGFloat = 6

    private let tile = CALayer()
    private let art = CALayer()
    private let icon = CALayer()
    private var shownArtwork: NSImage?
    private var shownIconName: String?
    private var shownTint: Color?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        let side = Self.side
        tile.bounds = CGRect(x: 0, y: 0, width: side, height: side)
        tile.cornerRadius = Self.cornerRadius
        tile.cornerCurve = .continuous
        tile.masksToBounds = true
        tile.backgroundColor = NSColor(white: 1, alpha: 0.1).cgColor
        tile.borderWidth = 0.5
        tile.borderColor = NSColor(white: 1, alpha: 0.15).cgColor

        art.frame = tile.bounds
        art.contentsGravity = .resizeAspectFill
        icon.contentsGravity = .resizeAspect

        [art, icon].forEach(tile.addSublayer)
        layer?.addSublayer(tile)
    }

    override var intrinsicContentSize: NSSize { NSSize(width: Self.side, height: Self.side) }

    override func layout() {
        super.layout()
        withoutLayerActions { tile.position = CGPoint(x: bounds.midX, y: bounds.midY) }
    }

    /// Shows the artwork, or the app's symbol in its colour when there is none. Does nothing when neither changed.
    func show(artwork: NSImage?, iconName: String, tint: Color) {
        withoutLayerActions {
            if let artwork {
                if artwork !== shownArtwork {
                    art.contents = artwork
                    shownArtwork = artwork
                }
                art.isHidden = false
                icon.isHidden = true
            } else {
                if iconName != shownIconName || tint != shownTint {
                    let symbol = Self.tintedSymbol(iconName, color: NSColor(tint))
                    icon.contents = symbol
                    let size = symbol?.size ?? .zero
                    icon.bounds = CGRect(origin: .zero, size: size)
                    icon.position = CGPoint(x: Self.side / 2, y: Self.side / 2)
                    shownIconName = iconName
                    shownTint = tint
                }
                art.contents = nil
                shownArtwork = nil
                art.isHidden = true
                icon.isHidden = false
            }
        }
    }

    /// The symbol at 11 pt bold, filled with `color` (a symbol image is a template and would draw black in a layer).
    private static func tintedSymbol(_ name: String, color: NSColor) -> NSImage? {
        guard let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 11, weight: .bold)) else { return nil }
        let tinted = NSImage(size: symbol.size)
        tinted.lockFocus()
        let rect = NSRect(origin: .zero, size: symbol.size)
        symbol.draw(in: rect)
        color.set()
        rect.fill(using: .sourceAtop)
        tinted.unlockFocus()
        return tinted
    }
}

/// Four bars, 2.5 pt wide, 2 pt apart, growing up from the bottom of an 18×16 box. While a track plays each bar loops
/// its own fixed levels at its own pace; paused they settle low.
@MainActor
final class EqualizerLayerView: IslandWingLayerView {
    static let size = NSSize(width: 18, height: 16)
    private static let barWidth: CGFloat = 2.5
    private static let barSpacing: CGFloat = 2
    private static let restLevel: CGFloat = 0.25
    /// Shown while playing with Reduce Motion on.
    private static let stillLevels: [CGFloat] = [0.4, 0.8, 0.5, 0.9]
    /// About 180 ms a step, the old random timer's pace. The steps and lengths differ per bar, so the four never line
    /// up into a visible repeat (they come back into phase only after the product of their periods).
    private static let patterns: [(levels: [CGFloat], step: CFTimeInterval)] = [
        ([0.3, 0.85, 0.45, 1.0, 0.25, 0.7, 0.4, 0.95, 0.3], 0.17),
        ([0.35, 1.0, 0.6, 0.8, 0.4, 0.95, 0.5, 0.75, 0.35], 0.19),
        ([0.3, 0.55, 0.9, 0.35, 0.75, 0.25, 0.85, 0.5, 0.3], 0.18),
        ([0.45, 0.9, 0.55, 1.0, 0.6, 0.85, 0.4, 1.0, 0.45], 0.21)
    ]
    private static let bounceKey = "zenith.bounce"
    private static let settleKey = "zenith.settle"

    private var bars: [CALayer] = []
    private var shownColor: Color?

    private static func height(_ level: CGFloat) -> CGFloat { max(3, 14 * level) }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        bars = (0..<4).map { _ in
            let bar = CALayer()
            bar.anchorPoint = CGPoint(x: 0.5, y: 0)   // grows upwards from the bottom
            bar.cornerRadius = 1
            bar.bounds = CGRect(x: 0, y: 0, width: Self.barWidth, height: Self.height(Self.restLevel))
            layer?.addSublayer(bar)
            return bar
        }
    }

    override var intrinsicContentSize: NSSize { Self.size }

    override func layout() {
        super.layout()
        let total = 4 * Self.barWidth + 3 * Self.barSpacing
        let originX = (bounds.width - total) / 2
        withoutLayerActions {
            for (index, bar) in bars.enumerated() {
                let x = originX + CGFloat(index) * (Self.barWidth + Self.barSpacing) + Self.barWidth / 2
                bar.position = CGPoint(x: x, y: 0)
            }
        }
    }

    func setColor(_ color: Color) {
        guard color != shownColor else { return }
        shownColor = color
        var cgColor = NSColor(color).cgColor
        effectiveAppearance.performAsCurrentDrawingAppearance { cgColor = NSColor(color).cgColor }
        withoutLayerActions { bars.forEach { $0.backgroundColor = cgColor } }
    }

    override func updateMotion() {
        if shouldMove { startBouncing() } else { stopBouncing() }
    }

    override func tearDown() {
        super.tearDown()
        bars.forEach { $0.removeAllAnimations() }
    }

    private func startBouncing() {
        guard bars.first?.animation(forKey: Self.bounceKey) == nil else { return }
        for (bar, pattern) in zip(bars, Self.patterns) {
            let heights = pattern.levels.map(Self.height)
            let steps = heights.count - 1
            let bounce = CAKeyframeAnimation(keyPath: "bounds.size.height")
            bounce.values = heights.map { NSNumber(value: Double($0)) }
            bounce.keyTimes = (0...steps).map { NSNumber(value: Double($0) / Double(steps)) }
            bounce.timingFunctions = Array(repeating: CAMediaTimingFunction(name: .easeInEaseOut), count: steps)
            bounce.duration = pattern.step * Double(steps)
            bounce.repeatCount = .infinity
            withoutLayerActions {
                bar.removeAnimation(forKey: Self.settleKey)
                bar.bounds.size.height = heights[0]
                bar.add(bounce, forKey: Self.bounceKey)
            }
        }
    }

    /// Paused: the bars settle low. Playing with Reduce Motion: they hold still at mixed heights.
    private func stopBouncing() {
        let levels = isPlaying ? Self.stillLevels : Array(repeating: Self.restLevel, count: 4)
        let settles = window != nil && !reducesMotion
        for (bar, level) in zip(bars, levels) {
            let target = Self.height(level)
            let current = bar.presentation()?.bounds.height ?? bar.bounds.height
            withoutLayerActions {
                bar.removeAnimation(forKey: Self.bounceKey)
                bar.bounds.size.height = target
            }
            guard settles, abs(current - target) > 0.5 else { continue }
            let settle = CABasicAnimation(keyPath: "bounds.size.height")
            settle.fromValue = NSNumber(value: Double(current))
            settle.toValue = NSNumber(value: Double(target))
            settle.duration = 0.2
            settle.timingFunction = CAMediaTimingFunction(name: .easeOut)
            bar.add(settle, forKey: Self.settleKey)
        }
    }
}

private struct EqualizerWing: NSViewRepresentable {
    let color: Color
    let isPlaying: Bool

    func makeNSView(context: Context) -> EqualizerLayerView {
        EqualizerLayerView(frame: NSRect(origin: .zero, size: EqualizerLayerView.size))
    }

    func updateNSView(_ view: EqualizerLayerView, context: Context) {
        view.setColor(color)
        view.isPlaying = isPlaying
    }

    static func dismantleNSView(_ view: EqualizerLayerView, coordinator: ()) {
        view.tearDown()
    }
}

private struct ThumbnailWing: NSViewRepresentable {
    let track: NowPlayingTrack

    func makeNSView(context: Context) -> ArtworkThumbnailLayerView {
        let side = ArtworkThumbnailLayerView.side
        return ArtworkThumbnailLayerView(frame: NSRect(x: 0, y: 0, width: side, height: side))
    }

    func updateNSView(_ view: ArtworkThumbnailLayerView, context: Context) {
        view.show(
            artwork: track.artworkData.flatMap { IslandArtwork.image(for: $0) },
            iconName: track.app.iconName,
            tint: track.app.brandColor
        )
    }

    static func dismantleNSView(_ view: ArtworkThumbnailLayerView, coordinator: ()) {
        view.tearDown()
    }
}

/// Rhythmic 4-bar equalizer visualizer displayed on the right wing of the Dynamic Island capsule.
public struct NowPlayingVisualizerView: View {
    public let brandColor: Color
    public let isPlaying: Bool

    public init(brandColor: Color = ZenithTheme.accent, isPlaying: Bool = true) {
        self.brandColor = brandColor
        self.isPlaying = isPlaying
    }

    public var body: some View {
        EqualizerWing(color: brandColor, isPlaying: isPlaying)
            .frame(width: EqualizerLayerView.size.width, height: EqualizerLayerView.size.height)
    }
}

/// Album artwork (or the app's symbol), in a small rounded tile, shown on the left wing of the Dynamic Island.
public struct NowPlayingCompactDiscView: View {
    public let track: NowPlayingTrack

    public init(track: NowPlayingTrack) {
        self.track = track
    }

    public var body: some View {
        ThumbnailWing(track: track)
            .frame(width: ArtworkThumbnailLayerView.side, height: ArtworkThumbnailLayerView.side)
    }
}

// MARK: - Expanded Media Player View

/// The Now Playing card: a rounded card tinted with the colour of the cover at 10 %, the cover with a soft glow of its
/// own colours behind it, and beside it the title, the player, the progress bar and the controls.
///
/// The colour and the glow come from `IslandArtwork.palette(for:)`, worked out once per cover; this view is
/// re-evaluated about once a second while a track plays and only looks them up.
public struct NowPlayingExpandedView: View {
    public let track: NowPlayingTrack
    public var onPrevious: () -> Void
    public var onTogglePlayPause: () -> Void
    public var onNext: () -> Void
    public var onSeek: (TimeInterval) -> Void

    @StateObject private var scrub = ScrubState()

    static let artworkSide: CGFloat = 60

    public init(
        track: NowPlayingTrack,
        onPrevious: @escaping () -> Void = {},
        onTogglePlayPause: @escaping () -> Void = {},
        onNext: @escaping () -> Void = {},
        onSeek: @escaping (TimeInterval) -> Void = { _ in }
    ) {
        self.track = track
        self.onPrevious = onPrevious
        self.onTogglePlayPause = onTogglePlayPause
        self.onNext = onNext
        self.onSeek = onSeek
    }

    /// Where the bar is drawn: under the pointer while it is being dragged, else where the track is.
    private var shownProgress: Double {
        scrub.fraction ?? track.progress
    }

    private var canScrub: Bool {
        track.canSeek && track.duration > 0
    }

    private var palette: ArtworkPalette? {
        track.artworkData.flatMap { IslandArtwork.palette(for: $0) }
    }

    /// The cover's colour; the player's own when there is no cover.
    private var tint: Color {
        palette?.color ?? track.app.brandColor
    }

    public var body: some View {
        let cardShape = RoundedRectangle(cornerRadius: 20, style: .continuous)
        return HStack(spacing: 10) {
            artworkView

            // The title and the controls share the first row and the progress bar runs under both, so the card stays
            // as tall as the cover.
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    titleBlock
                    controlsRow
                }
                progressRow
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(cardShape.fill(tint.opacity(0.10)))
        .overlay(cardShape.strokeBorder(Color.white.opacity(0.07), lineWidth: 1))
        .padding(.horizontal, 14)
    }

    // MARK: Pieces

    /// The title, and under it "Artist · Album" with the player's own symbol in front, so the player is named to
    /// VoiceOver and shown by its colour without a chip that would not fit. The line is cut at its end when it is
    /// too long, so the artist is what stays; the player's name is in the tooltip.
    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(verbatim: track.title)
                .font(.system(size: 14, weight: .semibold))
                .tracking(-0.15)
                .foregroundColor(.white)
                .lineLimit(1)

            HStack(spacing: 4) {
                Image(systemName: track.app.iconName)
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundColor(track.app.brandColor)
                    .accessibilityHidden(true)
                Text(verbatim: subtitle)
                    .font(.system(size: 11.5))
                    .foregroundColor(.white.opacity(0.62))
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .help(Text(verbatim: ([track.app.displayName] + [track.album].compactMap { $0 }).joined(separator: " · ")))
    }

    /// "Artist · Album", or the artist alone when the player does not say which album it is.
    private var subtitle: String {
        [track.artist, track.album ?? ""].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    private var progressRow: some View {
        HStack(spacing: 6) {
            if track.duration > 0 {
                timeLabel(scrub.fraction.map { NowPlayingTrack.formatTime($0 * track.duration) } ?? track.formattedPosition)
                    .frame(minWidth: 26, alignment: .leading)
                progressBar
                timeLabel(track.formattedDuration)
                    .frame(minWidth: 26, alignment: .trailing)
            } else {
                // Audio detected from a browser has no known length or position.
                timeLabel(String(localized: "Playing now"))
                progressBar
            }
        }
    }

    /// A 4 pt bar (6 while it is dragged); the whole 16 pt row takes the drag.
    private var progressBar: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.white.opacity(0.14))

                Capsule()
                    .fill(Color.white)
                    .frame(width: max(0, geo.size.width * CGFloat(shownProgress)))
            }
            .frame(height: scrub.fraction == nil ? 4 : 6)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard canScrub, geo.size.width > 0 else { return }
                        scrub.fraction = min(1, max(0, Double(value.location.x / geo.size.width)))
                    }
                    .onEnded { _ in
                        if let fraction = scrub.fraction, canScrub {
                            onSeek(fraction * track.duration)
                        }
                        scrub.fraction = nil
                    }
            )
            .animation(.easeOut(duration: 0.12), value: scrub.fraction == nil)
        }
        .frame(height: 16)
        .padding(.vertical, -4)
        .accessibilityElement()
        .accessibilityLabel("Playback position")
        .accessibilityValue(Text(verbatim: track.formattedPosition))
        .accessibilityAdjustableAction { direction in
            guard canScrub else { return }
            onSeek(track.position + (direction == .increment ? 10 : -10))
        }
    }

    private var controlsRow: some View {
        HStack(spacing: 0) {
            controlButton("backward.fill", label: "Previous track", isEnabled: track.canSkipPrevious, action: onPrevious)

            Button {
                onTogglePlayPause()
            } label: {
                ZStack {
                    Circle()
                        .fill(Color.white)
                        .frame(width: 32, height: 32)
                        .shadow(color: tint.opacity(0.35), radius: 7, x: 0, y: 2)
                    Image(systemName: track.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 13.5, weight: .bold))
                        .foregroundColor(.black)
                        .offset(x: track.isPlaying ? 0 : 1.2)
                }
                .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help(track.isPlaying ? "Pause" : "Play")
            .accessibilityLabel(track.isPlaying ? "Pause" : "Play")

            controlButton("forward.fill", label: "Next track", isEnabled: track.canSkipNext, action: onNext)
        }
        .fixedSize()
    }

    /// A command the player does not take stays in its place, dimmed, so the play button does not move.
    private func controlButton(_ symbol: String, label: LocalizedStringKey, isEnabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12.5))
                .foregroundColor(.white.opacity(isEnabled ? 0.85 : 0.22))
                .frame(width: 28, height: 34)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .help(label)
        .accessibilityLabel(label)
    }

    private func timeLabel(_ text: String) -> some View {
        Text(verbatim: text)
            .font(.system(size: 10).monospacedDigit())
            .foregroundColor(.white.opacity(0.55))
            .lineLimit(1)
            .allowsHitTesting(false)
    }

    private var artworkView: some View {
        let side = Self.artworkSide
        let shape = RoundedRectangle(cornerRadius: 13, style: .continuous)
        return ZStack {
            // A soft glow in the cover's own colours: the cover reduced to 16 × 16, scaled up smoothly and faded out
            // towards its edge. No blur filter to run.
            if let glow = palette?.glow {
                Image(decorative: glow, scale: 1)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: side + 18, height: side + 18)
                    .mask(
                        RadialGradient(colors: [.white, .white.opacity(0)], center: .center, startRadius: side * 0.3, endRadius: (side + 18) / 2)
                    )
                    .opacity(0.75)
                    .accessibilityHidden(true)
            }

            ZStack {
                shape.fill(Color.white.opacity(0.06))
                if let data = track.artworkData, let nsImage = IslandArtwork.image(for: data) {
                    Image(nsImage: nsImage)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: side, height: side)
                        .clipShape(shape)
                } else {
                    Image(systemName: track.app.iconName)
                        .font(.system(size: 24))
                        .foregroundColor(track.app.brandColor)
                }
            }
            .frame(width: side, height: side)
            .overlay(shape.strokeBorder(Color.white.opacity(0.15), lineWidth: 1))
        }
        .frame(width: side, height: side)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Artwork")
    }
}

/// The position under the pointer while the progress bar is dragged, as a share of the track.
@MainActor
final class ScrubState: ObservableObject {
    @Published var fraction: Double?
}

/// Decoded artwork, kept for the few most recent tracks, with the colour worked out from each. The island's views
/// are re-evaluated about once a second while a track plays (its position moves); decoding the picture, or
/// reducing it to its colour, on each of those would be wasted work, so both happen once per cover.
@MainActor
enum IslandArtwork {
    private final class Entry {
        let image: NSImage
        /// `nil` until asked for; `.some(nil)` when the picture has no colour to take (and is not tried again).
        var palette: ArtworkPalette??

        init(image: NSImage) { self.image = image }
    }

    private static let cache: NSCache<NSData, Entry> = {
        let cache = NSCache<NSData, Entry>()
        cache.countLimit = 8
        return cache
    }()

    private static func entry(for data: Data) -> Entry? {
        let key = data as NSData
        if let cached = cache.object(forKey: key) { return cached }
        guard let image = NSImage(data: data) else { return nil }
        let entry = Entry(image: image)
        cache.setObject(entry, forKey: key)
        return entry
    }

    static func image(for data: Data) -> NSImage? {
        entry(for: data)?.image
    }

    /// The cover's dominant colour and glow, computed the first time and kept with the decoded picture.
    static func palette(for data: Data) -> ArtworkPalette? {
        guard let entry = entry(for: data) else { return nil }
        if let known = entry.palette { return known }
        var rect = CGRect(origin: .zero, size: entry.image.size)
        let palette = entry.image.cgImage(forProposedRect: &rect, context: nil, hints: nil).flatMap(ArtworkPalette.make(from:))
        entry.palette = .some(palette)
        return palette
    }
}
