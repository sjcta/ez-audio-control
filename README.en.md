<img src="Assets/SAC-icon-source.png" width="96" alt="Ez Audio Control icon">

# Ez Audio Control

**Can't adjust your Mac's volume with the volume keys after connecting an external monitor?**

Ez Audio Control is a **free, open-source macOS menu bar tool focused on volume control**. Adjust your current output with familiar volume keys, mouse actions mapped to system volume commands and a menu bar slider. For compatible outputs without writable system volume, it automatically attempts software attenuation, **without installing an extra driver**.

[简体中文](README.md) · [MIT license](LICENSE) · [Privacy](PRIVACY.md) · [Contributing](CONTRIBUTING.md)

> **This is 0.1.44 development-preview source. There is no official download package or notarized release.** To try it, read the [runtime requirements](#runtime-requirements) and [build instructions](#build-from-source) first. Local builds are development artifacts.

## Features

- **Automatic volume control selection:** use native volume when system volume is writable; otherwise attempt software attenuation, subject to macOS permissions and a compatible output format.
- **Familiar controls:** volume up, down and mute keys, plus mouse actions already mapped to system volume commands. Ordinary scrolling or horizontal scrolling is not automatically treated as volume control.
- **Quick access from the menu bar:** left-click for the slider, volume value, mute and output devices. Volume commands show a top HUD, with a waiting state while control is not ready.

Also included:

- Paired Bluetooth audio devices, including disconnected ones; connect and select a device only after you click it.
- Two display modes: **HUD** keeps only the menu bar icon; **Full** also shows volume numbers. Both retain the top HUD. English and Simplified Chinese follow system language.
- Optional volume feedback and launch at login. Feedback in software mode follows confirmed software gain.
- A separate **Sound Settings…** entry at the bottom of the menu opens macOS Sound Settings.

Software volume is attenuation only: 100% preserves the incoming audio, 0% is silence. It does not change the monitor or external speaker's physical volume.

## Why I built this

After connecting my Mac mini to a monitor, audio played normally, but I could no longer adjust the macOS system volume. I just wanted to keep using familiar volume controls, so I built this free, open-source tool and aimed to keep it lightweight.

Free alternatives already exist; Ez Audio Control offers another choice focused on volume control. See [community discussions and common approaches (Chinese)](Docs/BACKGROUND.md).

## Runtime requirements

| Item | Requirement |
| --- | --- |
| Architecture | Apple Silicon; no Intel App build |
| System | macOS 14+ deployment target; software volume needs macOS 14.2+ and a compatible output format |
| Dependencies | Apple system frameworks only |

Compatibility checks are limited to development hardware, fake-device tests and component checks. Support for every macOS version, monitor or audio device is not guaranteed.

**Long-running, monitor-wake and sleep/wake recovery are still under observation.** Cleanup or recovery can briefly interrupt audio; unattenuated audio may return on exit or failure. Software attenuation is not a physical volume ceiling or hearing protection. Pause playback and lower external speaker volume before first use.

## Usage and permissions

1. Open the App and left-click its menu bar icon for volume/output selection. Right-click for display mode, feedback and login settings.
2. Volume keys and mapped mouse volume commands require a user-granted control permission: Device Control and Data Access on newer systems, Accessibility on older systems. The App links to the relevant page and takes over automatically after authorization.
3. Outputs without writable system volume automatically trigger an attempt at software mode. You decide the first macOS system-audio-capture prompt. No physical microphone is opened and no audio is saved.
4. Bluetooth permission is requested through an explicit Bluetooth action. The App does not scan, pair or connect devices automatically.

Run one copy of the App and avoid multiple volume tools handling the same command. Review support information copied from About before sharing it.

## Build from source

Build requirements differ from runtime requirements: the current source needs an **Apple toolchain with the macOS 27 SDK**, plus `xcrun`, `swiftc`, `clang` / `clang++` and `codesign`.

After downloading or cloning the source, run the existing [build script](scripts/build.sh) and [offline test entry point](scripts/test-offline.sh) from the repository root:

```sh
./scripts/build.sh --adhoc
./scripts/test-offline.sh
```

Output: `dist/0.1.44/Ez Audio Control.app`. Building and offline tests do not launch the App, install a driver, write device volume or request audio capture. Ad-hoc signing is for local development, without a distribution identity or Apple notarization. Use `--unsigned` to compile only.

Open the App yourself after building. Keep one installation path and a consistent signing identity where possible; changed development signatures may require permission updates. Do not modify TCC or disable system security to work around permissions.

## Development and feedback

See [architecture](Docs/ARCHITECTURE.md), [contributing](CONTRIBUTING.md), [releasing](Docs/RELEASING.md) and [security reporting](SECURITY.md). Include the version, OS, connection type and reproduction steps in bug reports; exclude full system logs, serial numbers and recordings.

The source retains DDC display discovery, the read-only `--diagnose` command and historical control code. The current default volume path uses native CoreAudio volume or software attenuation; it does not fall back to DDC hardware writes when system volume is not writable. The DDC bridge uses private IOAVService/CoreDisplay APIs, which may change with macOS. Mac App Store distribution is not promised.

## License and attribution

Original project code and documentation are [MIT-licensed](LICENSE), credited to **Ez Studio (Jeson)**. DDC adaptations retain the complete m1ddc and MonitorControl notices; see [THIRD_PARTY.md](THIRD_PARTY.md). The App icon is an AI-assisted project asset. macOS symbols and feedback audio are not redistributed.
