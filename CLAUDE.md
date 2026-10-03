# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build & Run

```bash
bash build.sh          # Universal release build, signs, installs to /Applications/Imperator EQ.app
swift build            # Debug build only (no app bundle)
open "/Applications/Imperator EQ.app"
"/Applications/Imperator EQ.app/Contents/MacOS/ImperatorEQ" --about-check   # brandbook gate
open -n -a "Imperator EQ" --args --engine-check --report /tmp/engine-check.json   # audio path gate
```

Releases follow the steps in README's Release section: tag `vx.y.z`, title `Imperator EQ x.y.z`,
asset `Imperator-EQ-x.y.z.zip`, and `CFBundleVersion` equal to the commit count including the
release commit.

`build.sh` runs `swift build -c release --arch arm64 --arch x86_64`, assembles the .app bundle (copies Info.plist and AppIcon.icns), codesigns, and copies to /Applications. The codesign step is mandatory: without it Gatekeeper blocks the app.

Two things in `build.sh` are load-bearing and must not be simplified away:

- **SDK stamp.** `-Xlinker -platform_version -Xlinker macos -Xlinker 14.2 -Xlinker <sdk>` stamps `LC_BUILD_VERSION` with the current SDK while keeping the deployment target at macOS 14.2, the first release with Core Audio process taps. AppKit picks which generation of a control to draw from that `sdk` field, and SwiftPM otherwise stamps it with the deployment target. Verify with `otool -l <binary> | awk '/LC_BUILD_VERSION/,/^$/'`: it must read `minos 14.2` and the current `sdk`. `MIN_MACOS` in build.sh and `platforms:` in Package.swift must stay equal.
- **Stable signing identity.** The app signs with `Imperator Dev`, not ad-hoc. An ad-hoc designated requirement is the cdhash, which changes every build, so macOS treats each update as a new app and drops its TCC grants. This app needs the System Audio Recording grant (see below), so ad-hoc would mean re-granting on every update. Override with `IMPERATOR_SIGN_IDENTITY`.

There are no tests and no linter configured. Two gates are built into the binary:

- `--about-check` builds the About panel and measures it against brandbook 10.2 and 10.3, printing `ABOUT_PANEL_OK` on success.
- `--engine-check --report <path>` runs the real `TapPipeline` headless and writes JSON: start/stop cycles (tap and aggregate counts must return to the baseline; the HAL drops destroyed objects from its lists about 12 ms after the destroy call returns, so count after it settles), the tap's readback (private, `mutedWhenTapped`, this process excluded), and levels per phase once a tone arrives from another process (flat, 1 kHz +12 dB, and a tail after the tone ends that must read silence). `--mode soak --seconds N` runs flat for N seconds instead. Launch it with `open -n` so TCC applies the app's own grant; a process started from a terminal is attributed to the terminal. Quit the app first: two taps on one device play the sound twice.

## System Audio Recording permission

Reading a process tap needs the **System Audio Recording Only** grant (TCC service `kTCCServiceAudioCapture`, Info.plist key `NSAudioCaptureUsageDescription`, both confirmed in `tccd`). It lives in System Settings > Privacy & Security > Screen & System Audio Recording; `SystemAudioAccess.settingsURL` opens exactly that pane. The app does not need microphone access and does not declare it.

There is no public API to read or request this grant. A tap without it reads silence, and a tap set to mute the apps it captures would then leave the Mac silent, so the state has to be known before starting. `SystemAudioAccess` looks up `TCCAccessPreflight` and `TCCAccessRequest` in the private TCC framework at runtime (0 granted, 1 denied, otherwise not asked). If they disappear, the status is `.unknown` and the engine starts anyway, letting macOS prompt on first read.

`AudioEngine` polls the status every 2 s while the switch is on, so a switch flipped in System Settings takes effect without a restart, and a revocation while running stops the engine (which unmutes the apps) instead of leaving them muted behind a silent tap.

## Never block the main thread on CoreAudio

