# Block Samsung OTA

KernelSU, Magisk, and APatch module that blocks Samsung software updates.

This is a Samsung adaptation of [Block OTA Update](https://github.com/manhgdev/Block-OTA-Update) v7.3 by [manhgdev](https://github.com/manhgdev), used under the MIT license. The Pixel module only auto-blocks Google phones, and its Samsung package list includes Device Care (`com.samsung.android.lool`). This module does not.

The Samsung changes were written with AI assistance.

## What it blocks

After Android finishes booting, on a Samsung phone only:

1. It disables these packages for the owner user when they are installed:
   - `com.wssyncmldm` — Samsung Software update / FOTA client
   - `com.sec.android.soagent` — Samsung software-update agent
   - `com.sec.android.fotaclient` — legacy FOTA client
   - `com.sec.android.systemupdate` — Samsung SystemUpdate package
   - `com.samsung.android.knox.efota` and `com.samsung.android.knox.efota.plugin` — Knox E-FOTA
   - `com.samsung.sdm` and `com.samsung.sdm.sdmviewer` — the package Knox labels as system updates
2. It installs one Intent Firewall rule that denies the Software update screen and the known FOTA download, install, poll, and push components inside `com.wssyncmldm`.
3. If `com.wssyncmldm` is still enabled after the package disable, it disables those same known components.
4. It deletes only these files, and only when no update snapshot or recovery command exists:
   - `/data/ota_package/metadata.pb`
   - `/data/ota_package/payload_metadata.bin`
   - `/data/fota/update.zip`

Missing packages are skipped. The module does not guess from package names at boot.

Samsung sometimes turns a disabled system package back on. The module repeats the same explicit list every five minutes. Already-disabled packages produce no extra log lines.

## What it leaves alone

- Device Care (`com.samsung.android.lool`)
- Knox Guard (`com.samsung.android.kgclient`)
- Settings, SystemUI, Phone, Play services, and Play Store
- Galaxy Store and its update center
- CSC / OMC (`com.samsung.android.app.omcagent`)
- `update_engine`, partitions, snapshots, and the rest of `/data/fota`

The Software update row in Settings may still be visible. Opening it is denied by the firewall rule, and the updater package is disabled, so it cannot download or install an update.

Do not install this on a Knox-enrolled, company-owned, or financed phone. Blocking FOTA there can make the device non-compliant. Knox Guard is not disabled, but a managed phone can still be flagged.

Do not install this beside the Pixel Block OTA Update module. Both provide `/system/bin/blockota`.

## Credits

- Original module: [manhgdev/Block-OTA-Update](https://github.com/manhgdev/Block-OTA-Update) v7.3, MIT license.
- Samsung port: [FixedBit/block-samsung-ota](https://github.com/FixedBit/block-samsung-ota), written with AI assistance.

## Install

1. Flash [Block-Samsung-OTA.zip](https://github.com/FixedBit/block-samsung-ota/releases/latest/download/Block-Samsung-OTA.zip) in KernelSU, Magisk, or APatch.
2. Reboot.
3. Check the result:

~~~sh
su -c blockota health
~~~

`com.wssyncmldm` and `com.sec.android.soagent` should say `disabled` when those packages exist on the phone. The firewall line should say `installed`.

## WebUI

KernelSU shows an Open button on this module. That page works like Zygisk Next's WebUI: it is a `webroot` page, and it reads live status by running `blockota`.

- **Status** shows whether blocking is active, whether the firewall rule is installed, and the state of every built-in Samsung update package.
- **Packages** lists installed packages whose names look like an updater but are not already in the built-in list. **Block** disables that package now and on later boots. **Not an updater** hides it from the list. Device Care, Knox Guard, Settings, and Play services cannot be added.
- **Settings** turns blocking on or off. Off restores the packages this module disabled.

Magisk does not open module WebUI pages itself. Use [KsuWebUI Standalone](https://github.com/5ec1cff/KsuWebUIStandalone/releases), the same app Zygisk Next documents for Magisk.

## Commands

~~~sh
su -c blockota status
su -c blockota health
su -c blockota block
su -c blockota enforce
su -c blockota restore
su -c blockota pause
su -c blockota resume
su -c blockota scan
su -c blockota log
~~~

`pause` stops enforcement and removes the firewall rule. Packages that were already disabled stay disabled. `restore` re-enables only what this module disabled, removes the firewall rule, and pauses enforcement. `resume` blocks again.

Smart Block is manual and can match packages by name. Review the log before rebooting. It is never run at boot.

~~~sh
su -c blockota scan-smart
su -c blockota smart-block-on
su -c blockota smart-block-off
~~~

## Recovery

If Android still boots:

~~~sh
su -c blockota restore
~~~

If you need the module stopped before Android starts, from recovery:

~~~sh
touch /data/adb/modules/block_samsung_ota/disable
rm -f /data/system/ifw/block_samsung_ota.xml
~~~

Remove that `disable` file later to let the module run again. Prefer `blockota restore` from a booted system.

## Release

Pushing a `vM.m` tag (`v1.0`, `v1.1`, … `v1.9`, `v2.0`) runs the GitHub Action. `versionCode` is `major * 10 + minor`, so v1.0 is 10. The tag, `module.prop`, and `update.json` must match. The action checks the scripts, builds `Block-Samsung-OTA.zip`, and publishes that zip on the release.
