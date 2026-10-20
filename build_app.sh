#!/bin/bash
# Builds SpotifyNotifier, packs it into a launchable .app (ad-hoc signed)
# and restarts the app afterwards (see --no-restart).
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="SpotifyNotifier"
BUILD_DIR="build"
APP_BUNDLE="$BUILD_DIR/$APP_NAME.app"
APP_BINARY="$APP_BUNDLE/Contents/MacOS/$APP_NAME"

RESTART=1

usage() {
  cat <<'EOF'
Usage: ./build_app.sh [options]

Builds the app (release), creates the .app bundle, signs it ad-hoc and
restarts the app afterwards.

Options:
  --no-restart   Build only – do not stop or restart a running app
  -h, --help     Show this help
EOF
}

for arg in "$@"; do
  case "$arg" in
    --no-restart) RESTART=0 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $arg" >&2; usage >&2; exit 2 ;;
  esac
done

# Stops a possibly running instance and waits until it is really gone.
stop_running_app() {
  local pids
  pids="$(pgrep -f "$APP_BINARY" || true)"
  if [ -z "$pids" ]; then
    return 0
  fi

  echo "==> Stopping running instance ($pids)…"
  # shellcheck disable=SC2086
  kill $pids 2>/dev/null || true

  local i
  for i in $(seq 1 30); do
    if ! pgrep -f "$APP_BINARY" >/dev/null 2>&1; then
      return 0
    fi
    sleep 0.1
  done

  # Follow up in case the app did not shut down cleanly.
  pkill -9 -f "$APP_BINARY" 2>/dev/null || true
  sleep 0.3
}

# Right after a kill `open` sometimes fails (LaunchServices timing), so give it
# a few attempts.
start_app() {
  local attempt
  for attempt in 1 2 3; do
    if open "$APP_BUNDLE"; then
      return 0
    fi
    sleep 0.5
  done
  return 1
}

echo "==> Building (release)…"
swift build -c release

BIN_PATH="$(swift build -c release --show-bin-path)/$APP_NAME"

# Stop the running instance first, then reassemble the bundle – that way the
# freshly built version is guaranteed to be the one running (no "why did nothing
# change?" effect). Only if the build succeeded before.
if [ "$RESTART" -eq 1 ]; then
  stop_running_app
fi

echo "==> Creating app bundle…"
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources"
cp "$BIN_PATH" "$APP_BINARY"
cp "Resources/Info.plist" "$APP_BUNDLE/Contents/Info.plist"

echo "==> Copying app icon…"
if [ -f "Resources/AppIcon.icns" ]; then
  cp "Resources/AppIcon.icns" "$APP_BUNDLE/Contents/Resources/AppIcon.icns"
else
  echo "    Warning: Resources/AppIcon.icns is missing – bundle without an icon."
  echo "             Create it with: swift make_icon.swift"
fi

echo "==> Signing (ad-hoc)…"
codesign --force --deep --sign - "$APP_BUNDLE"

echo ""
echo "==> Done: $APP_BUNDLE"

if [ "$RESTART" -eq 1 ]; then
  echo "==> Starting app…"
  if start_app; then
    echo "    App is running. Note: after a rebuild macOS may show the"
    echo "    \"Spotify control\" dialog again – hitting OK once is enough."
  else
    echo "    The app could not be started automatically." >&2
    echo "    Start it manually with: open \"$APP_BUNDLE\"" >&2
    exit 1
  fi
else
  echo "    Start with: open \"$APP_BUNDLE\""
fi
