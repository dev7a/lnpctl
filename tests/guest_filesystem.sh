#!/bin/bash
# Run as root in an owned disposable VM with a dedicated mounted APFS test image.
# Arguments: executable, entry token, mounted test volume, optional source fixture.
set -euo pipefail

lnp_binary=$1
lnp_token=$2
lnp_volume=$3
lnp_fixture=${4:-/Library/Preferences/com.apple.networkextension.plist}
lnp_store="$lnp_volume/Library/Preferences/com.apple.networkextension.plist"
lnp_backups="$lnp_volume/Backups"
lnp_plan="$lnp_backups/cleanup"
lnp_launcher="$lnp_backups/lnpctl-recovery"

echo 'Executable under test:'
shasum -a 256 "$lnp_binary"
"$lnp_binary" --version

if [[ $(id -u) != 0 || "$lnp_volume" != /Volumes/LNPCTL-Test ]]; then
    echo 'This test requires root and the dedicated /Volumes/LNPCTL-Test image.' >&2
    exit 1
fi
if [[ -e "$lnp_store" || -e "$lnp_backups" ]]; then
    echo 'Test destination already contains data; use a fresh image.' >&2
    exit 1
fi
mkdir -p "$lnp_volume/Library/Preferences"
cp "$lnp_fixture" "$lnp_store"
chmod 640 "$lnp_store"
xattr -w org.example.lnpctl preserved "$lnp_store"
chmod +a 'user:admin allow read,readattr,readextattr,readsecurity' "$lnp_store"

checksum() { shasum -a 256 "$1" | awk '{print $1}'; }
# ls -e is the macOS ACL display; this is one fixed, task-owned filename.
# shellcheck disable=SC2012
metadata() { stat -f '%u:%g:%p' "$lnp_store"; ls -le "$lnp_store" | tail -n +2; xattr -px org.example.lnpctl "$lnp_store"; }
lnp_original_hash=$(checksum "$lnp_store")
lnp_original_meta=$(metadata)

expect_failure() {
    local expected=$1
    shift
    local before after
    before=$(checksum "$lnp_store")
    if "$@" > "$lnp_volume/failure.txt" 2>&1; then
        echo "Expected refusal: $expected" >&2
        exit 1
    fi
    if ! /usr/bin/grep -Fq "$expected" "$lnp_volume/failure.txt"; then
        cat "$lnp_volume/failure.txt" >&2
        exit 1
    fi
    after=$(checksum "$lnp_store")
    [[ "$before" == "$after" ]]
    echo "PASS refusal: $expected"
}

"$lnp_binary" prepare --volume "$lnp_volume" --entry "$lnp_token" --backup "$lnp_plan"
echo 'Staged executable:'
shasum -a 256 "$lnp_plan/lnpctl"
"$lnp_plan/lnpctl" inspect "$lnp_plan"
[[ $(checksum "$lnp_store") == "$lnp_original_hash" ]]
echo 'PASS prepare does not write the live store'
/bin/bash "$(dirname "$0")/guest_trust.sh" "$lnp_binary" "$lnp_token" "$lnp_plan"
[[ $(checksum "$lnp_launcher") == "$(checksum "$lnp_binary")" ]]
[[ $(stat -f '%u:%g:%OLp' "$lnp_launcher") == 0:0:700 ]]
[[ $(xattr -p com.dev7a.lnpctl.recovery "$lnp_launcher") == 1 ]]
"$lnp_binary" setup-recovery --volume "$lnp_volume" --backups "$lnp_backups"
[[ $(checksum "$lnp_launcher") == "$(checksum "$lnp_binary")" ]]
expect_failure 'requires an interactive terminal' "$lnp_launcher" </dev/null
echo 'PASS stable launcher, repeat setup and noninteractive refusal'

# Migrate the old namespace even when the executable bytes already match.
xattr -d com.dev7a.lnpctl.recovery "$lnp_launcher"
xattr -w dev.alessandrobologna.lnpctl.recovery 1 "$lnp_launcher"
"$lnp_binary" setup-recovery --volume "$lnp_volume" --backups "$lnp_backups"
[[ $(xattr -p com.dev7a.lnpctl.recovery "$lnp_launcher") == 1 ]]
[[ $(xattr "$lnp_launcher") == com.dev7a.lnpctl.recovery ]]
[[ $(checksum "$lnp_launcher") == "$(checksum "$lnp_binary")" ]]
[[ $(checksum "$lnp_plan/lnpctl") == "$(checksum "$lnp_binary")" ]]

# Legacy recognition must not permit extra metadata on a foreign file.
xattr -d com.dev7a.lnpctl.recovery "$lnp_launcher"
xattr -w dev.alessandrobologna.lnpctl.recovery 1 "$lnp_launcher"
xattr -w org.example.unexpected marker "$lnp_launcher"
expect_failure 'unexpected file' "$lnp_binary" setup-recovery --volume "$lnp_volume" --backups "$lnp_backups"
[[ $(xattr -p org.example.unexpected "$lnp_launcher") == marker ]]
xattr -d org.example.unexpected "$lnp_launcher"
"$lnp_binary" setup-recovery --volume "$lnp_volume" --backups "$lnp_backups"
[[ $(xattr "$lnp_launcher") == com.dev7a.lnpctl.recovery ]]
echo 'PASS legacy launcher marker migration preserves backups and rejects extra metadata'

