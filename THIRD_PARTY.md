# Third-party notices

Ez Audio Control links Apple system frameworks and has no third-party runtime package dependencies. It does not bundle or launch m1ddc, MonitorControl or BetterDisplay.

## DDC adaptations

The IOAVService declarations, DDC packet construction/checksum, read/retry delays and framebuffer matching in `Sources/DDCBridge.m` and its header adapt the following pinned sources:

| Project | Revision | License and attribution |
| --- | --- | --- |
| [m1ddc](https://github.com/waydabber/m1ddc) | `04d949794102eb8df01ad3681afff6464a3eede2` | MIT, Copyright (c) 2021 waydabber; full text: [Licenses/m1ddc.txt](Licenses/m1ddc.txt) |
| [MonitorControl](https://github.com/MonitorControl/MonitorControl) | `84ac2d72bfb53b653536e484946f6ed027e4229c` | MIT, Copyright © 2017; source credits MonitorControl, @JoniVR, @theOneyouseek, @waydabber and others; full text: [Licenses/MonitorControl.txt](Licenses/MonitorControl.txt) |

Both license files retain their upstream text. No MediaKeyTap, Sparkle, Settings, SimplyCoreAudio or KeyboardShortcuts dependency is bundled.

## Current software-volume implementation

`ProcessTapAudio.mm`, `AttenuationDSP.h` and `ProcessTapVolume.swift` implement in-process attenuation using Apple CoreAudio process taps and a private aggregate audio device. Here “private aggregate” is a CoreAudio device visibility setting, not an installed HAL driver. The current build does not include the earlier Proxy Audio Device/HAL experiment or its forwarding client, and does not install a driver or persistent helper.

## System resources and artwork

- AppKit, CoreAudio, CoreBluetooth, IOBluetooth and other linked frameworks are supplied by macOS.
- DDC uses private IOAVService/CoreDisplay interfaces. Their availability and App Store acceptance are not guaranteed.
- SF Symbols are requested from macOS. The feedback sound is referenced in place at the system BezelServices path; no Apple sound file is copied into the source tree or App bundle. That internal path is not a stable public sound API.
- The App icon is an AI-assisted project asset; see [Assets/README.md](Assets/README.md).

Original project code and documentation use the root [MIT license](LICENSE). That grant does not replace upstream notices or grant ownership of Apple's system resources. Local builds are not notarized distribution releases; signature and notarization status must be checked for each binary separately.
