#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"

app_path="${1:-$PWD/dist/Шёпот.app}"
codesign --verify --deep --strict "$app_path"
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app_path/Contents/Info.plist")"
arch="$(lipo -archs "$app_path/Contents/MacOS/Shepot")"
if [[ "$arch" == *arm64* && "$arch" == *x86_64* ]]; then
    arch=universal
fi
if [[ "$arch" != arm64 && "$arch" != x86_64 && "$arch" != universal ]]; then
    print -u2 "Неподдерживаемая архитектура: $arch"
    exit 1
fi

mkdir -p .build dist
work="$(mktemp -d "$PWD/.build/shepot-dmg.XXXXXX")"
trap 'rm -rf -- "$work"' EXIT
mkdir "$work/contents"
ditto "$app_path" "$work/contents/Шёпот.app"
ln -s /Applications "$work/contents/Applications"
output="$PWD/dist/Shepot-$version-$arch.dmg"
hdiutil create -srcfolder "$work/contents" -volname "Шёпот $version" \
    -fs HFS+ -format UDZO -imagekey zlib-level=9 "$work/installer.dmg"
hdiutil verify "$work/installer.dmg"
mv "$work/installer.dmg" "$output"
print "Готово: $output"
