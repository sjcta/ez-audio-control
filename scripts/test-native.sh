#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
mkdir -p .build/native-tests .build/cache
cp Tests/native-main.swift .build/native-tests/main.swift
swiftc -swift-version 5 -module-cache-path .build/cache Sources/AudioOutputs.swift Sources/WriteFlow.swift Sources/NativeAudio.swift Sources/Localization.swift Sources/Diagnostics.swift Sources/VolumeFeedback.swift .build/native-tests/main.swift -framework CoreAudio -framework AudioToolbox -framework AppKit -o .build/native-tests/tests
.build/native-tests/tests
