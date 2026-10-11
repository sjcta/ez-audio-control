#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
mkdir -p .build/bluetooth-tests/cache
cp Tests/bluetooth-audio-main.swift .build/bluetooth-tests/main.swift
swiftc -swift-version 5 -module-cache-path .build/bluetooth-tests/cache \
    Sources/Localization.swift Sources/AudioOutputs.swift Sources/BluetoothAudioPolicy.swift \
    Sources/BluetoothAudioOutputs.swift .build/bluetooth-tests/main.swift \
    -framework AppKit -framework CoreAudio -framework CoreBluetooth -framework IOBluetooth \
    -o .build/bluetooth-tests/tests
.build/bluetooth-tests/tests
