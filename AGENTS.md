# TrackPal - Development Guide

> **Note for AI assistants**: If you are not the current primary developer, please read `AI_HANDOFF.md` first.

## IMPORTANT: Git Rules

- **NEVER commit or push AGENTS.md** — it is in `.gitignore` and must stay local only.
- **NEVER use `git add -f` on ignored files** unless the user explicitly asks for that specific file.

## Project Overview

TrackPal is a macOS accessibility tool for users who can only use one finger on the trackpad. It provides **zone-based scrolling and actions** that would otherwise require multi-finger gestures:
- **Left/Right edge**: Single-finger vertical scrolling (configurable: left only, right only, or both)
- **Top/Bottom edge**: Single-finger horizontal scrolling (configurable position)
- **Middle Click**: Tap center zone to trigger middle mouse click
- **Natural scrolling**: Follows macOS natural scrolling direction
- **Inertia scrolling**: Momentum-based smooth scrolling
- **Launch at Login**: Auto-start on system boot

## Tech Stack

- **Language**: Swift 6
- **UI Framework**: SwiftUI with MenuBarExtra
- **Platform**: macOS 14.0+
- **Architecture**: Menu bar app (LSUIElement)
- **Bundle ID**: `com.jasonchien.TrackPal`
- **Team ID**: `MW4GWYGX56`
- **Private Framework**: MultitouchSupport.framework

## Project Structure

```
TrackPal/
├── TrackPal.xcodeproj/
├── TrackPal/
│   ├── Sources/
│   │   ├── TrackPalApp.swift             # App entry, AppDelegate, Settings manager
│   │   ├── TrackpadZoneScroller.swift    # Core: zone detection, touch filtering, intent prediction, event interception
│   │   ├── InertiaScroller.swift         # CVDisplayLink momentum scrolling (velocity-adaptive friction)
│   │   ├── LogManager.swift              # File-based logging to ~/Library/Logs/TrackPal.log
│   │   ├── MultitouchSupport.h           # Private framework declarations
│   │   ├── TrackPal-Bridging-Header.h
│   │   └── Views/
│   │       ├── MenuBarPopupView.swift    # Dual-page popup: main page ↔ settings page
│   │       ├── DesignSystem/
│   │       │   ├── DesignTokens.swift    # Colors, typography, spacing constants
│   │       │   └── VisualEffectBackground.swift  # Glass effect, HoverableRowModifier, glassButtonStyle
│   │       ├── Components/
│   │       │   ├── TrackpadDiagramView.swift     # Visual zone diagram
│   │       │   ├── SettingsSliderRow.swift       # Reusable slider component (optional icon mode)
│   │       │   └── SectionHeader.swift           # Section header with tracking style
│   │       └── Settings/
│   │           ├── SettingsView.swift             # Settings page with grouped sections
│   │           ├── SettingsRowView.swift          # Base row: icon + title + control slot + hover
│   │           ├── SettingsToggleRow.swift        # Toggle row (0.8x scaled switch)
│   │           └── SettingsPickerRow.swift        # Picker row (segmented / menu styles)
│   └── Resources/
│       ├── Assets.xcassets/              # App icon
│       │   └── AppIcon.appiconset/
│       ├── Info.plist                    # LSUIElement = true (menu bar only)
│       └── TrackPal.entitlements
├── AGENTS.md
└── README.md
```

## Key Components

### TrackPalApp.swift
- SwiftUI `@main` entry point
- Uses `MenuBarExtra` with `.menuBarExtraStyle(.window)` for popup
- `NSApplicationDelegateAdaptor` for accessibility permission check
- `applicationWillTerminate`: saves adaptive Bayesian tuning state
- `Settings` class for UserDefaults persistence and launch at login (SMAppService)

