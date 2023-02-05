
# Device Installation/Setup and Backup/Restore

## LineageOS Installation

Create at least one complete build of the device configuration you wish to use. Since any later updates will need to use the same signing keys, and to be sure that building actually works as intended, this might as well be a full build done on / issued by the host that will do and serve the [periodic builds](./module.nix.md).
Then, with the repository updated by building (yes, unfortunately that is pretty much necessary), run `nix develop /app/lineage-build/config#device` (where `device` the internal device name).
The shell that opens has some programs on its `PATH` and variables set, so use this for all following commands.


### Unlock Bootloader

0. Connect to internet (dunno why, but before that, the option was greyed out; maybe ethernet works)
1. "Settings" > "About phone" > "Build number" (tap 8 times)
2. "Settings" > "System" > "Developer options" > "OEM unlocking" (enable)
3. "Settings" > "System" > "Developer options" > "USB debugging" (enable)
4. connect to PC and:
```bash
adb devices # should list »HEX device«
adb reboot bootloader # wait for screen with text menu
fastboot devices # should list »HEX fastboot«
fastboot oem unlock # confirm on screen, wait for factory reset to complete and the phone to boot
```
6. Skip through the setup and repeat steps 1, and 3.


### Flash Recovery + System

1. In fastboot, flash `dtbo`, `vbmeta`, and `recovery`:
```bash
adb devices ; adb reboot bootloader # wait for screen with text menu
( img=$(mktemp -u) && trap "rm -f '$img'" EXIT && unzip -p /app/lineage-build/build/${device}/${device}-signed_target_files-${buildNumber}.zip IMAGES/dtbo.img >"$img" && fastboot flash dtbo "$img" )
( img=$(mktemp -u) && trap "rm -f '$img'" EXIT && unzip -p /app/lineage-build/build/${device}/${device}-signed_target_files-${buildNumber}.zip IMAGES/vbmeta.img >"$img" && fastboot flash vbmeta "$img" )
( img=$(mktemp -u) && trap "rm -f '$img'" EXIT && unzip -p /app/lineage-build/build/${device}/${device}-signed_target_files-${buildNumber}.zip IMAGES/recovery.img >"$img" && fastboot flash recovery "$img" )
```
2. The next step requires flashing a ZIP signed with the official LineageOS keys, which will not work with the self-built & self-signed recovery, so temporarily boot into the official recovery build:
(*Note:* An alternative to copying the firmware to the inactive slot may be to [update the firmware manually](https://wiki.lineageos.org/devices/${device}/fw_update).)
```bash
( img=$(mktemp -u) && trap "rm -f '$img'" EXIT && wget -qO- https://mirrorbits.lineageos.org/recovery/${device}/20221126/lineage-19.1-20221126-recovery-${device}.img >"$img" && fastboot boot "$img" ) # (might need to update the date)
```
3. In the official recovery, select "Apply Update" > "Apply from ADB", then:
```bash
( zip=$(mktemp -u) && trap "rm -f '$zip'" EXIT && wget -qO- https://mirrorbits.lineageos.org/tools/copy-partitions-20220613-signed.zip >"$zip" && adb sideload "$zip" ) # (might need to update the date) ; wait for this to complete
```
4. Still in the official recovery, go back > "Advanced" > "Reboot to recovery".
5. In the self-built recovery, select "Apply Update" > "Apply from ADB", then:
```bash
adb sideload /app/lineage-build/build/${device}/${device}-ota_update-${buildNumber}.zip
```
6. Go back > "Factory reset" > (proceed) > go back > "Reboot system now".


## Setup

### Backup (SeedVault)

Out-of-the-box, NextCloud works as a backup target, but I have found that to be quite unreliable.
Seafile with SeafDAV enabled and a (secondary) account without 2FA works via DAVx5, so I use  that instead.
One thing to look out for though is that the upload of files past the server maximum seems to fail silently, leaving files empty.
So after backing up, do check that there are no 0 byte files in the `.../.SeedVaultAndroidBackup/<timestamp>/` directory.

Install the DAVx5 app from F-Droid, go to Options > Tools > WebDAV mounts > (+) and sign in (URL: `https://<domain>/seafdav/<lib>/`).
Then go to Settings > System > Backup > Seedvault (DAVx5 with the previously added mount should be available as target location). Note down the 12 words (it seems to be impossible to just use a password) in a very safe and secure location and confirm them on the next screen.
Now enable to backup all the individual things, then press the vertical ... at the top right and select "Backup now".
"Backup status" seems to report apps/items where there isn't anything to back up yet (or that haven't been opened recently enough?) with an orange warning triangle. Those will not (at all?) be included in the backup; make sure there aren't any!
While marked as experimental, storage backup seems to work just fine. Keeping things like a local Signal backup (encrypted) or the Fair Email settings export (encrypted) or a local copy of a KeePass DB in `Backup/` and including that as backed-up folder seems advisable.
Also, `Documents/` should probably be backed up.


### Automatic Restore

1. Race through the setup, do WiFi, but skip everything else including restore. (If some swipe gestures don't work yet, restart.)
2. Install the DAVx5 app from F-Droid, go to Options > Tools > WebDAV mounts > (+) and sign in (URL: `https://<domain>/seafdav/<lib>/`).
3. Open the phone app and "dial" `*#*#7378673#*#*`.
4. Follow the restore wizard (DAVx5 with the previously added mount should be available).

This restores:
* WiFi networks
* microG settings
* wallpaper (and some other visual customization)
* call history and SMS
* the settings/data/accounts of all apps that had a green checkmark in the "Backup status" (at least in my three trial runs, and also for apps that didn't install automatically)
* some apps (which apps are automatically re-installed seems to be a coin-toss; many are, others the setup prompts for installation from stores (when using Aurora Store, it will need to be installed & set up first), yet others are silently omitted)
* system backup credentials (but the backup is not enabled)
* user files (with original timestamps, "Photos and images" seems to be at least `DCIM/Camera`)
* some permissions (internet denial: yes, battery optimization: yes?, remove permissions and free up space: no)


### Manual Restore

Unfortunately, a number of apps and system settings exclude themselves or are excluded from being backed up.


#### Security/Biometrics

Changing these settings resets some credentials that other apps store secured by biometrics, so do this first:
Go to Settings > Security. Change the "Screen lock" type (with an unlocked bootloader, a strong password is advisable, since offline attacks are probably possible).
Then optionally add a bunch of fingerprints and verify that they each work to unlock the phone.


#### SeaFile + KeePass

Since passwords are required for a lot of the following steps, set up KeePass first:
Sign in to Seafile and use it to open the password database with KeePass.


#### DAVx5

Follow the "[Nextcloud app](https://www.davx5.com/tested-with/nextcloud)" instructions (make sure to close the browser popup when it says the window may be closed).
Select "groups are per-contact categories" as "Contact group method", confirm.
Then select the desired items to sync in the different tabs (contact birthdays as calendar is unreliable, don't select it here) and hit the sync icon at the bottom right.

Go to Simple Calendar, Options > Settings, enable CalDAV sync and select the calendars.
Then go back, and under Options, tap "Add contact birthdays" (directly from the synced contacts; this works much better).


#### Fair Email

Open the app > Menu > Settings (bottom) > Menu > Import (get password from KeePass, select file from `phone/Backup/fairemail_*.backup`) > Menu > Close settings (but follow prompt to grant permissions first).
And after changing settings/accounts, export the settings again (will need to unlock "pro features" again on each new device).


### Other Things to do Manually

* [ ] sign back in to other accounts
* [ ] disable stock apps, arrange app icons
* [ ] enable/disable keyboards
* [ ] display: disable "smooth" (90fps, causes flickering)
* [ ] sound: disable for screen locking and "touch"
* [ ] fix launcher icon color of "simple" series apps
* [ ] enable system backups
