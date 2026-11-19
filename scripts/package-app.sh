#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DESTINATION="${1:-$ROOT/dist}"
mkdir -p "$DESTINATION"
DESTINATION="$(cd "$DESTINATION" && pwd)"
APP="$DESTINATION/Photos Backup.app"
if [[ -e "$APP" ]]; then
  echo "Refusing to overwrite existing app bundle: $APP" >&2
  exit 2
fi

SCRATCH="$ROOT/.build/package"
swift build --package-path "$ROOT" --scratch-path "$SCRATCH" --configuration release --product photos-backup
BIN="$SCRATCH/release/photos-backup"
[[ -x "$BIN" ]]

mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/photos-backup"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
SIGNING_IDENTITY="${CODE_SIGN_IDENTITY:--}"
codesign --force --deep --sign "$SIGNING_IDENTITY" --timestamp=none "$APP"
codesign --verify --deep --strict "$APP"
plutil -lint "$APP/Contents/Info.plist"
echo "Packaged and signature-checked: $APP"