# Updating the marked launcher must not replace the binary inside any backup.
printf 'previous launcher' > "$lnp_launcher"
"$lnp_binary" setup-recovery --volume "$lnp_volume" --backups "$lnp_backups"
[[ $(checksum "$lnp_launcher") == "$(checksum "$lnp_binary")" ]]
[[ $(checksum "$lnp_plan/lnpctl") == "$(checksum "$lnp_binary")" ]]
mv "$lnp_launcher" "$lnp_volume/launcher.saved"
printf 'unrelated file' > "$lnp_launcher"
chmod 700 "$lnp_launcher"
expect_failure 'unexpected file' "$lnp_binary" setup-recovery --volume "$lnp_volume" --backups "$lnp_backups"
[[ $(cat "$lnp_launcher") == 'unrelated file' ]]
rm "$lnp_launcher"
ln -s "$lnp_plan/lnpctl" "$lnp_launcher"
expect_failure 'Symbolic links are not accepted' "$lnp_binary" setup-recovery --volume "$lnp_volume" --backups "$lnp_backups"
rm "$lnp_launcher"
mv "$lnp_volume/launcher.saved" "$lnp_launcher"
echo 'PASS launcher update preserves backups and refuses file or symlink collisions'

lnp_menu_tests="$(dirname "$0")/guest_recovery.exp"
/usr/bin/expect "$lnp_menu_tests" "$lnp_launcher" "$lnp_backups" cancel
lnp_menu_base="$lnp_volume/Menu"
mkdir -m 700 "$lnp_menu_base"
cp -R "$lnp_plan" "$lnp_menu_base/cleanup"
/usr/bin/expect "$lnp_menu_tests" "$lnp_binary" "$lnp_menu_base" cancel
/usr/bin/expect "$lnp_menu_tests" "$lnp_binary" "$lnp_menu_base" apply_cancel
[[ $(checksum "$lnp_store") == "$lnp_original_hash" ]]
/usr/bin/expect "$lnp_menu_tests" "$lnp_binary" "$lnp_menu_base" apply
[[ $(checksum "$lnp_store") == "$(checksum "$lnp_plan/edited.plist")" ]]
/usr/bin/expect "$lnp_menu_tests" "$lnp_binary" "$lnp_menu_base" restore
[[ $(checksum "$lnp_store") == "$lnp_original_hash" ]]

mkdir -m 700 "$lnp_volume/Snapshot"
lnp_menu_snapshots=("$lnp_menu_base"/restore-safety-*)
cp -R "${lnp_menu_snapshots[0]}" "$lnp_volume/Snapshot/snapshot"
/usr/bin/expect "$lnp_menu_tests" "$lnp_binary" "$lnp_volume/Snapshot" snapshot
mkdir -m 700 "$lnp_volume/Foreign"
cp -R "$lnp_plan" "$lnp_volume/Foreign/cleanup"
plutil -replace volume_uuid -string 00000000-0000-0000-0000-000000000001 "$lnp_volume/Foreign/cleanup/manifest.plist"
expect_failure 'No valid backups for this volume' "$lnp_binary" setup-recovery --volume "$lnp_volume" --backups "$lnp_volume/Foreign"
/usr/bin/expect "$lnp_menu_tests" "$lnp_binary" "$lnp_volume/Foreign" foreign
[[ $(checksum "$lnp_store") == "$lnp_original_hash" ]]
[[ $(metadata) == "$lnp_original_meta" ]]
echo 'PASS Recovery menu review, dispatch, restore and foreign-volume refusal'

expect_failure 'Wrong volume' "$lnp_plan/lnpctl" apply "$lnp_plan" --volume / --yes
"$lnp_plan/lnpctl" apply "$lnp_plan" --volume "$lnp_volume" --yes
[[ $(checksum "$lnp_store") == "$(checksum "$lnp_plan/edited.plist")" ]]
[[ $(metadata) == "$lnp_original_meta" ]]
echo 'PASS apply preserves owner, mode, xattr and ACL'
"$lnp_plan/lnpctl" apply "$lnp_plan" --volume "$lnp_volume" --yes

"$lnp_plan/lnpctl" restore "$lnp_plan" --volume "$lnp_volume" --yes
[[ $(checksum "$lnp_store") == "$lnp_original_hash" ]]
[[ $(metadata) == "$lnp_original_meta" ]]
echo 'PASS restore preserves original bytes and metadata'

