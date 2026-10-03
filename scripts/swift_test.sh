#!/usr/bin/env bash
#
# Run the FermixMessagesCore suite (swift-testing).
#
# A full Xcode toolchain ships XCTest and swift-testing on SwiftPM's search paths, so
# plain `swift test` works there. Command Line Tools ship no XCTest at all, and their
# Testing.framework and lib_TestingInterop.dylib sit in two directories SwiftPM does not
# search (and SIP strips DYLD_FRAMEWORK_PATH from swiftpm-testing-helper), so on a
# CLT-only machine the framework search path and both rpaths are baked in at link time.
# The selected developer directory decides which of the two configurations runs.
#
# Usage: scripts/swift_test.sh [additional swift test arguments]
set -euo pipefail

cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

DEVELOPER_DIR_SELECTED="$(xcode-select -p)"

if [ -d "$DEVELOPER_DIR_SELECTED/Platforms/MacOSX.platform" ]; then
  exec swift test "$@"
fi

CLT_FRAMEWORKS="$DEVELOPER_DIR_SELECTED/Library/Developer/Frameworks"
CLT_LIBRARIES="$DEVELOPER_DIR_SELECTED/Library/Developer/usr/lib"
# The @Test/#expect macro implementations. The default build system finds them on a
# clean build and loses them on an incremental one, so the path is always passed.
CLT_TESTING_PLUGINS="$DEVELOPER_DIR_SELECTED/usr/lib/swift/host/plugins/testing"

if [ ! -d "$CLT_FRAMEWORKS/Testing.framework" ]; then
  echo "swift_test: $DEVELOPER_DIR_SELECTED is neither an Xcode toolchain nor" >&2
  echo "swift_test: Command Line Tools that ship Testing.framework" >&2
  exit 1
fi

exec swift test \
  -Xswiftc -plugin-path -Xswiftc "$CLT_TESTING_PLUGINS" \
  -Xswiftc -F -Xswiftc "$CLT_FRAMEWORKS" \
  -Xlinker -F -Xlinker "$CLT_FRAMEWORKS" \
  -Xlinker -rpath -Xlinker "$CLT_FRAMEWORKS" \
  -Xlinker -rpath -Xlinker "$CLT_LIBRARIES" \
  "$@"
