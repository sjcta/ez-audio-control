#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
# Fake devices, synthetic PCM and offscreen UI only. No product App launch,
# system volume events, permission requests, output changes or real audio I/O.
./scripts/test.sh
./scripts/test-native.sh
./scripts/test-timing.sh
./scripts/test-process-tap.sh
./scripts/test-display-audio-recovery.sh
./scripts/test-bluetooth-audio.sh
./scripts/test-diagnostics.sh
./scripts/test-status-tracking.sh
./scripts/test-ui-offline.sh
./scripts/test-glyph.sh
./scripts/test-audio-output-icons.sh
version=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' Info.plist)
./scripts/test-localization.sh "dist/$version/Ez Audio Control.app"
print 'PASS offline suite. Hardware audio, permission prompts and sleep/wake are not tested.'