lnp_snapshots=("$lnp_backups"/restore-safety-*)
[[ ${#lnp_snapshots[@]} == 1 ]]
lnp_snapshot=${lnp_snapshots[0]}
"$lnp_snapshot/lnpctl" inspect "$lnp_snapshot"
"$lnp_snapshot/lnpctl" restore "$lnp_snapshot" --volume "$lnp_volume" --yes
[[ $(checksum "$lnp_store") == "$(checksum "$lnp_plan/edited.plist")" ]]
"$lnp_plan/lnpctl" restore "$lnp_plan" --volume "$lnp_volume" --yes
echo 'PASS restore-safety backup can itself restore the previous state'

# A damaged current store must not prevent restoration of a valid backup.
# Retain its exact bytes and metadata, but do not allow it as a restore input.
for lnp_damage in truncated newer-schema; do
    if [[ "$lnp_damage" == truncated ]]; then
        printf 'bplist00truncated' > "$lnp_store"
    else
        printf '<?xml version="1.0"?><plist version="1.0"><dict><key>FutureSchema</key><integer>999</integer></dict></plist>' > "$lnp_store"
    fi
    lnp_damaged_hash=$(checksum "$lnp_store")
    lnp_damaged_meta=$(metadata)
    "$lnp_plan/lnpctl" restore "$lnp_plan" --volume "$lnp_volume" --yes
    [[ $(checksum "$lnp_store") == "$lnp_original_hash" ]]
    [[ $(metadata) == "$lnp_original_meta" ]]
    lnp_found_snapshot=''
    for lnp_candidate in "$lnp_backups"/restore-safety-*; do
        if [[ $(checksum "$lnp_candidate/original.plist") == "$lnp_damaged_hash" ]]; then
            lnp_found_snapshot=$lnp_candidate
        fi
    done
    [[ -n "$lnp_found_snapshot" ]]
    [[ $(plutil -extract source_sha256 raw "$lnp_found_snapshot/manifest.plist") == "$lnp_damaged_hash" ]]
    # Source metadata survives the damage and restoration in this fixture.
    [[ "$lnp_damaged_meta" == "$lnp_original_meta" ]]
    if "$lnp_plan/lnpctl" restore "$lnp_found_snapshot" --volume "$lnp_volume" --yes; then
        echo 'An unreadable safety snapshot must not be accepted as a restore input.' >&2
        exit 1
    fi
    [[ $(checksum "$lnp_store") == "$lnp_original_hash" ]]
    [[ $(metadata) == "$lnp_original_meta" ]]
done
echo 'PASS restores over unreadable current stores while retaining safety bytes and strict restore inputs'

cp -R "$lnp_plan" "$lnp_backups/bad-checksum"
printf '\ncorrupt' >> "$lnp_backups/bad-checksum/edited.plist"
expect_failure 'Edited backup checksum mismatch' "$lnp_plan/lnpctl" apply "$lnp_backups/bad-checksum" --volume "$lnp_volume" --yes

cp -R "$lnp_plan" "$lnp_backups/bad-edit"
# $top is the literal keyed-archive key, not a shell variable.
# shellcheck disable=SC2016
plutil -replace '$top.Generation' -integer 999 "$lnp_backups/bad-edit/edited.plist"
lnp_bad_hash=$(checksum "$lnp_backups/bad-edit/edited.plist")
plutil -replace edited_sha256 -string "$lnp_bad_hash" "$lnp_backups/bad-edit/manifest.plist"
expect_failure 'changes more than the selected rule references' "$lnp_plan/lnpctl" apply "$lnp_backups/bad-edit" --volume "$lnp_volume" --yes

cp -R "$lnp_plan" "$lnp_backups/wrong-executable"
printf different > "$lnp_backups/wrong-executable/lnpctl"
lnp_bad_hash=$(checksum "$lnp_backups/wrong-executable/lnpctl")
plutil -replace executable_sha256 -string "$lnp_bad_hash" "$lnp_backups/wrong-executable/manifest.plist"
expect_failure 'executable differs' "$lnp_plan/lnpctl" apply "$lnp_backups/wrong-executable" --volume "$lnp_volume" --yes

chmod 600 "$lnp_store"
expect_failure 'store changed since preparation' "$lnp_plan/lnpctl" apply "$lnp_plan" --volume "$lnp_volume" --yes
chmod 640 "$lnp_store"

cp -R "$lnp_plan" "$lnp_backups/bad-format"
plutil -replace format -integer 999 "$lnp_backups/bad-format/manifest.plist"
expect_failure 'Unsupported or incomplete backup manifest' "$lnp_plan/lnpctl" apply "$lnp_backups/bad-format" --volume "$lnp_volume" --yes

"$lnp_plan/lnpctl" backups "$lnp_backups" --json > "$lnp_volume/backup-list.json"
[[ $(checksum "$lnp_store") == "$lnp_original_hash" ]]
[[ $(metadata) == "$lnp_original_meta" ]]
echo 'PASS all refusal cases leave original content and metadata intact'
echo 'FILESYSTEM INTEGRATION PASSED'
