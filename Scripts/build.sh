#!/bin/sh
# Build the app.
#
# Usage: Scripts/build.sh [Debug|Release] [universal]
#   Debug (default)     the active architecture only
#   Release             optimised; hardened runtime is applied
#   universal           Intel + Apple silicon (Release only makes sense here)
set -e
cd "$(dirname "$0")/.."
. Scripts/xcode-env.sh

CONFIG="${1:-Debug}"
DEST='platform=macOS'
if [ "${2:-}" = "universal" ]; then DEST='generic/platform=macOS'; fi

xcodebuild -project EjectRemapper.xcodeproj -scheme EjectRemapper \
  -configuration "$CONFIG" -destination "$DEST" \
  -derivedDataPath "$DERIVED_DATA" build | tail -n 15

APP="$DERIVED_DATA/Build/Products/$CONFIG/EjectRemapper.app"
echo
echo "App: $APP"
