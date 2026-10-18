# Project: GoldenGate

## Overview
GoldenGate is a native macOS desktop utility written in Swift, SwiftUI, and AppKit. It runs as a lightweight, persistent Menu Bar item (`NSStatusItem`) providing clipboard history management, screen capture with loupe magnifier and annotation tools, global keyboard shortcuts, subtle audio feedback, and modern macOS Golden Gate visual design (`.ultraThinMaterial`, dark/light mode vibrancy, spring micro-interactions).

---

## Architecture
GoldenGate is structured as a modular Swift Package Manager (SPM) project with strict dependency inversion, enabling 100% automated test coverage in headless environments.

```
┌────────────────────────────────────────────────────────────────────────┐
│                          GoldenGateApp (Executable)                    │
│  - NSApplication (.accessory policy)                                    │
│  - Menu Bar NSStatusItem & Context Menu                                │
│  - Floating NSPanels: Clipboard History, Screen Overlay, Annotation    │
│  - Floating Toast HUDs & Settings Window                               │
└───────────────────────────────────┬────────────────────────────────────┘
                                    │ consumes
┌───────────────────────────────────▼────────────────────────────────────┐
│                         GoldenGateCore (Library)                       │
│  ┌───────────────────────┐  ┌───────────────────────┐                  │
│  │    Clipboard Engine   │  │    HotKey Manager     │                  │
│  │  - Monitor & Polling  │  │  - Carbon HotKeys     │                  │
│  │  - Store & Eviction   │  │  - KeyCode Parser     │                  │
│  │  - Fuzzy Search       │  │  - Zero-Perms Global  │                  │
│  └───────────────────────┘  └───────────────────────┘                  │
│  ┌───────────────────────┐  ┌───────────────────────┐                  │
│  │ Screen Capture & Loupe│  │   Annotation Engine   │                  │
│  │  - ScreenCaptureKit   │  │  - Vector Tool Models │                  │
│  │  - Synthetic Pattern  │  │  - Undo/Redo Stack    │                  │
│  │  - Zero-Pointer Loupe │  │  - Export Pipeline    │                  │
│  └───────────────────────┘  └───────────────────────┘                  │
│  ┌───────────────────────┐  ┌───────────────────────┐                  │
│  │     Audio Feedback    │  │    Settings Store     │                  │
│  │  - NSSound / Shutter  │  │  - UserDefaults Model │                  │
│  │  - Mute Persistence   │  │  - Permission Checker │                  │
│  └───────────────────────┘  └───────────────────────┘                  │
└───────────────────────────────────▲────────────────────────────────────┘
                                    │ tests
┌───────────────────────────────────┴────────────────────────────────────┐
│                       GoldenGateCoreTests (Swift Testing)              │
│  - Tests using @Test and #expect via libTestingMacros.dylib            │
│  - Comprehensive Unit & Integration Tests (Tiers 1-4)                  │
└────────────────────────────────────────────────────────────────────────┘
```

---

