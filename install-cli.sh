#!/bin/bash
set -euo pipefail
umask 077

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SOURCE_APP="$SCRIPT_DIR/Photos Backup.app"
APPLICATIONS_DIR="$HOME/Applications"
APP_PATH="$APPLICATIONS_DIR/Photos Backup.app"
BIN_DIR="$HOME/.local/bin"
WRAPPER_PATH="$BIN_DIR/photo-backup"
PROFILE_DIR="${ZDOTDIR:-$HOME}"
PROFILE_PATH="$PROFILE_DIR/.zprofile"
STAGING_APP="$APPLICATIONS_DIR/.Photos Backup.installing.$$.app"
BACKUP_APP="$APPLICATIONS_DIR/.Photos Backup.previous.$$.app"
WRAPPER_TEMP="$BIN_DIR/photo-backup.tmp.$$"
REPLACEMENT_STARTED=0
INSTALL_COMPLETE=0

cleanup() {
  if [[ -e "$STAGING_APP" ]]; then rm -rf "$STAGING_APP"; fi
  if [[ -e "$WRAPPER_TEMP" ]]; then rm -f "$WRAPPER_TEMP"; fi
  if [[ "$INSTALL_COMPLETE" != 1 ]]; then
    if [[ -d "$BACKUP_APP" ]]; then
      if [[ -e "$APP_PATH" || -L "$APP_PATH" ]]; then rm -rf "$APP_PATH"; fi
      mv "$BACKUP_APP" "$APP_PATH"
    elif [[ "$REPLACEMENT_STARTED" == 1 && ( -e "$APP_PATH" || -L "$APP_PATH" ) ]]; then
      rm -rf "$APP_PATH"
    fi
  fi
  return 0
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

if [[ ! -d "$SOURCE_APP" ]]; then
  echo "Run this script from the extracted Photos Backup release folder." >&2
  exit 2
fi

if [[ -L "$WRAPPER_PATH" || ( -e "$WRAPPER_PATH" && ! -f "$WRAPPER_PATH" ) ]]; then
  echo "Refusing to replace a non-file at $WRAPPER_PATH" >&2
  exit 2
fi
if [[ -f "$WRAPPER_PATH" ]] && ! grep -Fq "# Photos Backup CLI wrapper" "$WRAPPER_PATH"; then
  echo "Refusing to replace an existing unrelated command at $WRAPPER_PATH" >&2
  exit 2
fi

mkdir -p "$APPLICATIONS_DIR" "$BIN_DIR" "$PROFILE_DIR"
if [[ -e "$STAGING_APP" || -L "$STAGING_APP" || -e "$BACKUP_APP" || -L "$BACKUP_APP" ]]; then
  echo "A previous Photos Backup install attempt left a staging path; inspect $APPLICATIONS_DIR before retrying." >&2
  exit 2
fi
ditto "$SOURCE_APP" "$STAGING_APP"
codesign --verify --deep --strict "$STAGING_APP"

if [[ -e "$APP_PATH" || -L "$APP_PATH" ]]; then
  if [[ ! -d "$APP_PATH" || -L "$APP_PATH" ]]; then
    echo "Refusing to replace a non-app at $APP_PATH" >&2
    rm -rf "$STAGING_APP"
    exit 2
  fi
  mv "$APP_PATH" "$BACKUP_APP"
fi

REPLACEMENT_STARTED=1
mv "$STAGING_APP" "$APP_PATH"

cat > "$WRAPPER_TEMP" <<'WRAPPER'
#!/bin/sh
# Photos Backup CLI wrapper
APP="$HOME/Applications/Photos Backup.app/Contents/MacOS/photos-backup"
if [ ! -x "$APP" ]; then
  echo "Photos Backup app is missing; rerun install-cli.sh from the release folder." >&2
  exit 127
fi
exec "$APP" "$@"
WRAPPER
chmod 700 "$WRAPPER_TEMP"
mv "$WRAPPER_TEMP" "$WRAPPER_PATH"

if [[ ! -f "$PROFILE_PATH" ]] || ! grep -Fq '# Photos Backup CLI PATH' "$PROFILE_PATH"; then
  cat >> "$PROFILE_PATH" <<'PROFILE'

# Photos Backup CLI PATH
case ":$PATH:" in
  *":$HOME/.local/bin:"*) ;;
  *) export PATH="$HOME/.local/bin:$PATH" ;;
esac
PROFILE
fi

INSTALL_COMPLETE=1
rm -rf "$BACKUP_APP"
echo "Installed the headless app at ~/Applications/Photos Backup.app."
echo "Open a new Terminal window, then run photo-backup config --storage-account NAME."
trap - EXIT INT TERM
