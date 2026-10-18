# Zenith 🌌

A premium, native macOS utility and creative workstation built with **Swift 6**, **SwiftUI**, and **AppKit**.

Zenith lives quietly in your Menu Bar as a high-performance accessory, bringing together smart clipboard history, precision screen capture with vector annotations, Dynamic IslandHUD capsules, DoH privacy DNS shield, and system cache cleaning into a cohesive, native macOS experience.

---

## ✨ Features

- **Menu Bar Command Hub**: Sleek macOS Sequoia popover with search, quick actions (`Area` ⌘⇧2, `Screen` ⌘⇧1), recent clips stream, and live system status indicators.
- **Smart Clipboard History**:
  - Global hotkey (`⌘⇧V` or `⌥V`) triggering instant search popover.
  - Fuzzy search filtering across plain text, rich text, code snippets, and images.
  - Sensitive pasteboard data filtering (1Password, Bitwarden, KeePassXC markers excluded automatically).
  - Pin items to protect from FIFO eviction.
- **Precision Screen Capture & Annotation**:
  - Area capture (`⌘⇧2`) with interactive marquee and real-time pixel magnifier loupe.
  - Full-screen capture (`⌘⇧1`).
  - Native vector annotation editor: arrows, rectangles, freehand pen, text labels, and privacy blur/pixelation.
  - High-DPI Retina export preserving 100% native backing pixel fidelity (PNG & JPEG).
  - Fast in-editor shortcuts (`⌘C` copy & close, `⌘S` save, `⌘Z` / `⇧⌘Z` undo/redo, `Esc` dismiss).
- **Dynamic Island & Drop Shelf**:
  - Hardware-aware notch integration adapting smoothly to both notched MacBooks and standard external displays.
  - Symmetrical 120Hz spring expansion.
  - Unified alert capsule HUD for quick actions and transient notifications.
- **DoH Privacy Shield**:
  - Built-in local DNS-over-HTTPS proxy with loopback binding guard and DNS rebinding protection.
  - Support for multiple upstream providers: Cloudflare, Google, AdGuard, Quad9, NextDNS, and custom endpoints.
- **System Cleaner & Memory Optimizer**:
  - Safe cache cleanup for developer artifacts (Xcode DerivedData, CocoaPods, Gradle, Cargo) and browser caches.
  - Real-time Mach kernel memory telemetry and safe RAM purge/pressure relief.
- **Audio Feedback**:
  - 14 customizable macOS system sound cues + custom audio file import support.

---

## 🛠 Tech Stack & Requirements

- **macOS**: 14.0+ (Sonoma, Sequoia)
- **Language**: Swift 6 (Strict Concurrency checking)
- **Frameworks**: SwiftUI, AppKit, ScreenCaptureKit, CoreGraphics, Network.framework
- **Architecture**: Modular SPM with decoupled Core library and 100% automated test coverage (658 tests across 59 suites).

---

## 🚀 Building & Running

### Prerequisites
- macOS 14.0 or newer
- Xcode 15+ / Swift 6.0+ Command Line Tools

### Build via Terminal
```bash
# Clone the repository
git clone https://github.com/<your-username>/zenith.git
cd zenith

# Run all test suites
swift test

# Build and assemble Zenith.app bundle
./scripts/bundle_app.sh

# Launch application
open Zenith.app
```

---

## 📄 License

MIT License. See [LICENSE](LICENSE) for details.
