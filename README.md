# Zenith 🌌

A premium, native macOS utility and creative workstation built with **Swift 6**, **SwiftUI**, and **AppKit**.

Zenith lives quietly in your Menu Bar as a high-performance accessory, bringing together smart clipboard history, precision screen capture with vector annotations, Dynamic IslandHUD capsules, DoH privacy DNS shield, and system cache cleaning into a cohesive, native macOS experience.

---

## 📥 Download & Installation

### Option 1: Download Pre-built DMG Installer (Recommended)
Download the latest disk image from [GitHub Releases](https://github.com/zenith/releases) or build it locally:

1. Download **`Zenith-2.0.0.dmg`**.
2. Double-click the DMG file to mount it.
3. Drag **Zenith.app** into your **Applications** folder.
4. Launch Zenith from Spotlight or Applications.

> **Note for macOS Gatekeeper:** If macOS warns about an unidentified developer, right-click (or Control-click) `Zenith.app` in `/Applications` and select **Open**, then click **Open** in the prompt.

### Option 2: Build from Source
```bash
# Clone the repository
git clone https://github.com/<your-username>/zenith.git
cd zenith

# Run automated test suites (658/658 tests)
swift test

# Build and assemble Zenith.app bundle
./scripts/bundle_app.sh

# Or generate a release DMG installer
./scripts/create_dmg.sh

# Launch the app
open Zenith.app
```

---

## ✨ Key Features

### 1. 🎛 Menu Bar Command Hub
- Minimalist macOS Sequoia popover designed with frosted glass vibrancy (`.ultraThinMaterial`).
- Instant search bar filtering clipboard items and actions.
- Direct quick action tiles for **Capture Area** (`⌘⇧2`) and **Capture Screen** (`⌘⇧1`).
- Recent clipboard stream with type-aware previews and single-click paste.
- Subtle system telemetry footer displaying DoH Shield status and cleanable cache space.

### 2. 📋 Smart Clipboard Manager
- **Global Hotkey (`⌘⇧V` or `⌥V`)**: Instantly opens clipboard history directly at cursor or center screen.
- **Fuzzy Search Engine**: Sub-millisecond search across plain text, rich text, code snippets, and images.
- **Password Manager Protection**: Automatically detects and ignores sensitive pasteboard data from 1Password, Bitwarden, KeePassXC, and concealed types.
- **Pin Items**: Immune from FIFO eviction limits.

### 3. 📸 Precision Screen Capture & Annotation Editor
- **Interactive Loupe Magnifier**: Real-time pixel loupe with RGB color sampling and dimension badges for pixel-perfect cropping.
- **Vector Annotation Tools**: Freehand pen, arrows with swept-back wings, rectangles, text labels, and privacy pixelation/blur.
- **100% Retina Fidelity**: Exports annotations directly at native physical display backing resolution (PNG & JPEG).
- **Rapid Keyboard Workflow**:
  - `⌘C`: Flatten annotations, copy to clipboard, and close editor.
  - `⌘S`: Export high-resolution image to disk.
  - `⌘Z` / `⇧⌘Z`: Full undo/redo history.
  - `Esc`: Dismiss editor safely.

### 4. 🏝 Dynamic Island & Alert Capsule
- **Hardware-Aware Geometry**: Seamlessly adapts to MacBook physical display notches as well as external monitors.
- **Fluid Spring Physics**: Symmetrical 120Hz ProMotion spring expansion without horizontal drift.
- **Alert Capsule HUD**: Transient HUD for copy/capture actions unified inside the notch capsule.

### 5. 🛡 DoH (DNS-over-HTTPS) Privacy Shield
- In-process local DNS proxy server with loopback-only binding guards and SSRF prevention.
- Seamlessly re-routable upstream providers: **Cloudflare**, **Google**, **AdGuard**, **Quad9**, **NextDNS**, or custom DoH URLs.

### 6. 🧹 System Cleaner & RAM Purge
- Safe cache cleaner inspecting developer caches (Xcode DerivedData, CocoaPods, Gradle, Cargo) and browser caches.
- Real-time Mach kernel memory telemetry and safe inactive RAM pressure relief.

### 7. 🔊 Audio Feedback
- 14 customizable native macOS sound cues (Pop, Tink, Hero, Bottle, Funk, Ping, Purr, Submarine, etc.) with custom sound file import (`.wav`, `.aiff`, `.m4a`).

---

## ⌨️ Global & In-App Keyboard Shortcuts

| Shortcut | Context | Action |
| :--- | :--- | :--- |
| `⌘⇧2` | Global | Start Area Screen Capture |
| `⌘⇧1` | Global | Capture Entire Active Display |
| `⌘⇧V` | Global | Open Clipboard History Manager |
| `↑` / `↓` | Clipboard Hub | Navigate clipboard list |
| `↵` (Enter) | Clipboard Hub | Paste selected item into active application |
| `⌘1` ... `⌘9` | Clipboard Hub | Quick select item by number row |
| `⌘⌫` | Clipboard Hub | Delete selected clip from history |
| `⌘P` | Clipboard Hub | Toggle pin status on selected clip |
| `⌘C` | Annotation Editor | Copy annotated image to clipboard and dismiss |
| `⌘S` | Annotation Editor | Save annotated image to disk |
| `⌘Z` | Annotation Editor | Undo last drawing action |
| `⇧⌘Z` | Annotation Editor | Redo drawing action |
| `Esc` | Any Modal / Editor | Dismiss / Cancel |
| `⌘,` | Menu Bar Hub | Open Zenith Settings |
| `⌘Q` | Menu Bar Hub | Quit Zenith |

---

## 🔒 System Permissions Guide

Zenith requires standard macOS system permissions to operate:

1. **Screen Recording (`TCC.kTCCServiceScreenCapture`)**:
   - Required to capture screenshots and sample pixels in the magnifier loupe.
   - macOS will prompt automatically on first capture. You can also enable it in:
     *System Settings → Privacy & Security → Screen Recording → Enable Zenith*.
2. **Accessibility (`TCC.kTCCServiceAccessibility`)**:
   - Required to simulate `⌘V` when selecting an item from clipboard history to paste directly into your current application.
   - Enable in:
     *System Settings → Privacy & Security → Accessibility → Enable Zenith*.

---

## 🧪 Architecture & Quality Verification

Zenith is engineered with clean modularity and strict Swift 6 concurrency safety:

```
┌────────────────────────────────────────────────────────┐
│               GoldenGateApp (Executable)               │
│  - NSApplication (.accessory policy)                   │
│  - Status Bar Controller & Menu Bar Popover            │
│  - Dynamic Island, Annotation Editor, Settings Window  │
└───────────────────────────┬────────────────────────────┘
                            │ consumes
┌───────────────────────────▼────────────────────────────┐
│                GoldenGateCore (Library)                │
│  - Headless, decoupled core engines                    │
│  - ScreenCaptureKit backend, HotKey parser, Proxy      │
│  - 100% verifiable via automated Swift Testing suites │
└───────────────────────────▲────────────────────────────┘
                            │ verified by
┌───────────────────────────┴────────────────────────────┐
│         GoldenGateCoreTests (658 tests / 59 suites)    │
│  - Tier 1: Feature coverage                            │
│  - Tier 2: Boundary & corner cases                     │
│  - Tier 3: Cross-feature interactions                  │
│  - Tier 4: Adversarial stress & concurrency torture    │
└────────────────────────────────────────────────────────┘
```

Run test suite:
```bash
swift test
```

---

## 📄 License

Zenith is open source under the [MIT License](LICENSE).