## Code Layout
```
golden_gate/
├── Package.swift                                      # SPM Manifest (Core, App, Tests)
├── Sources/
│   ├── GoldenGateCore/                                # Headless & Testable Domain Core
│   │   ├── Protocols/                                 # Service Interfaces
│   │   │   ├── PasteboardServiceProtocol.swift
│   │   │   ├── ScreenCaptureServiceProtocol.swift
│   │   │   ├── SoundServiceProtocol.swift
│   │   │   ├── HotKeyServiceProtocol.swift
│   │   │   └── StorageServiceProtocol.swift
│   │   ├── Models/                                    # Domain Entities
│   │   │   ├── ClipboardItem.swift
│   │   │   ├── HotKeyDefinition.swift
│   │   │   ├── AnnotationModels.swift                 # Pen, Arrow, Rect, Text, Blur, Crop
│   │   │   └── SettingsState.swift
│   │   ├── Services/                                  # Concrete Domain Implementations
│   │   │   ├── ClipboardStore.swift                   # History store, FIFO eviction, search
│   │   │   ├── PasteboardMonitor.swift                # changeCount poller & UTI parser
│   │   │   ├── CarbonHotKeyManager.swift              # RegisterEventHotKey wrapper
│   │   │   ├── AudioFeedbackManager.swift             # Sound player with mute control
│   │   │   ├── ScreenCaptureManager.swift             # ScreenCaptureKit live + synthetic
│   │   │   ├── LoupeMagnifier.swift                   # 1x1 pixel sampling & RGB hex
│   │   │   ├── AnnotationCommandStack.swift           # Command pattern Undo/Redo
│   │   │   ├── ImageExportService.swift               # Vector rendering to PNG/JPEG
│   │   │   └── SettingsStore.swift                    # UserDefaults backed persistence
│   │   └── Mocks/                                     # Headless Test Mocks
│   │       ├── MockPasteboardService.swift
│   │       ├── MockScreenCaptureService.swift
│   │       ├── MockSoundService.swift
│   │       └── MockHotKeyService.swift
│   │
│   └── GoldenGateApp/                                 # Executable & macOS UI Layer
│       ├── main.swift                                 # NSApplication entry point (.accessory)
│       ├── AppDelegate.swift                          # Lifecycle, StatusItem, HotKey wiring
│       ├── Controllers/                               # Window & Panel Controllers
│       │   ├── StatusBarController.swift              # Menu bar icon & menu
│       │   ├── ClipboardPanelController.swift         # Floating .ultraThinMaterial panel
│       │   ├── CaptureOverlayController.swift         # Fullscreen marquee & loupe panel
│       │   ├── AnnotationWindowController.swift       # Post-capture editor window
│       │   ├── SettingsWindowController.swift         # Preferences window
│       │   └── ToastHUDController.swift               # Ephemeral pill notifications
│       └── Views/                                     # SwiftUI Views
│           ├── Clipboard/
│           │   ├── ClipboardHistoryView.swift
│           │   ├── ClipboardRowView.swift
│           │   └── SearchBarView.swift
│           ├── Capture/
│           │   ├── SelectionMarqueeView.swift
│           │   ├── LoupeMagnifierView.swift
│           │   └── DimensionBadgeView.swift
│           ├── Annotation/
│           │   ├── AnnotationEditorView.swift
│           │   ├── CanvasView.swift
│           │   └── StylingToolbarView.swift
│           ├── Settings/
│           │   ├── SettingsView.swift
│           │   ├── ShortcutRecorderView.swift
│           │   └── PermissionsGuideView.swift
│           └── Common/
│               ├── MaterialBackground.swift
│               └── KeycapBadgeView.swift
│
└── Tests/
    └── GoldenGateCoreTests/                           # Swift Testing Test Suites
        ├── ClipboardTests/
        │   ├── ClipboardStoreTests.swift
        │   ├── FuzzySearchTests.swift
        │   └── EvictionTests.swift
        ├── HotKeyTests/
        │   ├── HotKeyParserTests.swift
        │   └── KeyCodeMappingTests.swift
        ├── AudioTests/
        │   └── AudioFeedbackManagerTests.swift
        ├── CaptureTests/
        │   ├── CoordinateTranslationTests.swift
        │   └── LoupeMagnifierTests.swift
        ├── AnnotationTests/
        │   ├── AnnotationCommandStackTests.swift
        │   ├── DrawingModelsTests.swift
        │   └── ImageExportTests.swift
        ├── SettingsTests/
        │   └── SettingsStoreTests.swift
        └── E2ETests/                                  # Opaque-box E2E Suites
            ├── Tier1_FeatureCoverageTests.swift
            ├── Tier2_BoundaryEdgeTests.swift
            ├── Tier3_PairwiseIntegrationTests.swift
            └── Tier4_ApplicationScenarioTests.swift
```

---

## Feature Inventory
Every feature from the Survey phase is mapped to a designated Milestone. No feature is left unassigned.

