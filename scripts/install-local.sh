#!/bin/zsh
set -euo pipefail

project_root="${0:A:h:h}"
derived_data="/tmp/captura-local-release"
app_source="$derived_data/Build/Products/Release/captura.app"
app_destination="/Applications/captura.app"
signing_identity="8E175F6AEED18DEF143E011A525591C2FFB70FCE"

cd "$project_root"

xcodebuild \
  -project ScreenRecorder.xcodeproj \
  -scheme ScreenRecorder \
  -configuration Release \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$derived_data" \
  CODE_SIGNING_ALLOWED=NO \
  build

codesign \
  --force \
  --deep \
  --options runtime \
  --timestamp=none \
  --sign "$signing_identity" \
  --entitlements ScreenRecorder/ScreenRecorder.entitlements \
  --identifier com.example.captura \
  "$app_source"

codesign --verify --deep --strict --verbose=2 "$app_source"
pkill -x captura 2>/dev/null || true
ditto "$app_source" "$app_destination"
codesign --verify --deep --strict --verbose=2 "$app_destination"

if [[ "${1:-}" == "--launch" ]]; then
  open -n "$app_destination"
fi
