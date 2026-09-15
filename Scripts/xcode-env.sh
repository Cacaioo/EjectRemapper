#!/bin/sh
# Sourced by build.sh and test.sh.
#
# Two environment problems are handled here.
#
# 1. Xcode may not be the selected developer directory. On the machine this project was written on,
#    `xcode-select` pointed at the Command Line Tools and Xcode lived on a secondary volume.
#
# 2. Derived data must not live on a volume that stamps `com.apple.FinderInfo` onto the built
#    bundle. Some volumes (notably file-provider-managed and non-boot APFS volumes) do exactly that,
#    and `codesign` then refuses the bundle with:
#        "resource fork, Finder information, or similar detritus not allowed"
#    Building into a directory on the boot volume avoids it entirely. Override with
#    EJECT_REMAPPER_DERIVED_DATA if you want the products somewhere specific.

if ! xcodebuild -version >/dev/null 2>&1; then
  for candidate in "/Applications/Xcode.app" "/Volumes/Macintosh_SSD/Applications/Xcode.app"; do
    if [ -d "$candidate/Contents/Developer" ]; then
      export DEVELOPER_DIR="$candidate/Contents/Developer"
      break
    fi
  done
fi

if ! xcodebuild -version >/dev/null 2>&1; then
  echo "error: Xcode not found. Install Xcode, or set DEVELOPER_DIR to its Contents/Developer." >&2
  exit 1
fi

if [ -n "$EJECT_REMAPPER_DERIVED_DATA" ]; then
  DERIVED_DATA="$EJECT_REMAPPER_DERIVED_DATA"
else
  DERIVED_DATA="${TMPDIR:-/tmp}EjectRemapper-DerivedData"
fi
export DERIVED_DATA
mkdir -p "$DERIVED_DATA"