| # | Feature ID | Feature Name | Description | Milestone | Source |
|---|------------|--------------|-------------|-----------|--------|
| 1 | F01 | Background Pasteboard Monitor | Continuously monitors `NSPasteboard` changeCount; captures items asynchronously. | M2 | R1 |
| 2 | F02 | Multi-Format Ingestion | Ingests plain text, rich text (RTF), and raster images (PNG/TIFF). | M2 | R1 |
| 3 | F03 | Sensitive Data Exclusion | Filters out password manager data (`org.nspasteboard.ConcealedType`). | M2 | R1 |
| 4 | F04 | Consecutive Deduplication | Suppresses consecutive identical clipboard entries; updates recency. | M2 | R1 |
| 5 | F05 | FIFO/Capacity Eviction | Limits history to user-configured capacity (default 20, up to 500); drops oldest. | M2 | R1, R6 |
| 6 | F06 | Global Hotkey Invocation (Clipboard) | Global shortcut (default `Cmd+Shift+V` / `Option+V`) opens clipboard panel. | M3 | R1 |
| 7 | F07 | Mouse-Anchored Popup Panel | Displays floating `.nonactivatingPanel` at cursor location, clamped to screen. | M2 | R1 |
| 8 | F08 | Real-Time Fuzzy Search | Real-time fuzzy query filtering with ranked matches. | M2 | R1 |
| 9 | F09 | Keyboard Arrow Navigation | Up/Down arrows navigate history list seamlessly without losing focus. | M2 | R1 |
| 10 | F10 | Enter to Paste / Restore | Enter restores selected item to clipboard and triggers copy/paste. | M2 | R1 |
| 11 | F11 | Quick Selection Badges | Number shortcuts (`⌘1`..`⌘9`) on top rows for quick 1-stroke restoration. | M2 | R1, R5 |
| 12 | F12 | Clear History Action | Purges unpinned history from memory and disk storage. | M2 | R1 |
| 13 | F13 | Global Area Crop Hotkey | Global shortcut (`Cmd+Shift+2` or `Cmd+Shift+X`) triggers area screenshot overlay. | M3 | R2 |
| 14 | F14 | Global Fullscreen Hotkey | Global shortcut (`Cmd+Shift+1`) captures full screen immediately. | M3 | R2 |
| 15 | F15 | Multi-Display Dim Overlay | Fullscreen transparent overlay at `.screenSaver` window level spanning displays. | M4 | R2 |
| 16 | F16 | Interactive Marquee Drag | Click-and-drag rectangular marquee highlighting selected area. | M4 | R2 |
| 17 | F17 | Dimension Badge Overlay | Live dimension pill showing width × height in points and physical pixels. | M4 | R2 |
| 18 | F18 | Pixel Magnifier Loupe | 4x-8x loupe following cursor with grid, crosshair, and exact `#RRGGBB` hex code. | M4 | R2 |
| 19 | F19 | Escape Cancel | Pressing `Esc` immediately cancels capture overlay and restores state. | M4 | R2 |
| 20 | F20 | High-DPI Retina Coordinate Mapping | Normalizes point coordinates to physical backing pixels for crisp 2x Retina crops. | M4 | R2 |
| 21 | F21 | Post-Capture Editor Window | Presents captured bitmap in editor window with canvas and tool palette. | M5 | R3 |
| 22 | F22 | Freehand Pen / Brush Tool | Smoothed Catmull-Rom/Bezier curve drawing with configurable stroke and color. | M5 | R3 |
| 23 | F23 | Arrow Tool | Vector arrow drawing with directional arrowhead proportional to stroke. | M5 | R3 |
| 24 | F24 | Rectangle Tool | Bounded hollow or filled rectangle drawing tool. | M5 | R3 |
| 25 | F25 | Text Annotation Tool | Vector text boxes with inline typography, font size, and color. | M5 | R3 |
| 26 | F26 | Blur / Pixelate Privacy Tool | CoreImage `CIPixellate` mosaic filter over sensitive screen areas. | M5 | R3 |
| 27 | F27 | Interactive Crop Tool | Interactive cropping and boundary adjustment post-capture. | M5 | R3 |
| 28 | F28 | Styling Toolbar | Floating glass palette for colors (8 presets) and stroke widths (2, 4, 8 pt). | M5 | R3, R5 |
| 29 | F29 | Command Stack (Undo/Redo) | Reversible command history supporting `Cmd+Z` undo and `Shift+Cmd+Z` redo. | M5 | R3 |
| 30 | F30 | In-Editor Copy (`Cmd+C`) | Flattens annotations, copies image to clipboard, shows HUD, dismisses editor. | M5 | R3 |
| 31 | F31 | In-Editor Save (`Cmd+S`) | Opens save dialog to write PNG/JPEG to disk, shows HUD, dismisses editor. | M5 | R3 |
| 32 | F32 | In-Editor Discard (`Esc`) | Discards annotations, frees image memory buffers, closes window without saving. | M5 | R3 |
| 33 | F33 | New Copy Sound Effect | Tactile audio click/pop when new item arrives on clipboard. | M3 | R4 |
| 34 | F34 | Paste Selection Sound Effect | Tactile audio cue when user selects an item to paste from history. | M3 | R4 |
| 35 | F35 | Shutter Sound Effect | Camera shutter sound effect upon completing screen capture. | M3 | R4 |
| 36 | F36 | Sound Effects Mute Toggle | Preference setting to mute all audio effects with zero latency. | M3 | R4, R6 |
| 37 | F37 | `.ultraThinMaterial` Glass Styling | Frosted glass vibrancy styling for floating panels and toolbars. | M2 | R5 |
| 38 | F38 | Adaptive Dark & Light Modes | Automatic adaptation to macOS system appearance using semantic colors. | M2 | R5 |
| 39 | F39 | Spring Micro-Animations | Fluid Apple spring animations (`response: 0.3, damping: 0.75`) for UI transitions. | M6 | R5 |
| 40 | F40 | List Item Hover Effects | Subtle rounded hover pills and depth elevation on cursor movement. | M2 | R5 |
| 41 | F41 | Non-Blocking HUD Toasts | Floating pill toasts ("Copied!", "Saved!") fading after 1.5s without focus steal. | M6 | R5 |
| 42 | F42 | Menu Bar Status Item | Persistent status icon in macOS menu bar (`NSStatusItem`). | M6 | R6 |
| 43 | F43 | Status Item Dropdown Menu | Dropdown menu with quick actions, settings link, and quit command. | M6 | R6 |
| 44 | F44 | Launch at Login | Automatic login item registration via `SMAppService.mainApp`. | M6 | R6 |
| 45 | F45 | Preferences Window | Multi-tab settings panel (General, Shortcuts, Audio, Permissions). | M1 | R6 |
| 46 | F46 | Shortcut Customization Recorder | Keyboard shortcut validator and configuration recorder. | M1 | R6 |
| 47 | F47 | Permissions Guidance & Check | Live status indicators and direct links for Screen Recording & Accessibility. | M1 | R6 |
| 48 | F48 | High-Resolution Image Export | Flattens vector annotations onto native display bitmap without downsampling. | M5 | R3 |

