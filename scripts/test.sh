#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
mkdir -p .build/cache .build/tests
clang -fobjc-arc -Wall -Wextra -Werror -I Sources Sources/DDCBridge.m Tests/packet.m -framework Foundation -framework IOKit -framework CoreGraphics -framework CoreDisplay -o .build/tests/packet
.build/tests/packet
# Swift allows executable top-level code in a main.swift file.
cp Tests/policy-main.swift .build/tests/main.swift
swiftc -swift-version 5 -module-cache-path .build/cache Sources/Localization.swift Sources/VolumePolicy.swift Sources/WriteFlow.swift .build/tests/main.swift -o .build/tests/policy
.build/tests/policy
clang -fobjc-arc -Wall -Wextra -Werror -I Sources Sources/DDCBridge.m Tests/probe.m -framework Foundation -framework IOKit -framework CoreGraphics -framework CoreDisplay -o .build/tests/ddc-probe
printf 'Read-only hardware probe: %s/.build/tests/ddc-probe\n' "$PWD"
