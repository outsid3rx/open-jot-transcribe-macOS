#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# Local Debug bundle using Command Line Tools. Does not launch/install the app.
set -euo pipefail
cd "$(dirname "$0")/.."
jot_build="${JOT_CHECK_BUILD:-$PWD/build/clt}"
jot_cache="${JOT_CHECK_CACHE:-$PWD/build/clt-cache}"
jot_app="${JOT_APP_PATH:-$PWD/build/Jot.app}"
swift build --package-path JotCore --scratch-path "$jot_build" --cache-path "$jot_cache" --disable-sandbox
jot_bin=$(swift build --package-path JotCore --scratch-path "$jot_build" --show-bin-path)
mkdir -p "$jot_app/Contents/MacOS" "$jot_app/Contents/Resources"
jot_objects=()
while IFS= read -r object; do jot_objects+=("$object"); done < <(
  rg --files --hidden --no-ignore "$jot_bin/JotCore.build" "$jot_bin/GRDB.build" "$jot_bin/Sauce.build" -g '*.o'
)
jot_sources=()
while IFS= read -r source; do jot_sources+=("$source"); done < <(rg --files App/Sources -g '*.swift')
swiftc -parse-as-library -swift-version 5 -D DEBUG \
  -target "$(uname -m)-apple-macosx14.0" -sdk "$(xcrun --sdk macosx --show-sdk-path)" \
  -I "$jot_bin/Modules" -I "$jot_build/checkouts/GRDB.swift/Sources/GRDBSQLite" \
  "${jot_sources[@]}" "${jot_objects[@]}" -lsqlite3 -o "$jot_app/Contents/MacOS/Jot"
cp -R App/Resources/Fonts App/Resources/Sounds App/Resources/ru.lproj App/Resources/en.lproj App/Resources/Jot.icns "$jot_app/Contents/Resources/"
cp -R "$jot_bin/JotCore_JotCore.bundle" "$jot_app/Contents/Resources/"
python3 - "$jot_app" <<'PY'
import plistlib, re, sys
from pathlib import Path
app = Path(sys.argv[1])
project = Path('project.yml').read_text()
def setting(key):
    return re.search(r'^\s+' + key + r':\s*([^\n#]+)', project, re.M)[1].strip().strip('"')
with open('App/Info.plist', 'rb') as source:
    info = plistlib.load(source)
info.update(CFBundleDevelopmentRegion='ru', CFBundleExecutable='Jot', CFBundleName='Jot',
            CFBundleIdentifier=setting('PRODUCT_BUNDLE_IDENTIFIER'),
            CFBundleShortVersionString=setting('MARKETING_VERSION'),
            CFBundleVersion=setting('CURRENT_PROJECT_VERSION'))
info['NSMicrophoneUsageDescription'] = 'Jot records audio while you hold the dictation key. The Russian translation is in InfoPlist.strings.'
with open(app / 'Contents/Info.plist', 'wb') as output:
    plistlib.dump(info, output)
PY
codesign --force --sign "${JOT_SIGN_IDENTITY:--}" --entitlements App/Jot.entitlements "$jot_app"
codesign --verify --deep --strict "$jot_app"
printf 'Built and signed: %s\n' "$jot_app"
