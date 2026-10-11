#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
mkdir -p .build/audio-output-icon-tests .build/cache
cp Tests/audio-output-icon-main.swift .build/audio-output-icon-tests/main.swift
swiftc -swift-version 5 -module-cache-path .build/cache Sources/Localization.swift Sources/AudioOutputs.swift \
    Sources/AudioOutputIcon.swift .build/audio-output-icon-tests/main.swift \
    -framework AppKit -framework CoreAudio -o .build/audio-output-icon-tests/tests
.build/audio-output-icon-tests/tests .build/audio-output-icon-tests/fixtures "$@"
