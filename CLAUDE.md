# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build & Run

```bash
bash build.sh          # Release build → signs → installs to /Applications/Imperator EQ.app
swift build            # Debug build only (no app bundle)
open "/Applications/Imperator EQ.app"
```

`build.sh` runs `swift build -c release`, assembles the .app bundle (copies Info.plist, AppIcon.icns, BlackHole2ch.driver), ad-hoc codesigns with `codesign --sign - --force --deep`, and copies to /Applications. The codesign step is mandatory — without it Gatekeeper blocks the app.

There are no tests and no linter configured.

## Architecture

Imperator EQ is a macOS menu bar app (LSUIElement, no Dock icon) that applies a system-wide 10-band parametric EQ. It captures all system audio via BlackHole 2ch virtual loopback, processes it through an AUNBandEQ Audio Unit, and routes it to the real output device.

### Audio Signal Chain

```
System audio → BlackHole 2ch (set as default output)
             → Aggregate Device (BlackHole input + real output)
             → AUHAL (kAudioUnitSubType_HALOutput)
             → AUNBandEQ (10 bands, ±12dB, Q=1.0)
             → Volume/Balance boost (1.5x compensation)
             → Real speakers/headphones
```

### Key Files

- **AudioEngine.swift** — Core audio: creates aggregate device, configures AUHAL + AUNBandEQ, render callbacks (real-time thread), device switching, crash recovery (`AudioRecovery`), preventive watchdog (restarts every 4 min to work around silent AUHAL stalls)
- **EQStore.swift** — `@MainActor ObservableObject` with all UI state (`bands`, `volume`, `balance`, `isEnabled`, `presets`). Persists to `state.json`/`presets.json` in Application Support. Auto-saves via Combine debounce (1s)
- **AppDelegate.swift** — Status bar item, NSPopover (340pt wide, `.transient`), Combine bindings from EQStore → AudioEngine
- **PopoverContentView.swift** — Main SwiftUI layout: header, output devices, volume, balance, EQ bands, presets, footer. Posts `.imperatorPopoverResize` notification when collapsible sections expand/collapse
- **Theme.swift** — `AppColors` enum with brand colors per Imperator brandbook

### Critical Patterns

**Real-time audio thread safety**: Render callbacks run on a CoreAudio real-time thread. No Swift allocations, no locks, no Objective-C messaging in callbacks. The watchdog uses `OSAllocatedUnfairLock<Int64>` for atomic heartbeat/error counters shared between the real-time thread and the background watchdog.

**Aggregate device lifecycle**: AudioEngine creates a non-private aggregate device combining BlackHole (with drift compensation enabled) and the real output. On stop/crash, `AudioRecovery` restores the original default output device from a recovery file.

**@MainActor isolation**: AudioEngine, EQStore, and AppDelegate are all `@MainActor`. The watchdog timer runs on a dedicated `DispatchQueue` background thread to avoid blocking the main actor.

**Unmanaged reference bridging**: Render callbacks receive context via `Unmanaged<RenderContext>.passRetained()` / `.takeUnretainedValue()`. The context is released in `stop()`.

## Brandbook

Colors and UI must follow the Imperator Apps BrandBook (separate repo). Key rules:
- Color enum is `AppColors` (not `Theme`), brand color `#A01818`
- Never use bare `Color.accentColor` — always `AppColors.brand`
- Popover width: 340pt
- Dark mode forced: `NSApp.appearance = NSAppearance(named: .darkAqua)`
- `UserDefaults.standard.set(0, forKey: "AppleAccentColor")` at launch
- Toggle: `.switch` style, scale 0.55, frame 36x20, tint `AppColors.brand`

## Known Issue

AUHAL render callback silently stops after 5-30 minutes with no error. Current mitigation: preventive restart every 4 minutes via watchdog. Root cause investigation documented in `docs/AUDIO_ENGINE_INVESTIGATION.md`.

## Dependencies

Zero external Swift packages. Uses only Apple frameworks: AudioToolbox, CoreAudio, AppKit, SwiftUI, Combine, ServiceManagement, os.
