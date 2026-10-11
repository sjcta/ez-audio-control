#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
mkdir -p .build/timing-tests .build/cache
cp Tests/timing-main.swift .build/timing-tests/main.swift
swiftc -swift-version 5 -module-cache-path .build/cache Sources/Localization.swift Sources/VolumePolicy.swift Sources/WriteFlow.swift Sources/AudioOutputs.swift Sources/NativeAudio.swift .build/timing-tests/main.swift -framework CoreAudio -framework AudioToolbox -o .build/timing-tests/tests
.build/timing-tests/tests
