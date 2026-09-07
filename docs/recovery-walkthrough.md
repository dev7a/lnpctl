# Apply a prepared cleanup from Recovery

These are unedited screenshots of a disposable Tart VM running macOS 27 Recovery. [Watch the 60-second screenshot walkthrough](media/recovery/lnpctl-recovery.mp4).

On a physical Apple silicon Mac, shut down, then hold the power button until startup options appear. The VM was launched with Tart's `--recovery` option; the physical power-button gesture is not shown. This guest did not require user authentication or FileVault unlock. If your Mac prompts for them, follow the prompts using your own login credentials.

## 1. Select Options

![Startup options](media/recovery/01-startup-options.jpg)

Click **Options**, then **Continue**.

![Options selected with Continue available](media/recovery/02-options-continue.jpg)

Wait for Recovery to finish booting.

![Recovery boot progress](media/recovery/03-recovery-boot.jpg)

## 2. Open Disk Utility

Select **Disk Utility**, then **Continue**.

![Disk Utility selected in Recovery](media/recovery/04-disk-utility.jpg)

## 3. Show the complete disk hierarchy

Choose **View → Show All Devices**.

![Show All Devices menu](media/recovery/05-show-all-devices.jpg)

## 4. Mount the Data volume

Select the **Data** volume beneath your startup disk, then click **Mount**. If it is encrypted, unlock it when prompted. Do not select Erase or Restore.

![Unmounted Data volume and Mount button](media/recovery/06-data-unmounted.jpg)

This VM's Data volume was already mounted on entering Recovery. We unmounted and remounted only the disposable guest volume to capture both states. If your volume is already mounted, leave it mounted.

Confirm the mount point. Here it is `/Volumes/Data`, and the toolbar now offers **Unmount**.

![Data mounted at Volumes Data](media/recovery/07-data-mounted.jpg)

## 5. Open Terminal

Choose **Disk Utility → Quit Disk Utility**, then **Utilities → Terminal** from the Recovery menu bar.

![Utilities menu with Terminal](media/recovery/08-utilities-terminal.jpg)

![Recovery Terminal open](media/recovery/09-terminal-open.jpg)

## 6. Check the mounted volume name

Run `ls /Volumes`. This guest shows `Data` among the mounted volumes.

![Terminal listing the mounted Data volume](media/recovery/10-terminal-volumes.jpg)

## 7. Run the prepared Recovery launcher

Use the command printed when you prepared the backup. With the default backup location and a volume mounted as `Data`, run:

```sh
'/Volumes/Data/Users/Shared/lnpctl/backups/lnpctl-recovery'
```

![Recovery launcher command](media/recovery/11-launcher-command.jpg)

The VM keyboard entered the path in lowercase; its case-insensitive filesystem resolved it. Use the capitalization in the command above, especially with case-sensitive volumes.

## 8. Select your backup

Choose the backup by its date and removal count. In this capture, the September 7 cleanup backup is number `2`; your number may differ.

![Choose a prepared backup](media/recovery/12-choose-backup.jpg)

## 9. Review and choose apply

Check the selected application's identity and executable path. Enter `a` to apply. This demonstration removes only the controlled stale **LNP Remove** entry in the disposable VM.

![Review the selected cleanup and choose apply](media/recovery/13-review-apply.jpg)

At **Apply this prepared cleanup? [y/N]**, enter `y` only if the displayed selection is correct. Return cancels.

![Final apply confirmation](media/recovery/14-confirm-apply.jpg)

## 10. Wait for verification, then reboot

The tool reports **Cleanup completed and verified.** It then instructs you to reboot and check settings and connectivity. It does not reboot automatically or display a separate yes/no reboot prompt.

![Cleanup verified with the reboot instruction](media/recovery/15-cleanup-complete.jpg)

Run:

```sh
reboot
```

![Reboot command after successful cleanup](media/recovery/16-reboot-command.jpg)

After login, check **System Settings → Privacy & Security → Local Network** and test the applications you kept. See the [complete checklist](../README.md#prepare-and-apply) for refusal handling and restore instructions.

## Capture details

These unedited screenshots were captured in a disposable Apple silicon Tart VM using macOS 27.0 build 26A5421a. The video is a paced sequence of screenshots, not a continuous recording. Application paths, the `admin` test account, configuration identifiers, and volume UUIDs belong to that disposable environment. No personal credentials or physical-Mac permission data appear in the demonstration.

The final steps use version 0.1.3 with a controlled stale test entry. The cleanup was actually applied and verified, and the guest was rebooted. After reboot, only the selected row was absent; retained entries had unchanged resolved public fields. SIP remained enabled. See [validation](validation.md) for coverage and limitations.
