#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
mkdir -p .build/status-tracking .build/cache
cp Tests/status-tracking-main.swift .build/status-tracking/main.swift
swiftc -module-cache-path .build/cache Sources/Localization.swift Sources/WriteFlow.swift Sources/Diagnostics.swift Sources/StatusItemExpansion.swift .build/status-tracking/main.swift -framework AppKit -o .build/status-tracking/tests
.build/status-tracking/tests "$@"
