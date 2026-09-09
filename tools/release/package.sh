#!/bin/bash
# Called only after the workflow validates the release tag and source commit.
set -euo pipefail
: "${RELEASE_TAG:?}" "${RELEASE_SHA:?}" "${SIGNING_IDENTITY:?}" "${APPLE_TEAM_ID:?}"
: "${NOTARY_KEY_PATH:?}" "${APPLE_API_KEY_ID:?}" "${APPLE_API_ISSUER_ID:?}"
[[ "$RELEASE_TAG" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || exit 1
[[ "$(git rev-parse HEAD)" == "$RELEASE_SHA" ]] || exit 1
[[ "$(uname -m)" == arm64 ]] || exit 1
version="${RELEASE_TAG#v}"
[[ "$(sed -n 's/^#define LNP_VERSION "\([^"]*\)"$/\1/p' src/LNPVersion.h)" == "$version" ]] || exit 1
make test
[[ "$(build/lnpctl --version)" == "lnpctl $version" ]] || exit 1
[[ "$(lipo -archs build/lnpctl)" == arm64 ]] || exit 1
mkdir -p build/release/root build/release/assets
cp build/lnpctl build/release/root/lnpctl
for license in LICENSE LICENSE.md LICENSE.txt; do
  if [[ -f "$license" ]]; then
    cp "$license" build/release/root/
  fi
done
cat > build/release/root/READ-ME.txt <<'TXT'
lnpctl for Apple Silicon, macOS 15 or later

Copy lnpctl to a directory you own and run it from Terminal.
Example: mkdir -p ~/.local/bin && cp /Volumes/lnpctl/lnpctl ~/.local/bin/
Then run: ~/.local/bin/lnpctl --help

Documentation: https://dev7a.github.io/lnpctl/guide/
Source: https://github.com/dev7a/lnpctl
TXT
codesign --force --sign "$SIGNING_IDENTITY" --options runtime --timestamp \
  --identifier com.dev7a.lnpctl build/release/root/lnpctl
codesign --verify --strict --verbose=2 build/release/root/lnpctl
codesign -d --verbose=4 build/release/root/lnpctl 2> build/release/signature.txt
grep -Fx "TeamIdentifier=$APPLE_TEAM_ID" build/release/signature.txt
grep -F 'Authority=Developer ID Application:' build/release/signature.txt
asset="lnpctl-${version}-macos-arm64.dmg"
hdiutil create -volname lnpctl -srcfolder build/release/root -format UDZO "build/release/assets/$asset"
codesign --force --sign "$SIGNING_IDENTITY" --timestamp "build/release/assets/$asset"
codesign --verify --strict --verbose=2 "build/release/assets/$asset"
xcrun notarytool submit "build/release/assets/$asset" --key "$NOTARY_KEY_PATH" \
  --key-id "$APPLE_API_KEY_ID" --issuer "$APPLE_API_ISSUER_ID" \
  --wait --timeout 30m --output-format json > build/release/notary-result.json
python3 - <<'PY'
import json
from pathlib import Path
result = json.loads(Path('build/release/notary-result.json').read_text())
if result.get('status') != 'Accepted':
    raise SystemExit(f"Notarization did not succeed: {result.get('status')}")
PY
xcrun stapler staple "build/release/assets/$asset"
xcrun stapler validate "build/release/assets/$asset"
spctl --assess --type open --context context:primary-signature --verbose=2 "build/release/assets/$asset"
# Hash only the final, stapled bytes.
(cd build/release/assets && shasum -a 256 "$asset" > SHA256SUMS)
python3 - <<'PY'
import json, os, subprocess
from pathlib import Path
receipt = {
    'tag': os.environ['RELEASE_TAG'], 'commit': os.environ['RELEASE_SHA'],
    'architecture': 'arm64', 'minimum_macos': '15.0',
    'team_id': os.environ['APPLE_TEAM_ID'],
    'notarization': json.loads(Path('build/release/notary-result.json').read_text()),
    'xcode': subprocess.check_output(['xcodebuild', '-version'], text=True).strip(),
}
Path('build/release/assets/release.json').write_text(json.dumps(receipt, indent=2) + '\n')
PY
