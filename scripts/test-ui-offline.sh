#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
mkdir -p .build/visual-tests .build/cache
cp Tests/visual-main.swift .build/visual-tests/main.swift
swiftc -module-cache-path .build/cache Sources/Localization.swift Sources/WriteFlow.swift Sources/VolumePolicy.swift Sources/AudioGlyph.swift Sources/VolumeHUD.swift Sources/CompactControls.swift Sources/DisplayMode.swift .build/visual-tests/main.swift -framework AppKit -o .build/visual-tests/tests
.build/visual-tests/tests
