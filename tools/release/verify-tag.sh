#!/bin/bash
set -euo pipefail
: "${1:?Release tag required}" "${2:?Approved public key file required}"
[[ "$1" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || exit 1
[[ "$(git cat-file -t "refs/tags/$1")" == tag ]] || exit 1
# An isolated keyring prevents the runner's other keys from authorizing a release.
GNUPGHOME="$(mktemp -d)"
export GNUPGHOME
trap 'rm -rf "$GNUPGHOME"' EXIT
chmod 700 "$GNUPGHOME"
gpg --batch --import "$2"
git -c gpg.format=openpgp -c gpg.program=gpg verify-tag --raw "refs/tags/$1"
