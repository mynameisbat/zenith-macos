import SwiftUI
import AppKit
import ZenithCore

/// Hardware-integrated notch shelf and transient alert HUD for Zenith.
/// Pure black stealth integration into MacBook hardware notch.
/// Seamlessly transitions between idle notch indicator, transient alert HUD, and file drop shelf.
public struct ZenithDynamicIslandView: View {
    @ObservedObject public var islandState: ZenithIslandState = .shared

    public var geometry: ZenithIslandGeometry

    public init(geometry: ZenithIslandGeometry = ZenithIslandGeometry()) {
        self.geometry = geometry
    }

    private var isDisplayingAlert: Bool {
        islandState.activeAlert != nil
    }

    private var currentWidth: CGFloat {
        if isDisplayingAlert {
            return geometry.alertWidth
        } else if islandState.isExpanded {
            return geometry.expandedWidth
        } else {
            return geometry.idleWidth
        }
    }

    private var currentHeight: CGFloat {
        if isDisplayingAlert {
            return geometry.effectiveAlertHeight
        } else if islandState.isExpanded {
            return geometry.expandedHeight
        } else {
            return geometry.idleHeight
        }
    }

    private var topRadius: CGFloat {
        if isDisplayingAlert {
            return geometry.hasNotch ? 0 : 18
        }
        return geometry.hasNotch ? 0 : (islandState.isExpanded ? 16 : (geometry.idleHeight / 2))
    }

    private var bottomRadius: CGFloat {
        if isDisplayingAlert {
            return 18
        }
        return islandState.isExpanded ? 18 : (geometry.hasNotch ? 10 : (geometry.idleHeight / 2))
    }

    private var currentShape: UnevenRoundedRectangle {
        UnevenRoundedRectangle(
            topLeadingRadius: topRadius,
            bottomLeadingRadius: bottomRadius,
            bottomTrailingRadius: bottomRadius,
            topTrailingRadius: topRadius,
            style: .continuous
        )
    }

    private var targetRimLightOpacity: Double {
        guard islandState.isRimLightVisible else { return 0.0 }
        if islandState.isDropTargeted {
            return 0.25
        } else if isDisplayingAlert {
            return 0.18
        } else {
            return 0.12
        }
    }

