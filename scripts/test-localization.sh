#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
mkdir -p .build/localization-tests .build/cache
cp Tests/localization-main.swift .build/localization-tests/main.swift
swiftc -swift-version 5 -module-cache-path .build/cache Sources/Localization.swift Sources/Sponsorship.swift Sources/About.swift .build/localization-tests/main.swift -framework AppKit -o .build/localization-tests/tests
version=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' Info.plist)
.build/localization-tests/tests "${1:-dist/$version/Ez Audio Control.app}"

# Run actual bundle localization selection without changing persistent preferences.
app=".build/localization-tests/LanguageSmoke.app"
mkdir -p "$app/Contents/MacOS"
cp Info.plist "$app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set CFBundleExecutable LanguageSmoke' "$app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set CFBundleIdentifier local.SimpleAudioControl.tests.LanguageSmoke' "$app/Contents/Info.plist"
mkdir -p "$app/Contents/Resources"
cp -R Resources/*.lproj "$app/Contents/Resources/"
cp Tests/language-smoke-main.swift .build/localization-tests/main.swift
swiftc -swift-version 5 -module-cache-path .build/cache Sources/Localization.swift Sources/Sponsorship.swift Sources/About.swift Sources/DisplayMode.swift Sources/CompactControls.swift Sources/AudioGlyph.swift .build/localization-tests/main.swift -framework AppKit -o "$app/Contents/MacOS/LanguageSmoke"
codesign --force --sign - --identifier local.SimpleAudioControl.tests.LanguageSmoke "$app"
codesign --verify --strict "$app"
"$app/Contents/MacOS/LanguageSmoke" --english -AppleLanguages '(en)'
"$app/Contents/MacOS/LanguageSmoke" -AppleLanguages '(zh-Hans)'
"$app/Contents/MacOS/LanguageSmoke" --english -AppleLanguages '(fr)'
