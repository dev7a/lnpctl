# Validation

## Current version: 0.1.3

The current implementation has been tested on Apple silicon with **macOS 27 beta 7 (26A5421a)**. The build targets macOS 15 or later, but the permission-store workflow has not been validated on every supported deployment version.

Run the local checks with:

```sh
make test
```

The suite contains 31 tests: 13 archive tests, 13 real ncurses pseudo-terminal tests, and 5 CLI display and confirmation tests. The build uses `-Wall -Wextra -Werror` and Apple's system libraries. The filesystem shell scripts also pass `bash -n` and ShellCheck.

## What the tests cover

- Exact selected-rule removal, preservation of defaults and unrelated configurations, multiple users, malformed archives, stale selection tokens, and shared configuration/controller/array rejection.
- Selection, filtering with hidden selections, scrolling, review, explicit preparation, cancellation, terminal restoration, resizing, Unicode, and terminal-control sanitization.
- Root ownership, directory ancestry, symlink and ACL checks, launcher installation, version-bound backup execution, tampering, stale source data, and wrong-volume refusal.
- Apply and restore on a dedicated APFS test volume, preservation of ownership/mode/xattrs/ACLs, restore-safety snapshots, and already-installed behavior.

The root-only integration suite is [guest_filesystem.sh](../tests/guest_filesystem.sh), with [trust checks](../tests/guest_trust.sh) and [Recovery menu tests](../tests/guest_recovery.exp). It requires an owned disposable environment, a fresh dedicated `/Volumes/LNPCTL-Test` volume with ownership enabled, and a valid fixture and selection token. Do not run it against a normal startup volume.

## Recovery validation

On September 7, 2026, version 0.1.3 completed preparation, interactive apply in macOS Recovery, and a normal reboot in a disposable Tart VM. Preparation left the source unchanged. Recovery verified the installed bytes against the prepared cleanup. After reboot, only the selected stale test entry was absent; the three retained entries had unchanged resolved identity and permission fields. SIP remained enabled and the guest booted normally.

macOS may reserialize the permission store after reboot. Post-boot comparisons therefore use resolved rule fields, not byte equality or source-bound selection tokens.

The [Recovery walkthrough](recovery-walkthrough.md) shows the real navigation, launcher, confirmation, completion message, and reboot command using a controlled test entry. VM usernames, app paths, and volume identifiers shown there belong to the disposable test environment.

A previous 0.1.0 build also completed a full Recovery apply → normal boot → Recovery restore → normal boot cycle, with a retained application's network connection checked. That older result is not a full restore-cycle validation of 0.1.3. Current 0.1.3 restore coverage comes from the offline APFS integration tests.

## Limits

FileVault unlock was not exercised. The Recovery entry and authentication steps remain manual. Safe Mode did not allow the protected store write in testing; leave SIP enabled and use Recovery. Physical-Mac apply and restore are not covered by these VM results.

Test fixtures are controlled examples, not evidence that every macOS permission-store layout is supported. Unsupported or ambiguous layouts are rejected. A missing executable alone is not proof that its permission entry should be removed.