---

## Milestones
Target: 6 implementation milestones + 1 final verification milestone.

| # | Name | Scope | Dependencies | Status |
|---|------|-------|-------------|--------|
| M1 | Foundation, SPM Build, Protocols & Settings Model | SPM `Package.swift` setup for Swift 6.4 CLT, core protocols, mockable interfaces, SettingsStore model, HotKey definitions, permission helpers (F45, F46, F47). 34 tests passing cleanly. | None | DONE |
| M2 | Clipboard History Engine & Floating Panel UI | Ingestion of text, RTF, images, privacy filtering, deduplication, FIFO eviction, fuzzy search, floating `.ultraThinMaterial` panel, keyboard navigation, hover states (F01-F05, F07-F12, F37, F38, F40). 186 tests passing cleanly. | M1 | DONE |
| M3 | Global HotKey Manager & Audio Feedback Engine | Carbon `RegisterEventHotKey` zero-permission global listener, hotkey parsing, NSSound audio effects (tink, pop, shutter sound) with mute control (F06, F13, F14, F33-F36). 261 tests passing cleanly across 20 suites. | M1 | DONE |
| M4 | Screen Capture Overlay & Loupe Magnifier | Transparent multi-screen overlay, marquee drag, live dimension HUD, Esc cancellation, 4x/8x zero-unsafe-pointer Loupe magnifier with RGB hex, Retina coordinate mapping (F15-F20). | M1, M3 | DONE |
| M5 | Annotation Canvas, In-Editor Shortcuts & Export | Vector annotation models (Pen, Arrow, Rect, Text, Blur, Crop), floating toolbar, Undo/Redo command stack, in-editor shortcuts (`Cmd+C`, `Cmd+S`, `Cmd+Z`, `Esc`), high-res export (F21-F32, F48). | M1, M4 | DONE |
| M6 | Menu Bar Integration, Settings Window & System App | Menu bar `NSStatusItem`, dropdown menu, multi-tab settings window, HUD toasts, spring micro-interactions, launch-at-login integration, main executable wiring (F39, F41-F44). 505 tests passing cleanly across 45 suites. | M1, M2, M3, M4, M5 | DONE |
| M7 | Final Acceptance: 100% E2E Test Suite Pass & Adversarial Hardening | Phase 1: 100% pass of opaque-box E2E suite (Tiers 1-4). Phase 2: Adversarial coverage hardening with Challengers (57 new stress tests). 562 tests passing cleanly across 49 suites. | M6, TEST_READY.md | DONE |

