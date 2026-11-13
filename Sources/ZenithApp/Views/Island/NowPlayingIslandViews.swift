import SwiftUI
import AppKit
import ZenithCore

// MARK: - Closed-island wings
//
// The disc and the equalizer move for as long as a track plays, so their motion is handed to Core Animation: each is
// one set of layer animations that the render server runs. No timer or Task loop ticks and no SwiftUI body is
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

/// The vinyl disc: an 18 pt groove, the artwork (or the app's symbol) in a 14 pt circle and a spindle hole. The whole
/// disc layer turns with one repeating rotation animation; pausing reads where it is and leaves it there.
@MainActor
final class SpinningDiscLayerView: IslandWingLayerView {
    static let side: CGFloat = 18
    /// 60° a second, the speed the old 20 Hz timer turned it at (3° every 50 ms).
    private static let secondsPerTurn: CFTimeInterval = 6
    private static let spinKey = "zenith.spin"

    private let disc = CALayer()
    private let art = CALayer()
    private let icon = CALayer()
    private var restAngle: CGFloat = 0
    private var shownArtwork: NSImage?
    private var shownIconName: String?
    private var shownTint: Color?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        let side = Self.side
        disc.bounds = CGRect(x: 0, y: 0, width: side, height: side)

        let groove = CAShapeLayer()
        groove.frame = disc.bounds
        groove.path = CGPath(ellipseIn: disc.bounds, transform: nil)
        groove.fillColor = NSColor(white: 0.12, alpha: 1).cgColor
        groove.strokeColor = NSColor(white: 1, alpha: 0.15).cgColor
        groove.lineWidth = 0.5

        art.frame = CGRect(x: 2, y: 2, width: 14, height: 14)
        art.cornerRadius = 7
        art.masksToBounds = true
        art.contentsGravity = .resizeAspectFill

        icon.contentsGravity = .resizeAspect

        let spindle = CAShapeLayer()
        let hole = CGRect(x: (side - 3.5) / 2, y: (side - 3.5) / 2, width: 3.5, height: 3.5)
        spindle.path = CGPath(ellipseIn: hole, transform: nil)
        spindle.fillColor = NSColor.black.cgColor
        spindle.frame = disc.bounds

        [groove, art, icon, spindle].forEach(disc.addSublayer)
        layer?.addSublayer(disc)
    }

    override var intrinsicContentSize: NSSize { NSSize(width: Self.side, height: Self.side) }

    override func layout() {
        super.layout()
        withoutLayerActions { disc.position = CGPoint(x: bounds.midX, y: bounds.midY) }
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

    override func updateMotion() {
        if shouldMove { startSpinning() } else { stopSpinning() }
    }

    override func tearDown() {
        super.tearDown()
        disc.removeAllAnimations()
    }

    private func startSpinning() {
        guard disc.animation(forKey: Self.spinKey) == nil else { return }
        let spin = CABasicAnimation(keyPath: "transform.rotation.z")
        spin.fromValue = NSNumber(value: Double(restAngle))
        // Clockwise, as SwiftUI's positive `rotationEffect` turned it (a layer's positive angle is anticlockwise).
        spin.toValue = NSNumber(value: Double(restAngle - 2 * .pi))
        spin.duration = Self.secondsPerTurn
        spin.repeatCount = .infinity
        spin.timingFunction = CAMediaTimingFunction(name: .linear)
        disc.add(spin, forKey: Self.spinKey)
    }

    /// Leaves the disc at the angle it had reached, so resuming continues from there.
    private func stopSpinning() {
        guard disc.animation(forKey: Self.spinKey) != nil else { return }
        if let angle = disc.presentation()?.value(forKeyPath: "transform.rotation.z") as? NSNumber {
            restAngle = CGFloat(angle.doubleValue)
        }
        withoutLayerActions {
            disc.transform = CATransform3DMakeRotation(restAngle, 0, 0, 1)
            disc.removeAnimation(forKey: Self.spinKey)
        }
    }

    /// The symbol at 8 pt bold, filled with `color` (a symbol image is a template and would draw black in a layer).
    private static func tintedSymbol(_ name: String, color: NSColor) -> NSImage? {
        guard let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 8, weight: .bold)) else { return nil }
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

private struct DiscWing: NSViewRepresentable {
    let track: NowPlayingTrack

    func makeNSView(context: Context) -> SpinningDiscLayerView {
        let side = SpinningDiscLayerView.side
        return SpinningDiscLayerView(frame: NSRect(x: 0, y: 0, width: side, height: side))
    }

    func updateNSView(_ view: SpinningDiscLayerView, context: Context) {
        view.show(
            artwork: track.artworkData.flatMap { IslandArtwork.image(for: $0) },
            iconName: track.app.iconName,
            tint: track.app.brandColor
        )
        view.isPlaying = track.isPlaying
    }

