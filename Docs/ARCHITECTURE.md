# Architecture

## Current output and control

`main.swift` coordinates one current output, the menu, native volume, software attenuation and volume events. `AudioOutputs.swift` reads live CoreAudio output devices. Only explicit menu selections request output changes.

Native writable volume is preferred. Otherwise the App attempts `ProcessTapVolume.swift` / `ProcessTapAudio.mm` software control. The retained DDC bridge uses private Apple interfaces and preserves its two upstream notices; it is not a promise of universal monitor support.

## Software audio lifecycle

The process tap excludes the App, mutes the captured original stream, and forwards compatible Float32 PCM through an in-process private aggregate. `AttenuationDSP.h` applies bounded 0–1 gain and short transitions. No physical microphone, on-disk recording, installed HAL, daemon or third-party audio engine is involved.

Initial gain uses readable system volume, then the same device's saved software gain, then 100%. It does not force a hardware volume value. An owner heartbeat, first valid frames, format/topology checks and explicit cleanup protect the lifecycle. A healthy session may be idle after receiving valid audio.

On output changes, old work is invalidated and old resources are released before binding the latest output. No control intent is replayed across devices. Recovery retains confirmed gain/mute for the same UID, merges wake notifications and uses bounded retry windows. Cleanup failures preserve quarantined resources and diagnostics rather than assuming success.

These protections reduce known failure modes; they do not guarantee a physical volume ceiling or eliminate every bypass. Long-duration and sleep/wake behavior still needs hardware observation.

## User interface and permissions

AppKit owns native menus and the status item. `CompactControls`, `VolumeHUD`, `AudioGlyph` and `StatusItemExpansion` implement the compact volume display. Newer system glass is guarded by runtime availability checks; the source still needs macOS 27 SDK to compile its latest properties.

`SystemVolumeEvents` handles volume commands subject to user-granted control permission. `ControlPermissionPresenter` explains that permission without granting or resetting it. Bluetooth lists already-paired audio devices and waits for an actual CoreAudio output before selection.

## Test boundaries

Fake CoreAudio and Bluetooth tables exercise failure, cancellation, cleanup and state changes without accessing real devices. DSP tests use synthetic samples. UI tests inspect offscreen components and translations. The GitHub workflow builds ad-hoc and runs this offline suite; it cannot validate system permission prompts, actual media keys, audio quality or physical sleep/wake.