    public var body: some View {
        ZStack(alignment: .top) {
            islandContainer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    // MARK: - Unified Morphing Container

    private var rimLightOverlay: some View {
        currentShape
            .strokeBorder(Color.white.opacity(targetRimLightOpacity), lineWidth: 0.5)
            .opacity(islandState.isRimLightVisible ? 1.0 : 0.0)
            .mask {
                if geometry.hasNotch {
                    // Strictly mask out top 0.75pt stroke line so no border leaks onto hardware notch bezel
                    Rectangle()
                        .padding(.top, 0.75)
                } else {
                    Rectangle()
                }
            }
    }

    private var islandContainer: some View {
        ZStack(alignment: .top) {
            if let alert = islandState.activeAlert {
                alertCapsuleView(alert)
                    .transition(.opacity.combined(with: .scale(scale: 0.95, anchor: .top)))
            } else if islandState.isExpanded {
                shelfContent
                    .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .top)))
            }
        }
        .frame(width: currentWidth, height: currentHeight, alignment: .top)
        .background(Color.black)
        .overlay(rimLightOverlay)
        .clipShape(currentShape)
        .scaleEffect(islandState.isDropTargeted ? 1.015 : 1.0, anchor: .top)
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: islandState.isExpanded)
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: islandState.activeAlert)
        .animation(.spring(response: 0.32, dampingFraction: 0.8), value: islandState.isDropTargeted)
        .onChange(of: islandState.isDropTargeted) { _, targeted in
            if targeted {
                NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .default)
            }
        }
    }

    // MARK: - Alert Capsule HUD

    private func alertCapsuleView(_ alert: IslandAlert) -> some View {
        HStack(spacing: 10) {
            Spacer(minLength: 0)

            Image(systemName: alert.icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(ZenithTheme.accent)
                .frame(width: 18, height: 18)

            VStack(alignment: .leading, spacing: 1) {
                Text(alert.title)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundColor(.white)
                    .lineLimit(1)

                if let subtitle = alert.subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: 9.5, weight: .regular))
                        .foregroundColor(.white.opacity(0.72))
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .frame(width: geometry.alertWidth, height: geometry.alertHeight)
        .padding(.top, geometry.hasNotch ? geometry.notchRect.height : 0)
        .frame(width: geometry.alertWidth, height: geometry.effectiveAlertHeight, alignment: .top)
    }

    // MARK: - Shelf Content

    private var shelfContent: some View {
        ZStack {
            if islandState.droppedItems.isEmpty {
                emptyShelfGuidance
            } else {
                populatedShelfDock
            }
        }
        .padding(.horizontal, 10)
        .padding(.top, geometry.hasNotch ? (geometry.notchRect.height + 2) : 8)
        .padding(.bottom, 8)
        .frame(width: geometry.expandedWidth, height: geometry.expandedHeight)
    }

    // MARK: - Empty Shelf Guidance

    private var emptyShelfGuidance: some View {
        HStack(spacing: 8) {
            Image(systemName: "tray.and.arrow.down")
                .font(.system(size: 14, weight: .regular))
                .foregroundColor(.white.opacity(islandState.isDropTargeted ? 0.85 : 0.4))

            Text(islandState.isDropTargeted ? "Release to stage" : "Drop files here to stage")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.white.opacity(islandState.isDropTargeted ? 0.95 : 0.4))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.white.opacity(islandState.isDropTargeted ? 0.08 : 0.045))
        )
    }

    // MARK: - Populated Shelf Dock

    private var populatedShelfDock: some View {
        HStack(spacing: 6) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(islandState.droppedItems) { item in
                        shelfItemCard(item: item)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.white.opacity(0.045))
            )

            // Clear shelf button
            Button {
                islandState.clearAll()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 13))
                    .foregroundColor(.white.opacity(0.35))
                    .padding(4)
            }
            .buttonStyle(.plain)
            .help("Clear Shelf")
        }
    }

    private func shelfItemCard(item: IslandDropItem) -> some View {
        VStack(spacing: 3) {
            ZStack(alignment: .topTrailing) {
                // Native macOS file icon
                if let url = item.fileURL {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 30, height: 30)
                } else {
                    Image(systemName: "doc.text.fill")
                        .font(.system(size: 26))
                        .foregroundColor(.white.opacity(0.85))
                        .frame(width: 30, height: 30)
                }

                // Delete individual item button
                Button {
                    islandState.removeItem(id: item.id)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 10))
                        .foregroundColor(.white.opacity(0.5))
                }
                .buttonStyle(.plain)
                .offset(x: 6, y: -4)
            }

            Text(item.name)
                .font(.system(size: 9.5, weight: .regular))
                .foregroundColor(.white.opacity(0.85))
                .lineLimit(1)
                .frame(width: 60)
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        // Click to copy immediately to clipboard
        .onTapGesture {
            copyItemToClipboard(item: item)
        }
        // Direct drag out to other applications
        .onDrag {
            islandState.beginDragOut()
            return makeItemProvider(for: item)
        }
        .contextMenu {
            if let url = item.fileURL, url.pathExtension.lowercased() == "app" {
                Button {
                    Task {
                        if let plan = AppUninstallerService.shared.analyzeApp(atPath: url.path) {
                            do {
                                let freed = try AppUninstallerService.shared.uninstall(plan: plan, moveToTrash: true)
                                ToastHUDController.shared.show(
                                    message: "Uninstalled \(plan.app.displayName) (Freed \(SystemCleanerService.formatBytes(freed)))",
                                    icon: "trash.fill"
                                )
                                islandState.removeItem(id: item.id)
                            } catch {
                                ToastHUDController.shared.show(message: "Uninstall error: \(error.localizedDescription)", icon: "exclamationmark.triangle")
                            }
                        }
                    }
                } label: {
                    Label("Deep Uninstall App & Leftovers", systemImage: "trash.fill")
                }

                Button {
                    Task {
                        if let plan = BinarySlimmerService.shared.scanApp(atPath: url.path) {
                            do {
                                let saved = try BinarySlimmerService.shared.slimApp(plan: plan)
                                ToastHUDController.shared.show(
                                    message: "Slimmed \(plan.appName) (Saved \(SystemCleanerService.formatBytes(saved)))",
                                    icon: "scissors"
                                )
                            } catch {
                                ToastHUDController.shared.show(message: "Slimming error: \(error.localizedDescription)", icon: "exclamationmark.triangle")
                            }
                        } else {
                            ToastHUDController.shared.show(message: "Already native Apple Silicon binary", icon: "checkmark.seal")
                        }
                    }
                } label: {
                    Label("Slim Universal App (Strip Intel code)", systemImage: "scissors")
                }

                Divider()
            }

            Button {
                copyItemToClipboard(item: item)
            } label: {
                Label("Copy to Clipboard", systemImage: "doc.on.clipboard")
            }

            Button(role: .destructive) {
                islandState.removeItem(id: item.id)
            } label: {
                Label("Remove from Shelf", systemImage: "xmark")
            }
        }
    }

    private func copyItemToClipboard(item: IslandDropItem) {
        let pboard = NSPasteboard.general
        pboard.clearContents()
        if let url = item.fileURL {
            pboard.writeObjects([url as NSURL, url.path as NSString])
            ToastHUDController.shared.show(message: "Copied \(item.name)", icon: "doc.on.clipboard")
        } else if let text = item.textContent {
            pboard.setString(text, forType: .string)
            ToastHUDController.shared.show(message: "Copied to Clipboard", icon: "doc.on.clipboard")
        }
    }

    private func makeItemProvider(for item: IslandDropItem) -> NSItemProvider {
        if let url = item.fileURL {
            let provider = NSItemProvider()
            // 1. URL representation (Standard for Finder, Telegram, Slack, Desktop, Notes)
            provider.registerObject(url as NSURL, visibility: .all)
            // 2. Plain text path (Fallback for web chat inputs, terminal, code editors)
            provider.registerObject(url.path as NSString, visibility: .all)

            // 3. Regular file data representation (only if not an app bundle or directory)
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue {
                provider.registerFileRepresentation(forTypeIdentifier: "public.item", fileOptions: [], visibility: .all) { completion in
                    completion(url, false, nil)
                    return nil
                }
            }
            return provider
        } else if let text = item.textContent {
            return NSItemProvider(object: text as NSString)
        } else {
            return NSItemProvider(object: item.name as NSString)
        }
    }
}
