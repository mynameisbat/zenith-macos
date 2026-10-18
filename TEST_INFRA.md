# GoldenGate Test Infrastructure & Methodology (`TEST_INFRA.md`)

## 1. Testing Philosophy & Methodology

### 1.1 Opaque-Box & Requirement-Driven Testing
The GoldenGate automated test infrastructure is designed under an **opaque-box, requirement-driven philosophy**:
- **Interface & Behavior Verification**: Tests interact strictly with public domain contracts, public protocols, domain models, and observable state boundaries. Tests make zero assumptions about private implementation mechanisms or internal control flow.
- **Requirement Traceability**: Every test suite and test case maps directly to requirements specified in `ORIGINAL_REQUEST.md` (R1–R6) and features cataloged in `PROJECT.md` (F01–F48).
- **Authoritative Expected Outputs**: Expected outputs are derived mathematically, logically, and deterministically from:
  1. The explicit specifications in `ORIGINAL_REQUEST.md` and `PROJECT.md`.
  2. macOS platform standards (HIToolbox virtual keycodes, Carbon modifier masks, CoreGraphics coordinate spaces, and Apple TCC URL schemes).
  3. Strict domain invariants (e.g. history capacity bounded to `[5, 500]`, non-negative and finite bounding geometry, lossless text payload integrity).

### 1.2 Headless & Deterministic Execution
GoldenGate runs natively on macOS, but its test suite must execute cleanly in continuous integration (CI) environments and headless terminals without physical screens, active audio speakers, or window server interactive prompts.
- **Dependency Inversion**: Core domain logic relies on service protocols (`PasteboardServiceProtocol`, `ScreenCaptureServiceProtocol`, `SoundServiceProtocol`, `HotKeyServiceProtocol`, `PermissionsServiceProtocol`).
- **Headless Mocks**: Pure, thread-safe, mock implementations (`MockScreenCaptureService`, `MockPasteboardService`, `MockSoundService`, `MockHotKeyService`, `MockPermissionsService`) simulate real-world behaviors without triggering OS dialogs or TCC permission errors (e.g., TCC `-3801`).
- **CoreGraphics Synthetic Buffers**: Image processing and vector annotations are rendered against headless in-memory `CGContext` buffers.

---

## 2. Four-Tier Testing Architecture

The test suite is structured into four progressive tiers to ensure total behavioral and boundary coverage:

```
┌────────────────────────────────────────────────────────────────────────┐
│               Tier 4: Real-World Application Scenarios                 │
│  - Multi-step end-to-end user workflows & lifecycle simulations        │
└───────────────────────────────────┬────────────────────────────────────┘
                                    │ integrates
┌───────────────────────────────────▼────────────────────────────────────┐
│               Tier 3: Cross-Feature Pairwise Interactions               │
│  - Inter-service communication, side-effects & state synchronization   │
└───────────────────────────────────┬────────────────────────────────────┘
                                    │ composes
┌───────────────────────────────────▼────────────────────────────────────┐
│               Tier 2: Boundary & Corner Cases (>=5 / feature)          │
│  - Extreme limits, malformed inputs, off-by-one, overflow, zero-values │
└───────────────────────────────────┬────────────────────────────────────┘
                                    │ validates
┌───────────────────────────────────▼────────────────────────────────────┐
│               Tier 1: Feature Coverage (>=5 / feature)                 │
│  - Happy paths & core contract validation across all 6 feature domains  │
└────────────────────────────────────────────────────────────────────────┘
```

### Tier 1: Feature Coverage (>= 5 tests per feature domain)
Validates primary behavior (happy paths) of each distinct feature domain in isolation:
- **Feature Domain 1 (R1 - Clipboard History & Ingestion)**: Ingest plain text, rich text (RTF), image payloads, compute preview strings, calculate byte size, verify model immutability.
- **Feature Domain 2 (R2 - Screen Capture & Display Region)**: Capture main display, capture arbitrary bounding regions, verify synthetic image generation, calculate pixel dimensions.
- **Feature Domain 3 (R3 - Annotation Commands & Vector Canvas)**: Execute Pen smoothed strokes, directional Arrow wings, Rectangle stroked/filled shapes, Text labels, and Blur privacy mosaic masks.
- **Feature Domain 4 (R4 - Audio Feedback & Mute Management)**: Play new copy pop, paste cue, camera shutter click, assert counter increments and audio event logging.
- **Feature Domain 5 (R5 / R1 / R2 - Global HotKey Management)**: Register hotkeys, verify keycode and modifier masks, trigger simulation, dispatch handlers, assert registrations.
- **Feature Domain 6 (R6 - Settings Persistence & System Permissions)**: Default settings initialization, persistence across instances, snapshot roundtrip, permissions query and deep-link verification.

