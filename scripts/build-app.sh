#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
configuration="${1:-release}"
app_path="$PWD/dist/Шёпот.app"
ensure_app_closed() {
    if [[ -e "$app_path/Contents/MacOS/Shepot" ]] && /usr/sbin/lsof -t "$app_path/Contents/MacOS/Shepot" >/dev/null 2>&1; then
        print -u2 "Закройте Шёпот перед обновлением. Запущенную копию нельзя перезаписывать."
        exit 1
    fi
}
ensure_app_closed
swift build --configuration "$configuration"
binary_dir="$(swift build --configuration "$configuration" --show-bin-path)"
identity_output="$(security find-identity -v -p codesigning)"
identity_cache="$PWD/.build/shepot-signing-identity"
sign_identity="${SHEPOT_SIGN_IDENTITY:-}"
if [[ -z "$sign_identity" && -f "$identity_cache" ]]; then
    cached_identity="$(cat "$identity_cache")"
    if [[ "$identity_output" == *"$cached_identity"* && "$cached_identity" =~ '^[A-Fa-f0-9]{40}$' ]]; then
        sign_identity="$cached_identity"
    fi
fi
if [[ -z "$sign_identity" ]]; then
    sign_identity="$(print -r -- "$identity_output" | awk '/"Apple Development:|"Developer ID Application:/ && !found {print $2; found=1}')"
fi
if [[ -z "$sign_identity" || "$sign_identity" == "-" ]]; then
    print -u2 "Нужен сертификат Apple Development или Developer ID. Укажите SHEPOT_SIGN_IDENTITY. Временная ad-hoc подпись ломает разрешения после обновлений."
    exit 1
fi
staging_dir="$(mktemp -d "$PWD/.build/shepot-app.XXXXXX")"
trap 'rm -rf -- "$staging_dir"' EXIT
staged_app="$staging_dir/Шёпот.app"
mkdir -p "$staged_app/Contents/MacOS" "$staged_app/Contents/Resources"
cp "$binary_dir/Shepot" "$staged_app/Contents/MacOS/Shepot"
cp Resources/Info.plist "$staged_app/Contents/Info.plist"
if [[ ! -f .build/AppIcon.icns || scripts/make-icon.swift -nt .build/AppIcon.icns ]]; then
    xcrun swift scripts/make-icon.swift
    iconutil -c icns .build/AppIcon.iconset -o .build/AppIcon.icns
fi
cp .build/AppIcon.icns "$staged_app/Contents/Resources/AppIcon.icns"
codesign --force --sign "$sign_identity" --options runtime --entitlements Resources/Shepot.entitlements "$staged_app"
codesign --verify --deep --strict "$staged_app"
print -r -- "$sign_identity" > "$identity_cache"
ensure_app_closed
mkdir -p "$PWD/dist"
rm -rf -- "$app_path"
mv "$staged_app" "$app_path"
print "Готово: $app_path"