    static func dismantleNSView(_ view: SpinningDiscLayerView, coordinator: ()) {
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

/// Compact vinyl disc / album artwork shown on the left wing of the Dynamic Island.
public struct NowPlayingCompactDiscView: View {
    public let track: NowPlayingTrack

    public init(track: NowPlayingTrack) {
        self.track = track
    }

    public var body: some View {
        DiscWing(track: track)
            .frame(width: SpinningDiscLayerView.side, height: SpinningDiscLayerView.side)
    }
}

// MARK: - Expanded Media Player View

public struct NowPlayingExpandedView: View {
    public let track: NowPlayingTrack
    public var onPrevious: () -> Void
    public var onTogglePlayPause: () -> Void
    public var onNext: () -> Void
    public var onSeek: (TimeInterval) -> Void

    @StateObject private var scrub = ScrubState()

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

    /// The island panel is 96 pt high and the top of a notched display's hardware notch hides the first ~32 pt of it,
    /// so this view gets about 60 pt. Everything, controls included, has to fit in that: anything lower is outside the
    /// panel and can be neither seen nor clicked.
    public var body: some View {
        HStack(spacing: 10) {
            artworkView

            VStack(alignment: .leading, spacing: 3) {
                // Title, artist and the app it comes from
                HStack(spacing: 6) {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(track.title)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(.white)
                            .lineLimit(1)

                        Text(track.artist + (track.album != nil ? " • \(track.album!)" : ""))
                            .font(.system(size: 9.5, weight: .regular))
                            .foregroundColor(.white.opacity(0.68))
                            .lineLimit(1)
                    }

                    Spacer(minLength: 4)

                    HStack(spacing: 3) {
                        Image(systemName: track.app.iconName)
                            .font(.system(size: 8.5))
                        Text(track.app.displayName)
                            .font(.system(size: 9, weight: .bold))
                    }
                    .foregroundColor(track.app.brandColor)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        Capsule()
                            .fill(track.app.brandColor.opacity(0.16))
                    )
                }

                // Progress bar
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(Color.white.opacity(0.15))

                        Capsule()
                            .fill(track.app.brandColor)
                            .frame(width: max(0, geo.size.width * CGFloat(shownProgress)))
                    }
                    .frame(height: scrub.fraction == nil ? 3 : 5)
                    .frame(maxHeight: .infinity)
                    // The bar is 3 pt high; the whole 9 pt row takes the drag.
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
                .frame(height: 9)
                .padding(.vertical, -3)
                .accessibilityElement()
                .accessibilityLabel("Playback position")
                .accessibilityValue(Text(verbatim: track.formattedPosition))
                .accessibilityAdjustableAction { direction in
                    guard canScrub else { return }
                    onSeek(track.position + (direction == .increment ? 10 : -10))
                }

                // Controls in the middle, times (or "Playing now") at the sides
                ZStack {
                    HStack(spacing: 18) {
                        controlButton("backward.fill", label: "Previous track", isEnabled: track.canSkipPrevious, action: onPrevious)

                        Button {
                            onTogglePlayPause()
                        } label: {
                            ZStack {
                                Circle()
                                    .fill(Color.white)
                                    .frame(width: 22, height: 22)
                                Image(systemName: track.isPlaying ? "pause.fill" : "play.fill")
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundColor(.black)
                                    .offset(x: track.isPlaying ? 0 : 0.7)
                            }
                            .contentShape(Circle())
                        }
                        .buttonStyle(.plain)
                        .help(track.isPlaying ? "Pause" : "Play")
                        .accessibilityLabel(track.isPlaying ? "Pause" : "Play")

                        controlButton("forward.fill", label: "Next track", isEnabled: track.canSkipNext, action: onNext)
                    }

                    HStack {
                        if track.duration > 0 {
                            timeLabel(scrub.fraction.map { NowPlayingTrack.formatTime($0 * track.duration) } ?? track.formattedPosition)
                            Spacer()
                            timeLabel(track.formattedDuration)
                        } else {
                            // Audio detected from a browser has no known length or position.
                            timeLabel(String(localized: "Playing now"))
                            Spacer()
                        }
                    }
                    .allowsHitTesting(false)
                }
                .frame(height: 22)
            }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 6)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// A command the player does not take stays in its place, dimmed, so the play button does not move.
    private func controlButton(_ symbol: String, label: LocalizedStringKey, isEnabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12))
                .foregroundColor(.white.opacity(isEnabled ? 0.8 : 0.22))
                .frame(width: 26, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .help(label)
        .accessibilityLabel(label)
    }

    private func timeLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 8.5, weight: .medium, design: .monospaced))
            .foregroundColor(.white.opacity(0.5))
    }

    private var artworkView: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color.white.opacity(0.06))

            if let data = track.artworkData, let nsImage = IslandArtwork.image(for: data) {
                Image(nsImage: nsImage)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 44, height: 44)
                    .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            } else {
                Image(systemName: track.app.iconName)
                    .font(.system(size: 20))
                    .foregroundColor(track.app.brandColor)
            }
        }
        .frame(width: 44, height: 44)
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(Color.white.opacity(0.12), lineWidth: 0.5)
        )
        .shadow(color: Color.black.opacity(0.3), radius: 4, x: 0, y: 2)
    }
}

/// The position under the pointer while the progress bar is dragged, as a share of the track.
@MainActor
final class ScrubState: ObservableObject {
    @Published var fraction: Double?
}

/// Decoded artwork, kept for the few most recent tracks. The island's views are re-evaluated about once a second
/// while a track plays (its position moves); decoding the picture on each of those is wasted work.
@MainActor
enum IslandArtwork {
    private static let cache: NSCache<NSData, NSImage> = {
        let cache = NSCache<NSData, NSImage>()
        cache.countLimit = 8
        return cache
    }()

    static func image(for data: Data) -> NSImage? {
        let key = data as NSData
        if let cached = cache.object(forKey: key) { return cached }
        guard let image = NSImage(data: data) else { return nil }
        cache.setObject(image, forKey: key)
        return image
    }
}