Creating a tap, an aggregate device or an IOProc, and starting IO, all wait on coreaudiod, and some wait on a permission decision. Done in `applicationDidFinishLaunching`, that wait freezes the app before the status item is ever drawn. Everything that builds, changes or tears down the pipeline runs on `EngineController`'s serial queue. Plain property reads (device lists, the default output, UIDs) are fine on the main thread.

Do not add `kAudioAggregateDeviceTapAutoStartKey` to the aggregate description: with it, `AudioDeviceStart` waits until an app starts playing.

## Architecture

Imperator EQ is a macOS menu bar app (LSUIElement, no Dock icon) that applies a system-wide 10-band parametric EQ. It reads what apps send to the default output through a Core Audio process tap, processes it through an AUNBandEQ Audio Unit, and writes it back to the same output.

### Audio Signal Chain

```
apps -> CATapDescription(excludingProcesses: [this app], deviceUID: default output, stream: 0)
        private, mutedWhenTapped
     -> private aggregate device (main sub-device = that output, tap drift-compensated)
     -> IOProc: deinterleave -> AUNBandEQ (10 bands, +/-12 dB, 1 octave) -> volume, balance
     -> aggregate output stream 0 = the same device stream
```

Measured with `--engine-check` on the built-in speakers: flat EQ is exactly unity (0.00 dB), a 1 kHz band at +12 dB measures 12.00 dB, the tail after a tone ends reads digital silence (no feedback), and 256 frames per cycle adds 15.6 ms between capture and output.

### Key Files

- **AudioEngine.swift**: `@MainActor` state for the panel (`EngineState`), the device list, the permission, and the system events that trigger a rebuild (default output change, coreaudiod restart, wake, and a device list change while the last start failed). `EngineController` in the same file owns the pipeline on its own queue and coalesces requests through a locked mailbox. A failed start, and a stall (IO callbacks that stop for 4 s, or never start), go through one capped retry: 0.5, 1, 2, 4, 8 s, then nothing until the switch, the output or the device list changes. IO that is moving resets the count. A device listener rebuilds only the pipeline it was registered for
- **TapPipeline.swift**: The tap, the private aggregate, the IOProc and the EQ unit, plus `RenderContext`, the real-time render. Read its header comment before changing a design decision; each one is load-bearing
- **SystemAudioAccess.swift**: Permission status and request through the TCC lookup
- **CoreAudioDevices.swift**: AudioObject property helpers: `value(_:_:as:)` and `set` for fixed-size properties, strings, streams, the default output, and `PropertyListener`. CFString properties come back at +1 and are taken retained
- **EngineCheck.swift**: `--engine-check`
- **EQStore.swift**: `@MainActor ObservableObject` with all UI state (`bands`, `volume`, `balance`, `isEnabled`, `presets`). Persists to `state.json`/`presets.json` in Application Support. Auto-saves via Combine debounce (1s)
- **AppDelegate.swift**: Status bar item, the `MenuBarPanel` (340pt wide), Combine bindings from EQStore → AudioEngine. It owns no click or key monitors: the panel does
- **PopoverContentView.swift**: Main SwiftUI layout: header, output devices, volume, balance, EQ bands, presets, footer, and the pieces the sections share (`SectionTitle`, `CollapsibleHeader`, `ActiveDot`, `.brandSwitch()`, `.hoverDimmed()`, `.listRow`). No scroll view and no height cap: `.fixedSize(horizontal: false, vertical: true)` makes the panel exactly as tall as its content, so expanding a section grows the window. The old `.imperatorPopoverResize` notification, which guessed the extra height from preset and device counts, is gone
- **MenuBarPanel.swift**: The menu bar surface, drawn by the app instead of by `NSPopover`. See the section below before changing any number in it
- **StatusItemIcon.swift**: The app glyph, shared by the menu bar item (18pt) and the panel header (16pt)
- **Theme.swift**: `AppColors` enum with brand colors per Imperator brandbook
- **AboutPanel.swift**: Brandbook 10 About panel. `makePanel()` is split out of `show()` so the gate measures the real window. The SwiftUI view must carry a width but **no height**: an explicit height makes the content report its overflow and the window grows to match (292pt instead of 260pt)
- **AboutCheck.swift**: `--about-check`, the brandbook gate for that panel

