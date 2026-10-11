#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
mkdir -p .build/diagnostic-tests .build/cache
cp Tests/diagnostics-main.swift .build/diagnostic-tests/main.swift
swiftc -module-cache-path .build/cache Sources/WriteFlow.swift Sources/Localization.swift Sources/Diagnostics.swift .build/diagnostic-tests/main.swift -o .build/diagnostic-tests/test
.build/diagnostic-tests/test