---

## Interface Contracts

### 1. `GoldenGateCore` Service Protocols

```swift
public protocol PasteboardServiceProtocol: Sendable {
    func startMonitoring(onChange: @escaping @Sendable (ClipboardItem) -> Void)
    func stopMonitoring()
    func copyItemToPasteboard(_ item: ClipboardItem)
    func writeImageToPasteboard(_ image: CGImage)
}

public protocol ScreenCaptureServiceProtocol: Sendable {
    func captureMainDisplay() async throws -> CGImage
    func captureDisplayRegion(_ rect: CGRect, displayID: CGDirectDisplayID) async throws -> CGImage
}

public protocol SoundServiceProtocol: Sendable {
    func playNewCopySound()
    func playPasteSound()
    func playShutterSound()
    var isMuted: Bool { get set }
}

public protocol HotKeyServiceProtocol: AnyObject {
    func registerHotKey(_ definition: HotKeyDefinition, handler: @escaping () -> Void) -> Bool
    func unregisterHotKey(_ definition: HotKeyDefinition)
    func unregisterAll()
}

public protocol StorageServiceProtocol: Sendable {
    func saveItems(_ items: [ClipboardItem]) throws
    func loadItems() throws -> [ClipboardItem]
    func clearItems() throws
}
```

### 2. Annotation & Export Protocol

```swift
public protocol AnnotationCommand: Sendable {
    func apply(to context: CGContext, scale: CGFloat)
}

public protocol ImageExportServiceProtocol: Sendable {
    func renderAnnotatedImage(baseImage: CGImage, commands: [AnnotationCommand], cropRect: CGRect?) -> CGImage
    func exportToPNG(image: CGImage) -> Data?
    func exportToJPEG(image: CGImage, quality: CGFloat) -> Data?
}
```

---

## E2E Testing Track
The E2E Testing Track runs in parallel with the Implementation Track. It creates `TEST_INFRA.md`, builds Tier 1–4 automated tests in `Tests/GoldenGateCoreTests/E2E/`, and generates `TEST_READY.md`. The project is not complete until Milestone 7 executes and passes all E2E tests.
