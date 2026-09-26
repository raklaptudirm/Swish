#!/bin/sh
# Runs the unit tests (both packages) and the interactive pty tests.
set -e
cd "$(dirname "$0")/.."

# With only the Command Line Tools installed, swift-testing isn't on the
# default search paths.
flags=""
if [ "$(xcode-select -p)" = /Library/Developer/CommandLineTools ]; then
    fw=/Library/Developer/CommandLineTools/Library/Developer/Frameworks
    lib=/Library/Developer/CommandLineTools/Library/Developer/usr/lib
    flags="-Xswiftc -F$fw -Xlinker -F$fw -Xlinker -rpath -Xlinker $fw -Xlinker -rpath -Xlinker $lib"
fi

swift test $flags
(cd Packages/SwishKit && swift test $flags)
swift build
expect Tests/Interactive/job-control.exp
