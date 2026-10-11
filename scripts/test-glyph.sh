#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
mkdir -p .build/glyph-tests .build/cache
cp Tests/glyph-geometry-main.swift .build/glyph-tests/main.swift
swiftc -module-cache-path .build/cache Sources/Localization.swift Sources/AudioGlyph.swift .build/glyph-tests/main.swift -framework AppKit -o .build/glyph-tests/tests
.build/glyph-tests/tests
