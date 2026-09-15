#!/bin/sh
# Run the unit tests.
#
# The tests need no permissions and cause no side effects: nothing is posted, no event tap is
# created, the screen is never locked and the user's real preferences are never touched.
# Note that `xcodebuild test` launches the app as the test host, so its menu bar icon may flash
# into view for a second or two. That is normal for host-based unit tests.
set -e
cd "$(dirname "$0")/.."
. Scripts/xcode-env.sh

xcodebuild -project EjectRemapper.xcodeproj -scheme EjectRemapper \
  -destination 'platform=macOS' -derivedDataPath "$DERIVED_DATA" test 2>&1 \
  | grep -E "Test (Case|Suite|case|suite)|error:|failed|passed|TEST (SUCCEEDED|FAILED)|Executed" \
  | tail -n 60
