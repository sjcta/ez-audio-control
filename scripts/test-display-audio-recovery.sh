#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
mkdir -p .build/display-audio-recovery .build/cache
cp Tests/display-audio-recovery-main.swift .build/display-audio-recovery/main.swift
swiftc -swift-version 5 -module-cache-path .build/cache Sources/DisplayAudioRecovery.swift .build/display-audio-recovery/main.swift -o .build/display-audio-recovery/policy-tests
.build/display-audio-recovery/policy-tests
