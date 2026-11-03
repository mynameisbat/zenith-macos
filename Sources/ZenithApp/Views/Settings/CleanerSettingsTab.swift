import SwiftUI
import ZenithCore

/// Settings tab for scanning, inspecting, and safely purging system and developer junk files.
public struct CleanerSettingsTab: View {
    @ObservedObject public var cleaner: SystemCleanerService = .shared

    public init() {}

    public var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 14) {
                // 1. Storage Status & Action Banner
                headerBanner

                // 2. Dual Telemetry Gauges (Storage Space & Live RAM)
                telemetryGaugesCard

                // 3. Selection Toolbar (Select All / Items Count)
                if !cleaner.categories.isEmpty {
                    selectionToolbar
                }

                // 4. Categories Breakdown List
                if cleaner.isScanning && cleaner.categories.isEmpty {
                    scanningPlaceholder
                } else if cleaner.categories.isEmpty {
                    emptyCleanState
                } else {
                    categoriesList
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
        }
        .onAppear {
            cleaner.refreshMemoryTelemetry()
            if cleaner.categories.isEmpty && !cleaner.isScanning {
                Task {
                    await cleaner.scan()
                }
            }
        }
        .confirmationDialog(
            "Clean Selected Files?",
            isPresented: $cleaner.showCleanConfirmation,
            titleVisibility: .visible
        ) {
            Button("Clean \(cleaner.formatSelectedSize)", role: .destructive) {
                Task {
                    let freed = await cleaner.cleanSelected()
                    if freed > 0 {
                        ToastHUDController.shared.show(
                            message: "Freed \(SystemCleanerService.formatBytes(freed))!",
                            icon: "sparkles"
                        )
                        AudioFeedbackManager.shared.playNewCopySound()
                    }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("These will be permanently deleted and cannot be restored:\n\(cleaner.selectionSummary)")
        }
    }

    // MARK: - Subviews

    private var headerBanner: some View {
        HStack(alignment: .center, spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.accentColor.opacity(0.12))
                    .frame(width: 44, height: 44)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(Color.accentColor.opacity(0.25), lineWidth: 1)
                    )
                Image(systemName: "trash.circle.fill")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundColor(.accentColor)
            }

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(cleaner.categories.isEmpty ? "System Clean" : SystemCleanerService.formatBytes(cleaner.totalJunkSize))
                        .font(.system(size: 16, weight: .bold, design: .monospaced))
                        .monospacedDigit()
                        .foregroundColor(.primary)

                    if cleaner.selectedJunkSize > 0 {
                        Text("(\(cleaner.formatSelectedSize) selected)")
                            .font(.system(size: 11.5, weight: .medium, design: .monospaced))
                            .monospacedDigit()
                            .foregroundColor(.secondary)
                    }
                }

                Text(cleaner.statusMessage ?? "Scan your Mac to identify safe cleanable files and developer caches.")
                    .font(.system(size: 11.5))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            HStack(spacing: 8) {
                Button {
                    Task {
                        await cleaner.scan()
                    }
                } label: {
                    if cleaner.isScanning {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 10))
                            Text("Scan")
                                .font(.system(size: 11.5, weight: .medium))
                        }
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(cleaner.isScanning || cleaner.isCleaning)

                Button {
                    cleaner.showCleanConfirmation = true
                } label: {
                    if cleaner.isCleaning {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        HStack(spacing: 4) {
                            Image(systemName: "sparkles")
                                .font(.system(size: 10))
                            Text("Clean")
                                .font(.system(size: 11.5, weight: .semibold))
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(cleaner.selectedJunkSize == 0 || cleaner.isCleaning || cleaner.isScanning)
            }
        }
        .zenithSettingsCard(cornerRadius: 10, padding: 14)
    }

    private var telemetryGaugesCard: some View {
        VStack(spacing: 12) {
            // Gauge 1: Storage Space
            if let disk = cleaner.diskInfo {
                diskMeterView(disk)
            }

            Rectangle()
                .fill(Color.primary.opacity(0.08))
                .frame(height: 0.5)

            // Gauge 2: Live System Memory (RAM)
            memoryMeterView
        }
        .zenithSettingsCard(cornerRadius: 10, padding: 12)
    }

    private func diskMeterView(_ disk: DiskSpaceInfo) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                HStack(spacing: 5) {
                    Image(systemName: "internaldrive")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                    Text("Macintosh HD Storage")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.secondary)
                }
                Spacer()
                Text("\(disk.formattedFree) available of \(disk.formattedTotal)")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .monospacedDigit()
                    .foregroundColor(.secondary)
            }

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(Color.primary.opacity(0.08))
                        .frame(height: 5)

                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(disk.usedPercentage > 0.85 ? Color.orange : Color.accentColor)
                        .frame(width: max(4, geo.size.width * CGFloat(disk.usedPercentage)), height: 5)
                }
            }
            .frame(height: 5)
        }
    }

    private var memoryMeterView: some View {
        let mem = cleaner.memoryTelemetry ?? SystemMemoryTelemetry.current()
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                HStack(spacing: 5) {
                    Image(systemName: "memorychip")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                    Text("Live System Memory (RAM)")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.secondary)
                }
                Spacer()
                Text("\(mem.formattedUsed) used (\(mem.formattedPercentage)) of \(mem.formattedTotal)")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .monospacedDigit()
                    .foregroundColor(.secondary)
            }

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(Color.primary.opacity(0.08))
                        .frame(height: 5)

                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(mem.usedPercentage > 0.85 ? Color.orange : Color.purple)
                        .frame(width: max(4, geo.size.width * CGFloat(mem.usedPercentage)), height: 5)
                }
            }
            .frame(height: 5)

            HStack {
                Text("Wired: \(SystemCleanerService.formatBytes(Int64(mem.wiredBytes))) • Compressed: \(SystemCleanerService.formatBytes(Int64(mem.compressedBytes))) • Available: \(mem.formattedAvailable)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.secondary)

                Spacer()

                Button {
                    Task {
                        let result = await cleaner.optimizeMemory()
                        let freedStr = SystemCleanerService.formatBytes(Int64(result.freedBytes))
                        let availStr = SystemCleanerService.formatBytes(Int64(result.availableBytes))
                        let subtitle = result.freedBytes > 0 ? "Freed \(freedStr)" : "Available: \(availStr)"
                        ToastHUDController.shared.show(
                            message: "RAM Optimized",
                            icon: "bolt.fill",
                            subtitle: subtitle
                        )
                        AudioFeedbackManager.shared.playNewCopySound()
                    }
                } label: {
                    if cleaner.isOptimizingMemory {
                        ProgressView()
                            .controlSize(.mini)
                    } else {
                        HStack(spacing: 4) {
                            Image(systemName: "bolt.fill")
                                .font(.system(size: 9))
                            Text("Optimize RAM")
                                .font(.system(size: 10.5, weight: .medium))
                        }
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)
                .disabled(cleaner.isOptimizingMemory)
            }
            .padding(.top, 2)
        }
    }

    private var selectionToolbar: some View {
        HStack {
            Button {
                let allSelected = cleaner.categories.allSatisfy(\.isSelected)
                cleaner.selectAll(!allSelected)
            } label: {
                let allSelected = cleaner.categories.allSatisfy(\.isSelected)
                HStack(spacing: 4) {
                    Image(systemName: allSelected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 11))
                        .foregroundColor(allSelected ? .accentColor : .secondary)
                    Text(allSelected ? "Deselect All" : "Select All")
                        .font(.system(size: 11, weight: .medium))
                }
            }
            .buttonStyle(.plain)

            Spacer()

            Text("\(cleaner.selectedItemCount) of \(cleaner.totalItemCount) items selected")
                .font(.system(size: 10.5, design: .monospaced))
                .monospacedDigit()
                .foregroundColor(.secondary)
        }
        .padding(.horizontal, 4)
    }

    private var categoriesList: some View {
        VStack(spacing: 8) {
            ForEach(cleaner.categories) { category in
                categoryCard(category)
            }
        }
    }

    private func categoryCard(_ category: JunkCategory) -> some View {
        VStack(spacing: 0) {
            // Category Header
            HStack(spacing: 10) {
                Button {
                    cleaner.toggleCategory(id: category.id)
                } label: {
                    Image(systemName: category.isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 14))
                        .foregroundColor(category.isSelected ? .accentColor : .secondary)
                }
                .buttonStyle(.plain)

                Image(systemName: category.icon)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.accentColor)
                    .frame(width: 18)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(category.title)
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundColor(.primary)
                        Text("(\(category.items.count))")
                            .font(.system(size: 10.5, design: .monospaced))
                            .foregroundColor(.secondary)
                    }

                    Text(category.description)
                        .font(.system(size: 10.5))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }

                Spacer()

                Text(category.formattedTotalSize)
                    .font(.system(size: 11.5, weight: .bold, design: .monospaced))
                    .monospacedDigit()
                    .foregroundColor(.primary)

                Button {
                    withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
                        cleaner.toggleCategoryExpansion(id: category.id)
                    }
                } label: {
                    Image(systemName: category.isExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.secondary)
                        .frame(width: 20, height: 20)
                }
                .buttonStyle(.plain)
            }
            .padding(12)
            .background(Color.primary.opacity(0.035))

            // Expandable Items Breakdown
            if category.isExpanded {
                Rectangle()
                    .fill(Color.primary.opacity(0.08))
                    .frame(height: 0.5)

                VStack(spacing: 2) {
                    ForEach(category.items) { item in
                        itemRow(category: category, item: item)
                    }
                }
                .padding(.vertical, 6)
                .padding(.horizontal, 10)
                .background(Color.primary.opacity(0.02))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 0.5)
        )
    }

    private func itemRow(category: JunkCategory, item: JunkItem) -> some View {
        HStack(spacing: 8) {
            Button {
                cleaner.toggleItem(categoryId: category.id, itemId: item.id)
            } label: {
                Image(systemName: item.isSelected ? "checkmark.square.fill" : "square")
                    .font(.system(size: 12))
                    .foregroundColor(item.isSelected ? .accentColor : .secondary)
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 1) {
                Text(item.name)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundColor(.primary)
                    .lineLimit(1)

                Text(abbreviateHomePath(item.path))
                    .font(.system(size: 9.5))
                    .foregroundColor(.secondary.opacity(0.8))
                    .lineLimit(1)
            }

            Spacer()

            Text(item.formattedSize)
                .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                .monospacedDigit()
                .foregroundColor(.secondary)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(item.isSelected ? Color.primary.opacity(0.02) : Color.clear)
        )
    }

    private var scanningPlaceholder: some View {
        VStack(spacing: 12) {
            ProgressView()
                .controlSize(.regular)
            Text("Scanning system caches and developer files...")
                .font(.system(size: 12))
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }

    private var emptyCleanState: some View {
        VStack(spacing: 10) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 28))
                .foregroundColor(.accentColor.opacity(0.8))
                .padding(.top, 20)
            Text("Your Mac is Clean")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.primary)
            Text("No significant junk or developer cache files were found.")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .padding(.bottom, 20)
        }
        .frame(maxWidth: .infinity)
        .zenithSettingsCard(cornerRadius: 10, padding: 0)
    }

    private func abbreviateHomePath(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if path.hasPrefix(home) {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }
}

extension SystemCleanerService {
    public var formatSelectedSize: String {
        Self.formatBytes(selectedJunkSize)
    }
}