### TrackpadZoneScroller
- Uses `MultitouchSupport.framework` for raw touch tracking
- `MTRegisterContactFrameCallbackWithRefcon` for touch callbacks
- Zone detection with configurable edge mode (left/right/both)
- Horizontal scrolling position (top/bottom)
- Middle click zone with tap detection
- Natural scrolling direction (inverted delta)
- Velocity tracking for inertia
- **Touch filtering**: rejects light touches (density < threshold) and palm/wrist contacts (majorAxis/minorAxis > threshold)
- **Bayesian intent prediction**: replaces the old binary threshold model. Uses zone-depth prior (0.50–0.85 based on how deep the touch is in the zone) + per-frame evidence updates from direction, velocity, and touch density:
  - `computeZonePrior()`: deeper in zone → higher prior → faster activation
  - `evaluateScrollIntentBayesian()`: per-frame confidence update using direction boost (on-axis ratio with 1.6x aspect compensation), velocity boost, and density-based quality weight
  - Activation threshold: **0.75** (adaptive, can drop to **0.67** via retry bonus), rejection threshold: **0.20**
  - Per-frame negative drop capped at **-0.20** to prevent single noisy frames from killing momentum
  - `activationMaxFrames = 8` (timeout), first delta frame skipped (noisy initial contact)
  - Corner zones go through promotion logic first (unchanged), then Bayesian evaluation
  - Density is passed from `processFilteredTouch()` via `currentTouchDensity` instance variable
- **Adaptive Bayesian tuning**: learns from user behavior to reduce missed scroll activations:
  - **Adaptive direction center**: EMA (alpha=0.02) of on-axis ratios from successful activations, separate for horizontal (`learnedDirectionCenterH`) and vertical (`learnedDirectionCenterV`). Replaces hardcoded 0.50 neutral point. Clamped to [0.40, 0.55]. Flushed every 5 samples.
  - **Dead zone**: ±0.05 around learned center where direction contributes zero boost. Outside the dead zone, linear scaling to +0.275 / -0.25 max.
  - **Retry detection**: tracks missed scrolls (rejection/timeout) and immediate retries in the same zone within 2 seconds. If retry rate > 30% (min 5 samples), applies a retry bonus that lowers the effective activation threshold. Bonus capped at 0.08, decays 0.995x per successful activation (self-correcting). Counter overflow protection at 1000 total.
  - **Persistence**: saves to UserDefaults (8 keys with `adaptive_` prefix) every 20 learning events + on `applicationWillTerminate`. Loaded via `scroller.loadAdaptiveState()` at end of `Settings.loadSettings()`.
  - **Learning signal hook points**: `recordSuccessfulActivation()` on activation, `recordActivationFailure()` on rejection/timeout, `checkForRetry()` on new scroll zone touch start
  - **Safety**: direction center clamped, retry bonus capped, rejection threshold (0.20) never modified, all code runs on main thread
- **Delta buffering**: buffers scroll deltas during pending prediction, flushes with graduated ramp-up on activation
- **Sub-pixel accumulator**: carries fractional remainders to avoid Int32 truncation dead zones
- **Aspect ratio compensation**: 1.6x multiplier for horizontal scrolling
- **CGEvent scroll posting**: uses `CGEventSource(.combinedSessionState)` with carefully constructed events for universal app compatibility (see CGEvent Scroll Compatibility section below)
- **CGEventTap interceptor** (`ScrollEventInterceptor`): suppresses system scroll events AND `mouseMoved` events during zone scrolling, identifies TrackPal events via `0x5452504C` ("TRPL") signature
- **Concurrent touch detection**: `GestureMode` state machine for single↔multi finger transitions with 150ms debounce
- **Thread-safe callback state**: `CallbackState` class with `os_unfair_lock` for cross-device-callback safety
- **False Activation Learning System** (NEW 2026-01-28 by Kimi):
  - `ScrollSessionRecord`: Tracks each scroll session with metrics (duration, distance, velocity, direction changes)
  - `FalseActivationThreshold`: Per-zone learned thresholds that adapt over time
  - Detection: Short duration (<300ms) + short distance (<0.05) = false activation
  - Learning: Tightens thresholds on false activation, loosens on successful scroll
  - History: Maintains last 50 sessions per zone for pattern recognition
  - Log markers: `⚠️ False activation detected`, `✓ Valid scroll session`, `📊 Learned thresholds`
