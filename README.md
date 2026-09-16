# lnpctl — Local Network Privacy Control

Remove stale entries from macOS **System Settings → Privacy & Security → Local Network**. Select the entries you recognize, prepare a backup in normal macOS, then apply the cleanup from Recovery.

> **Experimental software. Back up your Mac before using it.**
> lnpctl edits an undocumented macOS settings file using private APIs. A mistake or a macOS update could damage settings or disrupt network access. Backups and validation checks cannot guarantee recovery. Try a disposable VM first, and use this only if you are comfortable troubleshooting macOS Recovery. Keep SIP enabled.

[Download v0.1.4](https://github.com/dev7a/lnpctl/releases/tag/v0.1.4) · [Step-by-step guide](https://dev7a.github.io/lnpctl/guide/) · [Validation and limits](docs/validation.md)

## Demo

The complete workflow: select entries, prepare a backup, apply the cleanup in Recovery, and check the result after reboot.

https://github.com/user-attachments/assets/736ebd32-908b-4f92-ab11-a8c2b96e6066

Recorded in a disposable Tart VM with narration. Pauses are cut and navigation is accelerated. [Watch with subtitles](https://dev7a.github.io/lnpctl/#tutorial).

## Requirements and tested coverage

- **Apple silicon Mac, macOS 15 or later.** This is the build target, not a claim that every supported macOS version has been tested.
- **Administrator access and macOS Recovery** to apply or restore changes.
- The downloaded executable needs **no Xcode, Python, or Homebrew**. It uses Apple's system libraries.

The restore implementation passed offline APFS tests in a macOS 26.6.1 VM, including restoration over a damaged archive. Earlier Recovery apply testing used macOS 27 beta 7. Physical-Mac operation, FileVault unlock, and a full Recovery restore/reboot cycle for the current implementation have not been validated. See the [test record](docs/validation.md) for the exact scope.

## Install

### Download the signed release

1. Open the [v0.1.4 release](https://github.com/dev7a/lnpctl/releases/tag/v0.1.4) and download `lnpctl-0.1.4-macos-arm64.dmg` and `SHA256SUMS` into the same folder.
2. In Terminal, change to that folder and run `shasum -a 256 -c SHA256SUMS`. Continue only if the DMG reports `OK`.
3. Open the DMG in Finder. It contains the Developer ID signed executable, MIT license, and installation notes. The DMG is notarized by Apple and has a stapled ticket.
4. Copy the executable to a directory you own:

   ```sh
   mkdir -p "$HOME/.local/bin"
   cp /Volumes/lnpctl/lnpctl "$HOME/.local/bin/lnpctl"
   "$HOME/.local/bin/lnpctl" --version
   ```

You can eject the disk image after copying. Copying the executable does not change Local Network settings or install a background service. Release downloads require repository access while the repository is private.

### Build from source

Install Xcode or Apple's Command Line Tools, then:

```sh
git clone https://github.com/dev7a/lnpctl.git
cd lnpctl
make
./build/lnpctl --version
```

The source build is an alternative to the downloaded executable. In the commands below, substitute `./build/lnpctl` for `"$HOME/.local/bin/lnpctl"` if you built from source.

## Clean up entries

1. **Select in normal macOS.** Close System Settings and the applications whose entries you intend to remove, then open the picker:

   ```sh
   sudo "$HOME/.local/bin/lnpctl"
   ```

   Use the arrow keys to move, Space to select, `/` to filter, and Enter to review. Nothing is selected automatically. A missing executable is a clue, not proof that an entry should be removed.
2. **Prepare the backup.** Press `p` in the review screen. This saves the original settings, proposed change, and executable without changing live permissions. Backups default to `/Users/Shared/lnpctl/backups/`. **Save the printed Recovery checklist on your phone or on paper before shutting down.**
3. **Apply in Recovery.** Shut down, enter Recovery, mount or unlock the correct Data volume, and follow the saved checklist. Review the selection again before confirming. Use the [illustrated Recovery walkthrough](docs/recovery-walkthrough.md) for the individual steps.
4. **Reboot and verify.** Check Local Network settings and test network access in the applications you kept.

The tool refuses to write the currently booted Data volume or apply a plan whose source has changed. Leave SIP enabled; Safe Mode is not a substitute for Recovery.

[Full operating instructions](docs/usage.md) cover all keyboard controls, custom backup locations, older backups, and noninteractive commands.

## Restore a backup

In Recovery, use the same saved launcher, choose the backup, and select `r` to restore it. Review and confirm before proceeding, then reboot and check your settings.

**Restore replaces the entire main NetworkExtension plist**, including later permission and configuration changes in that file. The current bytes are saved as a separate safety snapshot first. A corrupt current archive does not prevent restoring a valid backup, but an unreadable safety snapshot cannot itself be restored through lnpctl.

Backups contain private application and configuration data. Keep them private and do not edit them. Each backup runs its own staged executable; installing a newer lnpctl does not upgrade older backups. See [restore details](docs/usage.md#restore-a-backup).

## How it protects your settings

lnpctl removes selected rule references while preserving other archive objects, other users' rules, and unrelated NetworkExtension configurations. It validates the selection, backup, target volume, and file metadata before replacing the offline store. Unsupported layouts and changed source data cause refusal.

These checks reduce risk; they do not make Apple's undocumented format stable or provide a supported reset API. Read the [data-integrity details](docs/usage.md#data-integrity-and-scope) and [validation limits](docs/validation.md#limits) before trusting it with your settings.

## Development

Run `make test` for archive, terminal, and CLI tests. Tests that modify a settings store belong in an owned disposable VM or its dedicated APFS test image; see [validation](docs/validation.md).

The CLI is Objective-C and uses system libraries. The [website](site/README.md) has a separate Node build. GitHub Actions runs CLI tests on macOS 15 and 26, publishes the static site, and builds signed, notarized releases from approved signed version tags. See [release maintenance](docs/releases.md) and [Pages setup](docs/github-pages.md).

## License

[MIT](LICENSE). Third-party website components retain their [licenses and notices](site/public/THIRD_PARTY_NOTICES.txt).
