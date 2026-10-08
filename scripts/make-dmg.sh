#!/bin/bash
# Copyright 2026 Google LLC
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     https://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

# Packages an existing Jot.app with an Applications shortcut for drag installation.
# No Xcode, Apple Developer account or Finder automation is required.
#   scripts/make-dmg.sh <path-to-Jot.app> [output.dmg]
# Packaging preserves the app's signature; it does not notarize the app or DMG.
set -euo pipefail
cd "$(dirname "$0")/.."

jot_app="${1:?usage: make-dmg.sh <Jot.app> [output.dmg]}"
[ -d "$jot_app" ] || { echo "error: app not found: $jot_app" >&2; exit 1; }
codesign --verify --deep --strict "$jot_app"
jot_version=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$jot_app/Contents/Info.plist")
jot_arch=$(lipo -archs "$jot_app/Contents/MacOS/Jot")
if [[ "$jot_arch" == *" "* ]]; then jot_arch="universal"; fi
jot_out="${2:-build/Jot-$jot_version-macOS-$jot_arch.dmg}"
mkdir -p "$(dirname "$jot_out")"
jot_staging=$(mktemp -d "${TMPDIR:-/tmp}/jot-dmg.XXXXXX")
trap 'rm -rf "$jot_staging"' EXIT

ditto "$jot_app" "$jot_staging/Jot.app"
ln -s /Applications "$jot_staging/Applications"
hdiutil create -srcfolder "$jot_staging" -volname "Jot $jot_version" -fs HFS+ \
  -format UDZO -imagekey zlib-level=9 -ov "$jot_out"
hdiutil verify "$jot_out"
printf 'Created: %s\n' "$jot_out"