### Tier 2: Boundary & Corner Cases (>= 5 tests per feature domain)
Subject each feature domain to boundary conditions, invalid inputs, and stress:
- **Feature Domain 1 (R1 - Clipboard Boundaries)**: Zero-length strings, whitespace-only content, massive UTF-8 strings (100k+ chars), binary image data with 0x0 or extreme dimensions, pinned item protection during eviction.
- **Feature Domain 2 (R2 - Screen Capture Boundaries)**: 1x1 minimal pixel crop, maximum display dimension limits, non-positive rects, NaN/Infinity coordinates, permission denied error throwing.
- **Feature Domain 3 (R3 - Annotation Boundaries)**: Empty point sets (0 points), single-point pen command, zero-dimension rectangles, zero-length arrows, empty text strings, extreme stroke widths.
- **Feature Domain 4 (R4 - Audio Boundaries)**: Immediate mute toggle suppression, consecutive rapid audio bursts, sound effect reset preservation, empty sound history.
- **Feature Domain 5 (R5 / R1 / R2 - HotKey Boundaries)**: Duplicate hotkey registration override, registration failure handling, multiple modifier bitwise combinations, unregister non-existent IDs.
- **Feature Domain 6 (R6 - Settings Boundaries)**: `Int.min` and `Int.max` history limit clamping, off-by-one capacity boundaries (4 -> 5, 501 -> 500), corrupted settings recovery, permission denial state transitions.

### Tier 3: Cross-Feature Interactions
Validates state synchronization and behavioral contracts when multiple features operate together:
1. **Screen Capture + Audio Feedback**: Screenshot capture triggers shutter sound; respects mute setting.
2. **Screen Capture + Annotation Engine + Pasteboard Export**: Captured region rendered with vector annotations and exported to pasteboard.
3. **Clipboard Monitoring + Audio Feedback**: External pasteboard copy triggers new copy sound; muted toggle suppresses sound.
4. **HotKey Trigger + Pasteboard Restoration**: Global hotkey simulation triggers selected item restoration to system pasteboard and emits paste sound.
5. **SettingsStore + HotKey Service Synchronization**: Mutating hotkey configuration updates registered hotkeys in the hotkey manager.
6. **SettingsStore + Sound Service Mute Sync**: Toggling sound effects in SettingsStore instantly updates `MockSoundService.isMuted`.
7. **SettingsStore Capacity + Clipboard Eviction**: Ingestion pipeline enforces SettingsStore `historyLimit`, evicting oldest unpinned items while retaining pinned items.
8. **Permissions Gate + Screen Capture**: Capturing display verifies Screen Recording permission; aborts or redirects when permission is denied.

### Tier 4: Real-World Application Scenarios
End-to-end scenarios simulating full user workflows and edge-case lifecycle operations:
1. **Full Screenshot & Annotation Workflow**: Global shortcut trigger -> Area capture -> Camera shutter sound -> Vector annotations (pen, arrow, text, blur) -> In-editor `Cmd+C` copy to pasteboard -> Editor dismiss.
2. **Clipboard History Overflow & Pinned Item Workflow**: Continuous copying of plain text, rich text, and images -> History reaches configured limit -> FIFO eviction purges oldest unpinned items while protecting pinned items -> Search and restore to pasteboard.
3. **Shortcut Customization & Reconfiguration Lifecycle**: User updates global hotkey in Settings -> Hotkey manager unregisters previous combination and registers new combination -> User triggers new shortcut -> Settings reset to defaults restores standard shortcuts.
4. **First-Launch Permission Onboarding Flow**: App launches with ungranted permissions -> User attempts screen capture -> Permission check detects missing access -> Settings deep-link opened -> User grants permission -> Capture succeeds.
5. **Audio Feedback Toggle Workflow**: Rapid clipboard copy and screen capture with sound -> User mutes audio in Settings -> Subsequent operations produce zero sound effects -> User unmutes -> Audio cues resume.
6. **Multi-Format Mixed Ingestion Workflow**: Alternating plain text, rich text, and screenshot images -> Ingestion preserves exact format payload, previews, and byte counts -> Retrieval preserves data fidelity.

---

## 3. Feature Mapping Matrix

| Feature Domain | Requirement (`ORIGINAL_REQUEST.md`) | Features (`PROJECT.md`) | Tier 1 Tests | Tier 2 Tests | Tier 3 Tests | Tier 4 Scenarios |
|---|---|---|---|---|---|---|
| **Clipboard History** | R1 | F01–F05, F08–F12 | >= 5 | >= 5 | Verified | Verified |
| **Screen Capture & Loupe** | R2 | F13–F20 | >= 5 | >= 5 | Verified | Verified |
| **Image Annotation** | R3 | F21–F32, F48 | >= 5 | >= 5 | Verified | Verified |
| **Audio Feedback** | R4 | F33–F36 | >= 5 | >= 5 | Verified | Verified |
| **Global HotKeys** | R1, R2, R6 | F06, F13, F14, F46 | >= 5 | >= 5 | Verified | Verified |
| **Settings & Permissions** | R6 | F44, F45, F47 | >= 5 | >= 5 | Verified | Verified |

---

## 4. Test Runner Invocation

### Executing All Tests
The entire test suite (Unit Tests, Stress Tests, and Tiers 1–4 E2E Suites) can be invoked via standard Swift Package Manager:

```bash
swift test
```

### Filtering Specific Tiers
To execute a specific tier suite:
```bash
# Run Tier 1 Feature Coverage
swift test --filter Tier1FeatureCoverageTests

# Run Tier 2 Boundary & Corner Cases
swift test --filter Tier2BoundaryCornerTests

# Run Tier 3 Cross-Feature Interactions
swift test --filter Tier3CrossFeatureTests

# Run Tier 4 Real-World Application Scenarios
swift test --filter Tier4ApplicationScenarioTests
```

### Verification Criteria
- All tests must complete with **exit code 0**.
- Zero regressions in existing Milestone 1 tests (34 tests).
- 100% headless execution with zero dependency on display or audio hardware.
