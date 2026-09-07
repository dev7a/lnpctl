#!/bin/bash
# Root-only regression tests on the owned disposable /Volumes/LNPCTL-Test image.
# Arguments: executable, entry token, existing valid cleanup backup.
set -euo pipefail
lnp_binary=$1
lnp_token=$2
lnp_plan=$3
lnp_volume=/Volumes/LNPCTL-Test
lnp_trust="$lnp_volume/Trust"
lnp_store="$lnp_volume/Library/Preferences/com.apple.networkextension.plist"
if [[ $(id -u) != 0 || "$lnp_plan" != "$lnp_volume/Backups/cleanup" || -e "$lnp_trust" ]]; then
    echo 'Requires root, the dedicated test plan, and a fresh Trust directory.' >&2
    exit 1
fi
lnp_before=$(shasum -a 256 "$lnp_store")
mkdir -m 755 "$lnp_trust"
refuse() {
    local expected=$1
    shift
    if "$@" > "$lnp_trust/refusal.txt" 2>&1; then
        echo "Unexpected acceptance: $expected" >&2
        exit 1
    fi
    /usr/bin/grep -F "$expected" "$lnp_trust/refusal.txt"
    [[ $(shasum -a 256 "$lnp_store") == "$lnp_before" ]]
}

refuse 'reserved for the Recovery launcher' "$lnp_binary" prepare --volume "$lnp_volume" --entry "$lnp_token" --backup "$lnp_trust/reserved/lnpctl-recovery"
[[ ! -e "$lnp_trust/reserved" ]]
echo 'PASS reserved launcher name rejected before creation'

# A private root-owned leaf must not hide an owner-controlled ancestor.
mkdir -m 755 "$lnp_trust/user"
chown admin "$lnp_trust/user"
mkdir -m 700 "$lnp_trust/user/private"
cp -R "$lnp_plan" "$lnp_trust/user/private/existing"
refuse 'root-owned directories throughout' "$lnp_binary" prepare --volume "$lnp_volume" --entry "$lnp_token" --backup "$lnp_trust/user/private/new"
[[ ! -e "$lnp_trust/user/private/new" ]]
refuse 'root-owned directories throughout' "$lnp_binary" inspect "$lnp_trust/user/private/existing"
refuse 'root-owned directories throughout' "$lnp_binary" setup-recovery --volume "$lnp_volume" --backups "$lnp_trust/user/private"
refuse 'root-owned directories throughout' "$lnp_binary" recovery "$lnp_trust/user/private" </dev/null
# Demonstrate the original substitution mechanism without executing a payload.
sudo -u admin mv "$lnp_trust/user/private" "$lnp_trust/user/moved"
sudo -u admin mkdir "$lnp_trust/user/private"
echo 'PASS owner-controlled ancestor rejected; unprivileged substitution demonstrated'

mkdir -m 777 "$lnp_trust/writable"
mkdir -m 700 "$lnp_trust/writable/private"
refuse 'writable ancestor' "$lnp_binary" prepare --volume "$lnp_volume" --entry "$lnp_token" --backup "$lnp_trust/writable/private/new"
[[ ! -e "$lnp_trust/writable/private/new" ]]
refuse 'without the sticky bit' "$lnp_binary" prepare --volume "$lnp_volume" --entry "$lnp_token" --backup "$lnp_trust/writable/missing/new"
[[ ! -e "$lnp_trust/writable/missing" ]]
echo 'PASS nonsticky writable ancestor rejected before creation'

for permission in delete_child writesecurity writeattr writeextattr add_file add_subdirectory delete chown; do
    lnp_acl="$lnp_trust/acl-$permission"
    mkdir -m 755 "$lnp_acl"
    mkdir -m 700 "$lnp_acl/private"
    chmod +a "everyone allow $permission" "$lnp_acl"
    refuse 'ancestor ACL granting mutation access' "$lnp_binary" prepare --volume "$lnp_volume" --entry "$lnp_token" --backup "$lnp_acl/private/new"
    [[ ! -e "$lnp_acl/private/new" ]]
done
echo 'PASS mutation-granting ancestor ACLs rejected'

mkdir -m 1777 "$lnp_trust/sticky"
"$lnp_binary" prepare --volume "$lnp_volume" --entry "$lnp_token" --backup "$lnp_trust/sticky/private/cleanup"
[[ -x "$lnp_trust/sticky/private/lnpctl-recovery" ]]
# The root test driver deliberately owns the captured output.
# shellcheck disable=SC2024
if sudo -u admin mv "$lnp_trust/sticky/private" "$lnp_trust/sticky/substituted" > "$lnp_trust/rename.txt" 2>&1; then
    echo 'Unprivileged user replaced a protected sticky-directory child' >&2
    exit 1
fi
[[ -d "$lnp_trust/sticky/private" ]]
echo 'PASS sticky root-owned parent accepted; unprivileged rename refused'

mkdir -m 755 "$lnp_trust/readonly-acl"
chmod +a 'everyone allow read,readattr,readextattr,readsecurity' "$lnp_trust/readonly-acl"
"$lnp_binary" prepare --volume "$lnp_volume" --entry "$lnp_token" --backup "$lnp_trust/readonly-acl/private/cleanup"
echo 'PASS read-only ancestor ACL accepted'

ln -s "$lnp_trust/sticky/private" "$lnp_trust/link"
refuse 'without symbolic links' "$lnp_binary" inspect "$lnp_trust/link/cleanup"
[[ $(shasum -a 256 "$lnp_store") == "$lnp_before" ]]
echo 'TRUST REGRESSIONS PASSED'