### Critical Patterns

**Real-time audio thread safety**: The IOProc runs on the HAL's real-time thread. No allocation, no locks, no Objective-C in `RenderContext.render`. Counters and levels live in C memory (`RenderStats`) written with plain aligned stores and read without a lock; volume and balance likewise (`RenderParams`). When the EQ cannot run for a cycle, the tap is copied through unprocessed, never silence: the apps are muted while the tap is read.

**Own process excluded**: the tap excludes this app's process object, or it would capture its own output and feed back. `CoreAudioDevices.processObject(for:)` maps `kAudioObjectUnknown` to nil and the pipeline refuses to start without it.

**Private objects**: the tap and the aggregate are private, so other processes never see them and coreaudiod removes both when the app exits, even on `kill -9`, so a crash leaves nothing to clean up. The system default output is never changed by the engine. The output picker sets it the way macOS's own pickers do: the HAL does not move the alert device along, so `setDefaultOutputDevice` does when Sound settings play sound effects through the selected device (ByHost `com.apple.soundpref` `AlertsUseMainDevice`, unset meaning yes).

**Property listeners**: never `AudioObjectAddPropertyListenerBlock` for a listener that is removed again. Swift wraps the closure in a new block at every call and the HAL matches removals by block pointer, so the remove silently does nothing (measured: five add and remove rounds, five blocks firing). `PropertyListener` uses the function-pointer API, which matches on function and context.

**Idle sleep**: `CoreAudioDevices.allowIdleSleepDuringIO()` runs at setup. Without it coreaudiod holds `PreventUserIdleSystemSleep` for the aggregate the whole time the switch is on, silence included (`pmset -g assertions`), and a MacBook never idle-sleeps. It is per process: an app that plays keeps its own assertion.

**Settings reach the engine without a run loop hop**: `@Published` fires in willSet, so the EQ, volume and balance values come straight from `CombineLatest3` of the publishers. A `.receive(on: RunLoop.main)` hop does not run while a slider tracks the mouse, and the sound then changes only on mouse-up.

**Microphone permission, not verified**: tccd shows coreaudiod preflighting `kTCCServiceMicrophone` for this app even for the speakers-only aggregate. On this Mac a grant left from the loopback-driver version answers it. A fresh install, and an output with inputs of its own (USB headset, audio interface), have not been tried. The app declares no microphone usage string on purpose.

**Headset microphones stay closed**: the aggregate lists the output device's own input streams first and the tap stream last (measured). `kAudioDevicePropertyIOProcStreamUsage` switches every input stream but the tap off, so a headset's microphone should never open. Designed that way, not yet tried on a real headset.

**On/off**: the switch stops and starts the whole pipeline. Off means no tap, no mute, native audio, not an EQ in bypass.

**@MainActor isolation**: AudioEngine, EQStore, and AppDelegate are all `@MainActor`. `EngineController` is not an actor; everything it touches runs on its serial queue.

**Unmanaged reference bridging**: The IOProc and the EQ input callback receive the context via `Unmanaged<RenderContext>.passRetained()` / `.takeUnretainedValue()`. `TapPipeline.stop()` stops IO before it releases the context.

## Brandbook

