#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUTPUT="${1:-$ROOT/dist/photo-backup}"
OUTPUT_DIR="$(dirname "$OUTPUT")"
OUTPUT_NAME="$(basename "$OUTPUT")"
mkdir -p "$OUTPUT_DIR"
OUTPUT_DIR="$(cd "$OUTPUT_DIR" && pwd)"
OUTPUT="$OUTPUT_DIR/$OUTPUT_NAME"
if [[ -e "$OUTPUT" ]]; then
  echo "Refusing to overwrite existing binary: $OUTPUT" >&2
  exit 2
fi

SCRATCH="$ROOT/.build/package-binary"
swift build --package-path "$ROOT" --scratch-path "$SCRATCH" --configuration release --arch arm64 --product photo-backup
BUILD_BIN_DIR="$(swift build --package-path "$ROOT" --scratch-path "$SCRATCH" --configuration release --arch arm64 --show-bin-path)"
BUILT_BINARY="$BUILD_BIN_DIR/photo-backup"
[[ -x "$BUILT_BINARY" ]]
install -m 755 "$BUILT_BINARY" "$OUTPUT"

SIGNING_IDENTITY="${CODE_SIGN_IDENTITY:--}"
SIGNING_ARGS=(--force --sign "$SIGNING_IDENTITY" --identifier com.photosbackup.cli --timestamp=none)
if [[ -n "${PHOTOS_BACKUP_KEYCHAIN_PATH:-}" ]]; then
  SIGNING_ARGS+=(--keychain "$PHOTOS_BACKUP_KEYCHAIN_PATH")
fi
codesign "${SIGNING_ARGS[@]}" "$OUTPUT"
codesign --verify --strict --verbose=2 "$OUTPUT"
LOAD_COMMANDS="$(otool -l "$OUTPUT")"
if [[ "$LOAD_COMMANDS" != *'__info_plist'* ]]; then
  echo "The binary does not contain its embedded Photos permission metadata" >&2
  exit 1
fi
plutil -lint "$ROOT/Resources/Info.plist"
echo "Packaged and signature-checked: $OUTPUT"
