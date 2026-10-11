#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
mode="${1:-}"
if [[ "$#" != 1 || ( "$mode" != "--adhoc" && "$mode" != "--unsigned" ) ]]; then
    print -u2 'Usage: ./scripts/build.sh --adhoc | --unsigned'
    print -u2 'Local development only; no install, launch, notarization or upload.'
    exit 2
fi
sdk=$(xcrun --sdk macosx --show-sdk-version)
if (( ${sdk%%.*} < 27 )); then
    print -u2 'This source requires macOS 27 SDK. Select a compatible installed Apple toolchain.'
    exit 2
fi
version=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' Info.plist)
app="dist/$version/Ez Audio Control.app"
[[ -f Assets/AppIcon.icns ]] || { print -u2 'Missing checked-in AppIcon.icns'; exit 2; }
mkdir -p .build/cache .build/objects "$app/Contents/MacOS" "$app/Contents/Resources/Licenses"
clang -target arm64-apple-macos14.0 -fobjc-arc -Wall -Wextra -Werror -O2 -I Sources -c Sources/DDCBridge.m -o .build/objects/DDCBridge.o
clang++ -std=c++17 -target arm64-apple-macos14.0 -fobjc-arc -fblocks -Wall -Wextra -Werror -O2 -c Sources/ProcessTapAudio.mm -o .build/objects/ProcessTapAudio.o
swiftc -swift-version 5 -target arm64-apple-macos14.0 -O -whole-module-optimization -module-cache-path .build/cache -import-objc-header Sources/DDCBridge.h Sources/Localization.swift Sources/Sponsorship.swift Sources/VolumePolicy.swift Sources/WriteFlow.swift Sources/Diagnostics.swift Sources/SystemVolumeEvents.swift Sources/AudioGlyph.swift Sources/VolumeHUD.swift Sources/CompactControls.swift Sources/AudioOutputs.swift Sources/BluetoothAudioOutputs.swift Sources/BluetoothAudioPolicy.swift Sources/AudioOutputIcon.swift Sources/NativeAudio.swift Sources/ProcessTapVolume.swift Sources/DisplayAudioRecovery.swift Sources/VolumeFeedback.swift Sources/StatusItemExpansion.swift Sources/DisplayMode.swift Sources/About.swift Sources/AboutPresenter.swift Sources/ControlPermissionPresenter.swift Sources/main.swift .build/objects/DDCBridge.o .build/objects/ProcessTapAudio.o -framework AppKit -framework ApplicationServices -framework IOKit -framework CoreGraphics -framework CoreDisplay -framework CoreAudio -framework CoreBluetooth -framework IOBluetooth -framework AudioToolbox -framework ServiceManagement -lc++ -o "$app/Contents/MacOS/SimpleAudioControl"
cp Info.plist "$app/Contents/Info.plist"
cp -R Resources/*.lproj "$app/Contents/Resources/"
cp Resources/ProcessTap.entitlements.plist "$app/Contents/Resources/"
cp Licenses/*.txt "$app/Contents/Resources/Licenses/"
cp LICENSE THIRD_PARTY.md "$app/Contents/Resources/"
cp Assets/AppIcon.icns "$app/Contents/Resources/AppIcon.icns"
if [[ "$mode" == "--adhoc" ]]; then
    codesign --force --sign - --identifier local.SimpleAudioControl --options runtime --entitlements Resources/ProcessTap.entitlements.plist "$app"
    codesign --verify --strict "$app"
else
    rm -rf "$app/Contents/_CodeSignature"
    print 'Unsigned build: not a launch or distribution artifact.'
fi
printf 'Built local development App: %s/%s\n' "$PWD" "$app"
