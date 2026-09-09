#!/bin/bash
set -euo pipefail
: "${RUNNER_TEMP:?}" "${GH_TOKEN:?}" "${GH_REPO:?}" "${RELEASE_TAG:?}" "${RELEASE_SHA:?}"
[[ "$RELEASE_TAG" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || exit 1
asset="lnpctl-${RELEASE_TAG#v}-macos-arm64.dmg"
python3 - <<'PY'
import hashlib, json, os
from pathlib import Path
p = Path('release-assets')
tag = os.environ['RELEASE_TAG']
name = f'lnpctl-{tag[1:]}-macos-arm64.dmg'
assert {f.name for f in p.iterdir()} == {name, 'SHA256SUMS', 'release.json'}
r = json.loads((p / 'release.json').read_text())
assert r['tag'] == tag and r['commit'] == os.environ['RELEASE_SHA']
assert r['notarization']['status'] == 'Accepted'
assert (p / 'SHA256SUMS').read_text() == hashlib.sha256((p / name).read_bytes()).hexdigest() + '  ' + name + '\n'
PY
# Resolve the tag again immediately before publication, including annotated tags.
remote_sha="$(gh api "repos/$GH_REPO/commits/$RELEASE_TAG" --jq .sha)"
[[ "$remote_sha" == "$RELEASE_SHA" ]] || exit 1
# Listing errors must fail rather than being mistaken for an absent release.
existing="$(gh api --paginate "repos/$GH_REPO/releases?per_page=100" --jq ".[] | select(.tag_name == \"$RELEASE_TAG\") | [.id, .draft, .target_commitish] | @tsv")"
if [[ -n "$existing" ]]; then
  IFS=$'\t' read -r _release_id draft target <<< "$existing"
  [[ "$draft" == true && "$target" == "$RELEASE_SHA" ]] || {
    echo 'Refusing to modify an existing published release or a draft for different source.' >&2
    exit 1
  }
else
  gh release create "$RELEASE_TAG" --verify-tag --target "$RELEASE_SHA" --draft \
    --title "lnpctl ${RELEASE_TAG#v}" \
    --notes "Signed and notarized Apple Silicon executable for macOS 15 or later. Download the DMG, copy lnpctl to a directory you own, and run it from Terminal. SHA256SUMS verifies the final stapled DMG; release.json records its source and notarization."
fi
# A failed upload leaves a draft. Reruns may replace only this validated draft's assets.
gh release upload "$RELEASE_TAG" "release-assets/$asset" release-assets/SHA256SUMS release-assets/release.json --clobber
gh release view "$RELEASE_TAG" --json assets > "$RUNNER_TEMP/remote-assets.json"
python3 - <<'PYASSETS'
import json, os
from pathlib import Path
assets = json.loads((Path(os.environ['RUNNER_TEMP']) / 'remote-assets.json').read_text())['assets']
expected = {f"lnpctl-{os.environ['RELEASE_TAG'][1:]}-macos-arm64.dmg", 'SHA256SUMS', 'release.json'}
assert len(assets) == 3 and {a['name'] for a in assets} == expected
for a in assets:
    assert a['size'] == (Path('release-assets') / a['name']).stat().st_size
PYASSETS
# Recheck the moving tag after the upload as well.
[[ "$(gh api "repos/$GH_REPO/commits/$RELEASE_TAG" --jq .sha)" == "$RELEASE_SHA" ]] || exit 1
gh release edit "$RELEASE_TAG" --draft=false
