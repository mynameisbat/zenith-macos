import SwiftUI
import AppKit
import ZenithCore

// MARK: - Animated Equalizer Visualizer Bars

@MainActor
final class EqualizerAnimationState: ObservableObject {
    @Published var barHeights: [CGFloat] = [0.4, 0.8, 0.5, 0.9]
    private var timer: Task<Void, Never>?

    func startAnimating() {
        guard timer == nil else { return }
        timer = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 180_000_000) // 180ms rhythmic pulse
                guard let self = self else { break }
                withAnimation(.spring(response: 0.2, dampingFraction: 0.6)) {
                    self.barHeights = [
                        CGFloat.random(in: 0.2...1.0),
                        CGFloat.random(in: 0.3...1.0),
                        CGFloat.random(in: 0.2...0.9),
                        CGFloat.random(in: 0.4...1.0)
                    ]
                }
            }
        }
    }

    func stopAnimating() {
        timer?.cancel()
        timer = nil
        barHeights = [0.25, 0.25, 0.25, 0.25]
    }
}

/// Rhythmic 4-bar equalizer visualizer displayed on the right wing of the Dynamic Island capsule.
public struct NowPlayingVisualizerView: View {
    public let brandColor: Color
    public let isPlaying: Bool
    @StateObject private var animState = EqualizerAnimationState()

    public init(brandColor: Color = ZenithTheme.accent, isPlaying: Bool = true) {
        self.brandColor = brandColor
        self.isPlaying = isPlaying
    }

    public var body: some View {
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(0..<4, id: \.self) { index in
                RoundedRectangle(cornerRadius: 1, style: .continuous)
                    .fill(brandColor)
                    .frame(width: 2.5, height: max(3, 14 * animState.barHeights[index]))
            }
        }
        .frame(width: 18, height: 16, alignment: .bottom)
        .onAppear {
            if isPlaying {
                animState.startAnimating()
            }
        }
        .onChange(of: isPlaying) { _, playing in
            if playing {
                animState.startAnimating()
            } else {
                animState.stopAnimating()
            }
        }
        .onDisappear {
            animState.stopAnimating()
        }
    }
}

// MARK: - Mini Compact Disc / Artwork View

@MainActor
final class VinylRotationState: ObservableObject {
    @Published var rotation: Double = 0.0
    private var timer: Task<Void, Never>?

    func startRotating() {
        guard timer == nil else { return }
        timer = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 50_000_000)
                guard let self = self else { break }
                self.rotation = (self.rotation + 3.0).truncatingRemainder(dividingBy: 360.0)
            }
        }
    }

    func stopRotating() {
        timer?.cancel()
        timer = nil
    }
}

/// Compact vinyl disc / album artwork shown on the left wing of the Dynamic Island.
public struct NowPlayingCompactDiscView: View {
    public let track: NowPlayingTrack
    @StateObject private var rotationState = VinylRotationState()

    public init(track: NowPlayingTrack) {
        self.track = track
    }

    public var body: some View {
        ZStack {
            // Vinyl outer groove
            Circle()
                .fill(Color(white: 0.12))
                .frame(width: 18, height: 18)
                .overlay(
                    Circle()
                        .stroke(Color.white.opacity(0.15), lineWidth: 0.5)
                )

            // Inner label / artwork
            if let data = track.artworkData, let nsImage = NSImage(data: data) {
                Image(nsImage: nsImage)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 14, height: 14)
                    .clipShape(Circle())
            } else {
                Image(systemName: track.app.iconName)
                    .font(.system(size: 8, weight: .bold))
                    .foregroundColor(track.app.brandColor)
            }

            // Center spindle hole
            Circle()
                .fill(Color.black)
                .frame(width: 3.5, height: 3.5)
        }
        .rotationEffect(.degrees(rotationState.rotation))
        .onAppear {
            if track.isPlaying {
                rotationState.startRotating()
            }
        }
        .onChange(of: track.isPlaying) { _, playing in
            if playing {
                rotationState.startRotating()
            } else {
                rotationState.stopRotating()
            }
        }
        .onDisappear {
            rotationState.stopRotating()
        }
    }
}

// MARK: - Expanded Media Player View

public struct NowPlayingExpandedView: View {
    public let track: NowPlayingTrack
    public var onPrevious: () -> Void
    public var onTogglePlayPause: () -> Void
    public var onNext: () -> Void

    public init(
        track: NowPlayingTrack,
        onPrevious: @escaping () -> Void = {},
        onTogglePlayPause: @escaping () -> Void = {},
        onNext: @escaping () -> Void = {}
    ) {
        self.track = track
        self.onPrevious = onPrevious
        self.onTogglePlayPause = onTogglePlayPause
        self.onNext = onNext
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
                            .frame(width: max(0, geo.size.width * CGFloat(track.progress)))
                    }
                }
                .frame(height: 3)

                // Controls in the middle, times (or "Playing now") at the sides
                ZStack {
                    HStack(spacing: 18) {
                        controlButton("backward.fill", action: onPrevious)

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

                        controlButton("forward.fill", action: onNext)
                    }

                    HStack {
                        if track.duration > 0 {
                            timeLabel(track.formattedPosition)
                            Spacer()
                            timeLabel(track.formattedDuration)
                        } else {
                            // Audio detected from a browser has no known length or position.
                            timeLabel("Playing now")
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

    private func controlButton(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12))
                .foregroundColor(.white.opacity(0.8))
                .frame(width: 26, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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

            if let data = track.artworkData, let nsImage = NSImage(data: data) {
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
