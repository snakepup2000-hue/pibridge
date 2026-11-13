#!/bin/sh
# Builds and installs PiBridge into /Applications.
set -e
cd "$(dirname "$0")"
./build_app.sh
rm -rf /Applications/PiBridge.app
cp -R build/PiBridge.app /Applications/PiBridge.app
codesign -v /Applications/PiBridge.app
echo "installed /Applications/PiBridge.app"
