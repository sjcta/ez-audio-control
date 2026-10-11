#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
mkdir -p .build/SAC.iconset
source="Assets/SAC-icon-source.png"
for size in 16 32 128 256 512; do
    doubled=$((size * 2))
    /usr/bin/sips -s format png --resampleHeightWidth "$size" "$size" "$source" --out ".build/SAC.iconset/icon_${size}x${size}.png" >/dev/null
    /usr/bin/sips -s format png --resampleHeightWidth "$doubled" "$doubled" "$source" --out ".build/SAC.iconset/icon_${size}x${size}@2x.png" >/dev/null
done
/usr/bin/iconutil -c icns .build/SAC.iconset -o Assets/AppIcon.icns
printf 'Built AppIcon.icns\n'
