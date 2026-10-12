#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
configuration="release"
swift build -c "$configuration"
binary_dir="$(swift build -c "$configuration" --show-bin-path)"
app_path="$PWD/dist/StatsWarning.app"
mkdir -p "$app_path/Contents/MacOS" "$app_path/Contents/Resources"
cp "$binary_dir/StatsWarning" "$app_path/Contents/MacOS/StatsWarning"
cp Resources/Info.plist "$app_path/Contents/Info.plist"
cp THIRD_PARTY_NOTICES.md "$app_path/Contents/Resources/THIRD_PARTY_NOTICES.md"
if [ ! -f Resources/AppIcon.icns ]; then
    swift scripts/generate-icon.swift
fi
cp Resources/AppIcon.icns "$app_path/Contents/Resources/AppIcon.icns"
settings_path="$app_path/Contents/Helpers/StatsWarningSettings.app"
mkdir -p "$settings_path/Contents/MacOS" "$settings_path/Contents/Resources"
cp "$binary_dir/StatsWarningSettings" "$settings_path/Contents/MacOS/StatsWarningSettings"
cp Resources/Settings-Info.plist "$settings_path/Contents/Info.plist"
cp Resources/AppIcon.icns "$settings_path/Contents/Resources/AppIcon.icns"
codesign --force --sign "${SIGNING_IDENTITY:--}" "$settings_path"
codesign --force --sign "${SIGNING_IDENTITY:--}" "$app_path"
printf 'Built %s\n' "$app_path"
