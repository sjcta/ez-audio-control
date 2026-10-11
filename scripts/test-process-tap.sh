#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
mkdir -p .build/process-tap .build/cache
clang++ -std=c++17 -Wall -Wextra -Werror -fsanitize=address,undefined -g Tests/attenuation-dsp.cpp -o .build/process-tap/dsp-tests
.build/process-tap/dsp-tests
clang++ -std=c++17 -fobjc-arc -fblocks -Wall -Wextra -Werror -fsanitize=address,undefined -g Tests/process-tap.mm -framework Foundation -framework CoreAudio -o .build/process-tap/tap-tests
.build/process-tap/tap-tests
cp Tests/process-tap-main.swift .build/process-tap/main.swift
clang++ -std=c++17 -fobjc-arc -fblocks -O2 -c Sources/ProcessTapAudio.mm -o .build/process-tap/ProcessTapAudio.o
swiftc -swift-version 5 -module-cache-path .build/cache -import-objc-header Sources/ProcessTapAudio.h Sources/Localization.swift Sources/WriteFlow.swift Sources/ProcessTapVolume.swift .build/process-tap/main.swift .build/process-tap/ProcessTapAudio.o -framework Foundation -framework CoreAudio -lc++ -o .build/process-tap/controller-tests
.build/process-tap/controller-tests