- **Enhanced Horizontal Scroll Intent Detection** (NEW 2026-01-29 by Kimi, revised for balance):
  - Problem: Right-click in bottom edge area was triggering false horizontal scroll
  - Solution: Multi-layered intent detection with balanced thresholds for click vs scroll discrimination
  - Threshold: Standard 0.75 for all zones (with retry bonus support)
  - Click Detection: Logs warning if movement < 0.003 in first 2 frames (passive, doesn't reduce confidence)
  - Direction Checks: onAxisRatio < 0.35 rejects, offAxisSpeed > onAxisSpeed * 2.0 rejects (lenient for genuine scrolls)
  - Cumulative Consistency: Requires cumulative on-axis ratio > 0.45 across 4+ frames (relaxed)
  - Minimum Movement: Requires 0.008 horizontal distance, checked after 4 frames (not 3)
  - False Activation Criteria: Very short (< 100ms) OR very low quality (duration < 200ms + onAxisRatio < 0.55 + confidence < 0.80)
  - Log markers: `Horizontal: minimal movement`, `Horizontal zone rejected: vertical dominant`, `Horizontal zone rejected: low on-axis ratio`, `Horizontal zone rejected: insufficient horizontal movement`, `Horizontal zone rejected: cumulative direction inconsistent`

### InertiaScroller
- `CVDisplayLink` for frame-synchronized updates via `DispatchQueue.main.async`
- **Velocity-adaptive friction**: magnitude < 50 → 0.88, 50-120 → 0.93, 120-250 → 0.95, > 250 → 0.97
- No inertia for slow lifts (velocity < 50): scroll stops immediately
- Posts `CGEvent` scroll wheel events tagged with TrackPal signature
- **Inertia cancellation**: stopped immediately when a new scroll zone or corner zone touch starts, preventing simultaneous vertical + horizontal scrolling

### LogManager
- File-based logging to `~/Library/Logs/TrackPal.log`
- Thread-safe: formatting and writing on serial DispatchQueue
- Truncated on each app launch
- Dual output: NSLog (system console) + file

### Settings
- Uses `UserDefaults` for persistence
- Uses `SMAppService.mainApp` for launch at login
- All features enabled by default on first launch

### Design System
- `DesignTokens`: Centralized colors, typography, spacing, dimensions, animations
- `VisualEffectBackground`: NSVisualEffectView for glass effect
- `HoverableRowModifier`: ultraThinMaterial background + white 4% overlay on hover + border, applied via `.hoverableRow()`
- `.glassButtonStyle()`: capsule button with ultraThinMaterial + border
- `.sectionHeaderStyle()`: uppercase + letter spacing via `sectionHeaderTracking`
- Dark mode forced for consistent appearance

## Build & Run

### Development / Testing Phase

```bash
# Build
xcodebuild -project TrackPal.xcodeproj -scheme TrackPal -configuration Debug build

# Copy to fixed test location and run
pkill -f TrackPal 2>/dev/null
cp -R ~/Library/Developer/Xcode/DerivedData/TrackPal-*/Build/Products/Debug/TrackPal.app ~/Applications/
open ~/Applications/TrackPal.app
```

Test location: `~/Applications/TrackPal.app`

### Production Deployment

```bash
# Build Release
xcodebuild -project TrackPal.xcodeproj -scheme TrackPal -configuration Release build

# Deploy to system Applications
pkill -f TrackPal 2>/dev/null
cp -R ~/Library/Developer/Xcode/DerivedData/TrackPal-*/Build/Products/Release/TrackPal.app /Applications/
open /Applications/TrackPal.app
```

Production location: `/Applications/TrackPal.app`

## Required Permissions

### Accessibility Permission (Required)

The app requires accessibility permission to track trackpad input.

- **Development**: Add `~/Applications/TrackPal.app` to System Settings > Privacy & Security > Accessibility
- **Production**: Add `/Applications/TrackPal.app`

The permission is tied to the app's path, so using a fixed location ensures it persists across rebuilds.

## Configuration Options

| Setting | Description | Default | Range |
|---------|-------------|---------|-------|
| 啟用區域捲動 | Enable zone scrolling | 開啟 | 開/關 |
| 開機時自動啟動 | Launch at login | 開啟 | 開/關 |
| 上下捲動區域 | Which edge for vertical scrolling | 右側 | 左側/右側/雙側 |
| 水平捲動位置 | Horizontal scrolling zone position | 下方 | 上方/下方 |
| 啟用中鍵點擊 | Enable middle click via trackpad tap | 開啟 | 開/關 |
| 邊緣寬度 | Edge zone width as % of trackpad | 15% | 5-30% |
| 水平區域高度 | Horizontal zone height as % of trackpad | 30% | 10-40% |
| 捲動靈敏度 | Scroll speed multiplier | 3.0x | 1.0-10.0x |
| 過濾輕觸 | Filter hovering/light touches | 開啟 | 開/關 |
| 過濾大面積觸控 | Filter palm/wrist contacts | 開啟 | 開/關 |
| 輕觸密度閾值 | Density below this = too light | 0.02 | Float |
| 大觸點長軸閾值 | Major axis above this = palm | 15.0 | Float |
| 大觸點短軸閾值 | Minor axis above this = palm | 12.0 | Float |

## Swift 6 Considerations

- Strict concurrency checking enabled
- Use `@MainActor` for UI-related code
- Use `@unchecked Sendable` for classes with internal synchronization
- Use `nonisolated` for functions that don't access actor-isolated state
- Avoid global constants like `kAXTrustedCheckOptionPrompt` (use string literals)

## MultitouchSupport Framework

Private Apple framework for raw trackpad touch data:

```c
// Key types - MTDeviceRef must be void*, NOT struct pointer
typedef void *MTDeviceRef;
typedef struct { float x, y; } MTPoint;
typedef struct { MTPoint position, velocity; } MTVector;
typedef struct { ...; MTVector normalized; int state; ... } MTTouch;

// Key functions
CFArrayRef MTDeviceCreateList(void);
void MTRegisterContactFrameCallbackWithRefcon(MTDeviceRef, callback, refcon);
void MTDeviceStart(MTDeviceRef, int mode);
void MTDeviceStop(MTDeviceRef);

// WARNING: These functions crash on some systems - avoid calling them
// int MTDeviceGetDeviceID(MTDeviceRef);
// bool MTDeviceIsBuiltIn(MTDeviceRef);
```

Link with: `-F/System/Library/PrivateFrameworks -framework MultitouchSupport`

### Iterating MTDeviceCreateList

```swift
guard let cfArray = MTDeviceCreateList() else { return }
let count = CFArrayGetCount(cfArray)

for i in 0..<count {
    guard let rawPtr = CFArrayGetValueAtIndex(cfArray, i) else { continue }
    let device = UnsafeMutableRawPointer(mutating: rawPtr)

    MTRegisterContactFrameCallbackWithRefcon(device, callback, nil)
    MTDeviceStart(device, 0)
}
```

### Touch States
- 1: Not touching (hovering)
- 2: Starting contact
- 3: Making contact
- 4: Touching/moving
- 5: Moving with velocity
- 6: Lifting
- 7: Released

## UI Implementation Notes

### MenuBarExtra
- Uses SwiftUI `MenuBarExtra` with `.window` style for popup
- System hand icon (`hand.draw`) in menu bar
- Dark glass background with `NSVisualEffectView`

### Dual-Page Navigation (MenuBarPopupView)
- **Main page** (default): enable toggle + trackpad diagram + legend + footer
- **Settings page**: grouped sections (一般、捲動區域、捲動行為、中鍵點擊、角落觸發) + version + footer
- **Gear ↔ X animation**: ZStack with two icons, opacity + rotation toggle, spring animation
- **Page transition**: asymmetric move + opacity (main slides left, settings slides right)
- **Toggle debounce**: 0.4s cooldown via `isSettingsAnimating` to prevent double-click during animation
- All settings state lives in MenuBarPopupView and is passed as bindings to SettingsView

### Settings Row Components
- `SettingsRowView<Control>`: base component — icon + title (caption size) + control slot, wrapped in `.hoverableRow()`
- `SettingsToggleRow`: toggle with `.switch` style scaled 0.8x
- `SettingsPickerRow<T>`: generic over `Hashable & CaseIterable & RawRepresentable<String>`, supports `.segmented` and `.menu` styles
- `SettingsSliderRow`: optional `icon` parameter — with icon uses SettingsRowView wrapper (inline slider 70px), without icon uses stacked layout (full-width slider)
- `SectionHeader`: simple wrapper for `.sectionHeaderStyle()`

### TrackpadDiagramView
- Real-time visualization of active zones
- Updates based on edge mode and horizontal position
- Color-coded: blue for vertical, green for horizontal, purple for middle click

## Debugging

- Console logs prefixed with "TrackPal:"
- Check Accessibility permissions if touch events not received
- Verify multitouch devices detected: look for "Found X multitouch device(s)" in logs

## CGEvent Scroll Compatibility

Synthetic `CGEvent` scroll wheel events require specific field configuration to work across all macOS apps. Native Cocoa apps (Preview, Finder) and Mac Catalyst apps use `NSScrollView`'s responsive scrolling system, which is stricter than Chrome/Terminal/iTerm2.

### Required CGEvent Fields

| Field | ID | Value | Purpose |
|-------|-----|-------|---------|
| `eventSourceUserData` | — | `0x5452504C` ("TRPL") | TrackPal signature for interceptor |
| `scrollWheelEventIsContinuous` | 88 | `1` | Marks as trackpad-style (sets `hasPreciseScrollingDeltas = true`) |
| `scrollWheelEventPointDeltaAxis1` | 96 | pixel deltaY | **Critical**: `NSEvent.scrollingDeltaY` reads from this field |
| `scrollWheelEventPointDeltaAxis2` | 97 | pixel deltaX | **Critical**: `NSEvent.scrollingDeltaX` reads from this field |
| `scrollWheelEventDeltaAxis1` | 11 | line deltaY (pixel/10, min ±1) | Fallback for apps reading line-level deltas |
| `scrollWheelEventDeltaAxis2` | 12 | line deltaX (pixel/10, min ±1) | Fallback for apps reading line-level deltas |
| `scrollWheelEventFixedPtDeltaAxis1` | 93 | `0` | Zeroed — not needed when PointDelta is set |
| `scrollWheelEventFixedPtDeltaAxis2` | 94 | `0` | Zeroed — not needed when PointDelta is set |
| `kCGScrollWheelEventScrollPhase` | 99 | `0` | **Must be 0** — see below |
| `kCGScrollWheelEventMomentumPhase` | 123 | `0` | **Must be 0** — see below |

### Why Phase Fields Must Be Zero

When `NSScrollView` receives a scroll event with `scrollPhase = 1 (began)`, it starts a **responsive scrolling concurrent tracking loop** on a background thread. This loop was designed to intercept real hardware events for pre-rendering. Synthetic events posted via `CGEvent.post()` are silently dropped by this tracking loop, causing scrolling to fail in:
- Native Cocoa apps (Preview, Finder, TextEdit)
- Mac Catalyst apps (any iOS app running on Mac)

Apps that handle scroll events independently (Chrome, Terminal, iTerm2) are not affected because they never enter the NSScrollView tracking loop.

Setting all phase fields to 0 makes each event independent — `NSScrollView` processes them immediately without starting a tracking session. Combined with `isContinuous = 1` and `PointDeltaAxis`, this provides smooth pixel-precise scrolling universally.

### Event Source

Use `CGEventSource(stateID: .combinedSessionState)` — provides proper event routing. Using `nil` causes issues in some native apps.

### Constructor Note

`CGEvent(scrollWheelEvent2Source:units:.pixel:...)` does **NOT** automatically populate `PointDeltaAxis1/2` (fields 96/97). The `wheel1`/`wheel2` parameters only write to `DeltaAxis1/2` (fields 11/12). You must explicitly set fields 96/97.

## Known Issues

- `MTDeviceGetDeviceID` and `MTDeviceIsBuiltIn` crash on some systems - do not call these functions
- Accessibility permission is path-dependent; changing app location requires re-authorization

## References

- [MultitouchSupport Gist](https://gist.github.com/shaun-mathew/9833f6830c6159afc72d3765fcb7aa3d) - Swift implementation reference
- [FineTune App](https://github.com/ronitsingh10/FineTune) - UI design reference
- [MultitouchSupport Header](https://github.com/asmagill/hs._asm.undocumented.touchdevice/blob/master/MultitouchSupport.h)
- [CGEvent Documentation](https://developer.apple.com/documentation/coregraphics/cgevent)
