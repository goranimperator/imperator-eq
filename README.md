<p align="center"><img src="Resources/AppIcon.png" width="128" alt="Imperator EQ"></p>

# Imperator EQ

A system-wide 10-band parametric equaliser for macOS, living in the menu bar.

macOS has no built-in EQ for system output. Imperator EQ adds one: it takes the sound apps send
to your current output, runs it through an equaliser, and plays the result on that same output.
It needs no driver and no per-app setup.

Requires macOS 14.2 or later, Apple silicon or Intel. Built and tested on macOS 27 only; older
versions are expected to work but have not been verified.

Install at your own risk. The app is not notarized and carries no Apple Developer signature,
so macOS cannot vouch for it. It is provided as is, with no warranty, under the MIT license.

## What it does

- 10 EQ bands from 32 Hz to 16 kHz, plus or minus 12 dB each
- Volume boost up to 200% and left/right balance
- Named presets you can save, rename, reorder and delete
- Picks the Mac's sound output from the panel, the same setting as the Sound menu, with
  sound effects moving along when Sound settings play them through the selected device
- Runs in the menu bar with no Dock icon, and can open at login

## Install

Download the zip from the [releases page](https://github.com/goranimperator/imperator-eq/releases),
unzip it, and drag `Imperator EQ.app` into `/Applications`. The app is signed with a
self-signed certificate rather than notarized, so the first launch needs a right-click and
**Open** to get past Gatekeeper.

The app installs nothing else and never asks for an administrator password.

## Permissions

**System audio recording.** To process what your Mac plays, the app has to read it first,
and macOS asks before it lets any app do that. The prompt appears the first time the switch
in the panel is on. The app records nothing and keeps no audio: the sound goes through the
equaliser and straight back out. It does not open the microphone. On an output that has one
of its own, like a headset, the app switches that microphone stream off before it starts;
that case has not been tried on a real headset yet.

While the switch is on, macOS shows its recording indicator for Imperator EQ in the menu bar
and lists the app in Control Center, because reading what the Mac plays counts as recording
system audio. Nothing is saved anywhere. Turn the switch off and the indicator goes away.

Until you allow it, the panel says it is waiting, and your sound plays as normal. If you
turned it down, the panel has a button to the right place: **System Settings > Privacy &
Security > Screen & System Audio Recording**, in the **System Audio Recording Only** list.
The app notices the change within a couple of seconds, with no restart.

Only that last list matters to this app. It does not need the screen recording permission in
the list above it.

macOS offers apps no public way to read this permission's state, so the app asks the
system's privacy service (TCC) directly. If a future macOS removes that, the app falls back
to starting the EQ and letting macOS show its own prompt.

## Use

Click the waveform icon in the menu bar to open the panel. The switch in the header turns processing on and
off. Drag the band sliders to shape the sound, or pick a preset; the sound changes while you
drag. **Reset** returns every band to flat. The output list sets the Mac's sound output, the
same setting as the Sound menu, and the EQ follows it. **Open at Login** starts the app with
the Mac.

## The menu bar panel

The panel is drawn by the app, not by `NSPopover`. macOS 27 draws its own menu bar panels as
plain rounded rectangles with no arrow and no open or close animation, and `NSPopover` draws
neither that shape nor that corner and offers no way to set one. The measurements behind the
corner radius, and the reason the constant is not the number it draws, are written down in
`Sources/ImperatorEQ/MenuBarPanel.swift`.

## How it works

The app uses a Core Audio process tap, the API macOS 14.2 added for reading other apps'
audio. The tap sits on the current output device and takes everything apps send to it,
except the app's own sound. The app reads the tap through a private aggregate device whose
only other member is that same output, runs each block through Apple's `AUNBandEQ` Audio
Unit, applies volume and balance, and writes the result back to the output.

```
apps -> tap on the default output (apps muted while the tap is read)
     -> private aggregate device
     -> IOProc: AUNBandEQ (10 bands), volume, balance
     -> the same output device
```

A few properties follow from that design:

- The system output never changes. Volume keys and the Sound menu work on the real device,
  as they do without the app.
- Apps are muted only while the app reads the tap. Quit it, turn the switch off, or have it
  crash, and the apps play directly again at once. The tap and the aggregate device are
  private to the app, and macOS removes both when the app exits, so nothing is left behind.
- The tap covers only the output device the app plays to. An app that sends its sound to a
  different device keeps playing there, untouched.
- When the default output changes, for example when headphones connect, the app rebuilds
  the tap on the new device. If the new device refuses at first, as one that is still
  connecting can, the app tries again after 0.5, 1, 2, 4 and 8 seconds, and once more
  whenever a device is added or removed. Until then the sound plays as normal.
- The Mac can still go to sleep with the switch on. The app tells macOS that its own audio
  should not keep the Mac awake; an app that is playing keeps it awake, as it always does.
- The app adds about 16 ms between an app and the speaker: 256 frames per cycle, measured on
  the built-in speakers at 44.1 kHz as output time minus capture time.

The setup work waits on the system's audio service, so it all runs on the engine's own
queue. The menu bar item stays responsive while it runs.

## Build

```bash
bash build.sh
```

That runs a universal release build, assembles `Imperator EQ.app`, signs it, and copies it to
`/Applications`. Signing is not optional: Gatekeeper blocks an unsigned bundle.

`swift build` on its own produces the binary without the app bundle, which is enough for
checking that the code compiles but not for running the app.

Two things the build does that are easy to miss:

- It stamps the binary with the current SDK through `-Xlinker -platform_version` while keeping
  the deployment target at macOS 14.2. AppKit picks which generation of controls to draw from
  that stamp, so without it the app would keep drawing older controls on current systems even
  though it still has to run on macOS 14.2.
- It signs with the stable `Imperator Dev` certificate rather than ad-hoc. An ad-hoc signature's
  designated requirement is the code hash, which changes on every build, so macOS would treat
  each update as a different app and drop the system audio recording permission. Override
  with `IMPERATOR_SIGN_IDENTITY` if you are building on a machine without that certificate.

Two self-checks are built into the app. The first measures the About panel against the
brandbook instead of trusting its own constants:

```bash
"/Applications/Imperator EQ.app/Contents/MacOS/ImperatorEQ" --about-check
```

The second runs the real audio path without the menu bar item and writes what it measured to
a JSON file: start and stop cycles, EQ gain, timing, and the tap's settings. It records levels
and counters, never audio. It has to be launched through `open`, so macOS applies the app's
own permission, and the app must not be running at the same time, or two taps would play the
sound twice:

```bash
open -n -a "Imperator EQ" --args --engine-check --report /tmp/engine-check.json
```

It waits for sound to arrive before it measures, so play something while it runs.

There are no tests and no linter.

## Release

Commit everything first. Then set `CFBundleShortVersionString` in `Resources/Info.plist` to the
new version and `CFBundleVersion` to the commit count plus one (`git rev-list --count HEAD`,
plus the release commit that is about to exist), build, zip, commit, tag and publish:

```bash
bash build.sh
mkdir -p dist
ditto -c -k --sequesterRsrc --keepParent "Imperator EQ.app" "dist/Imperator-EQ-x.y.z.zip"
git commit -am "Release vx.y.z"
git tag -a vx.y.z -m "Imperator EQ x.y.z"
git push origin HEAD vx.y.z
gh release create vx.y.z --title "Imperator EQ x.y.z" "dist/Imperator-EQ-x.y.z.zip#Imperator EQ x.y.z (macOS)"
```

Check the zip people download rather than the bundle in the repo: unzip it and run
`codesign --verify --strict` on the app inside.

## Layout

| Path | What lives there |
| --- | --- |
| `Sources/ImperatorEQ/main.swift` | Entry point and the two self-checks |
| `Sources/ImperatorEQ/AppDelegate.swift` | Status item, panel, bindings |
| `Sources/ImperatorEQ/MenuBarPanel.swift` | The menu bar surface, drawn by the app rather than by `NSPopover` |
| `Sources/ImperatorEQ/StatusItemIcon.swift` | The app glyph, shared by the menu bar item and the panel header |
| `Sources/ImperatorEQ/AudioEngine.swift` | Engine state for the panel, permission, device and wake events, and the queue that owns the pipeline |
| `Sources/ImperatorEQ/TapPipeline.swift` | The process tap, private aggregate device, IOProc and `AUNBandEQ` |
| `Sources/ImperatorEQ/SystemAudioAccess.swift` | Reads and requests the system audio recording permission |
| `Sources/ImperatorEQ/CoreAudioDevices.swift` | Property helpers for devices, streams and the default output, and a property listener that can be removed |
| `Sources/ImperatorEQ/EngineCheck.swift` | The `--engine-check` self-check |
| `Sources/ImperatorEQ/EQStore.swift` | UI state and persistence to Application Support |
| `Sources/ImperatorEQ/PopoverContentView.swift` | Panel layout, footer, launch-at-login toggle, and the pieces the sections share |
| `Sources/ImperatorEQ/EQBandsView.swift` | The band sliders |
| `Sources/ImperatorEQ/EQSlider.swift` | The slider control |
| `Sources/ImperatorEQ/OutputDeviceView.swift` | Output device picker |
| `Sources/ImperatorEQ/PresetManagerView.swift` | Preset list and editing |
| `Sources/ImperatorEQ/AboutPanel.swift` | About panel |
| `Sources/ImperatorEQ/AboutCheck.swift` | Brandbook gate for the About panel |
| `Sources/ImperatorEQ/Theme.swift` | `AppColors`, the Imperator palette |

## Known limits

The EQ runs on the first two channels. On an output with more, the rest pass through at the
same volume without EQ.

Some outputs cannot join an aggregate device, for example another aggregate device. On those
the EQ does not run, the panel says so, and the sound plays as normal.

Headsets, Bluetooth outputs, sleep and wake have not been tested yet.

While the switch is on, the output device keeps running even when nothing plays. That costs
some battery: coreaudiod used about 4% of one core in a measurement with the app idle.

The app is not notarized, so every machine needs the right-click **Open** on first launch.

## Third-party

None. The app uses Apple frameworks only.

## License

MIT. See [LICENSE](LICENSE).