Colors and UI must follow the Imperator Apps BrandBook (separate repo). Key rules:
- Color enum is `AppColors` (not `Theme`), brand color `#A01818`
- Never use bare `Color.accentColor`: always `AppColors.brand`
- Panel width: 340pt
- Dark mode forced: `NSApp.appearance = NSAppearance(named: .darkAqua)`
- `UserDefaults.standard.set(0, forKey: "AppleAccentColor")` at launch
- Toggle: `.switch` style, scale 0.55, tint `AppColors.brand`, `.labelsHidden()`, and **no** `.frame`. Brandbook 7.2: the switch is 54x24pt on macOS 27 and `scaleEffect(0.55)` gives 29.7x13.2, so a 36x20 frame is invisible padding that reads as a size guarantee it does not give
- **Cursor: the system default everywhere.** No `.cursor(...)`, no `NSCursor` push or pop, no pointing hand, on links included. Goran's rule, and it overrides anything the brandbook says about pointer cursors
- Text on the panel is `.primary` or `.secondary`. Brand red measures 1.73:1 on the panel background and a resting `HoverButton` (45% opacity) 3.35:1, both under the 4.5:1 caption text needs, so neither carries text that has to be read

## The menu bar panel

`MenuBarPanel` draws the menu bar surface itself. Do not put `NSPopover` back, and do not
round any of the numbers in that file: each one was measured against what macOS 27 draws.

- **`cornerRadius = 18.25`, which *draws* 17.50pt.** The target is Control Centre's Wi-Fi
  panel on macOS 27: captured with `screencapture -o -l` and fitted on its bottom corner it
  measures 35.0 device pixels, 17.50pt, rms 0.38, at 309 x 290 drawn points. The constant sits
  higher than the target because `NSVisualEffectView` blends its edge and draws about 0.75pt
  tighter than the radius it is given. Measured both ways on this app's own panel: at 17.5 it
  drew 16.75, at 18.25 it draws 17.50.
- **Circular, not `.continuous`.** The Wi-Fi panel fits a circle at n=2.2.
- **A window corner, not a popover one.** A plain titled window measures 17.25 by the same
  method. `NSPopover` draws 26.25pt from a binary stamped `sdk 27.0` and 9.5pt from one
  stamped `sdk 14.0`, and exposes no radius to set.
- **No arrow and no animation.** macOS 27 puts its own menu bar panels up and takes them down
  instantly, and Control Centre's Wi-Fi panel is a plain rounded rectangle with no arrow.
- **`isFloatingPanel` before `level`.** Setting `isFloatingPanel` resets the level to floating (3), under the Dock and the menu bar, so it goes first and `.popUpMenu` (101) after it.
- **`close()` is an override.** A `close(_ sender: Any? = nil)` is a second method, and every plain `close()` call reached NSWindow's instead, leaving both monitors installed: Escape was swallowed across the app. The monitors also ignore a panel that is hidden or has a sheet attached, and Escape from another window or a sheet passes through. The same file lives in the other Imperator menu bar apps (AirDrop, CRT Overlay, DefaultBrowser, Docks, FinderTerminal, FreeGames, MenuBarFolders, RetroPong, WidgetClock), and these fixes are ported to all of them; a change here belongs in every copy.
- **The panel owns the dismissal.** Its global click monitor skips clicks inside its own frame
  and inside the status item's window, because the first click into an inactive accessory app
  reaches a global monitor too and would otherwise close the panel out from under the click, or
  race the status item's toggle and reopen what it just closed. A local monitor takes Escape,
  and `canBecomeKey` is overridden because a borderless panel refuses key status by default.
- The surface is `NSVisualEffectView` with `.popover` material and `.behindWindow` blending.
  The SwiftUI content lays `AppColors.popoverBackground` over it.

To re-measure: build, install, open the panel, capture the real window with
`screencapture -x -o -l <window id>` and fit the corner profile against a circle. Do not
measure a render.

## Conventions

English only in code, comments, docs, commit messages and release notes, even when the
conversation is in Swedish. No em or en dashes anywhere. Never commit or push without Goran's
explicit word in that message.

## Dependencies

Zero external Swift packages. Uses only Apple frameworks: CoreAudio (process taps), AudioToolbox, AppKit, SwiftUI, Combine, ServiceManagement, os. The only non-public call is the TCC lookup in `SystemAudioAccess`.
