# Changelog

## v1.1

- Adds a KernelSU WebUI with a status page and a package page, following the same module WebUI pattern as Zygisk Next.
- Status shows the firewall rule and whether each built-in Samsung update package is disabled.
- Packages lists installed update-like apps that are not in the built-in list. Block adds one to the extra list. Not an updater hides it from the list.
- Device Care, Knox Guard, Settings, and Play services stay protected and cannot be blocked from the page.

## v1.0

Samsung adaptation of manhgdev Block OTA Update v7.3.

- Runs the block automatically on Samsung after boot, then re-checks the same package list every five minutes.
- Disables dedicated Samsung update packages for user 0: `com.wssyncmldm`, `com.sec.android.soagent`, legacy `com.sec.android.fotaclient`, `com.sec.android.systemupdate`, Knox E-FOTA, and `com.samsung.sdm` when those packages are installed.
- Installs one module-owned Intent Firewall rule for the Software update action and the known Samsung FOTA screens, receivers, and poll/push services.
- If `com.wssyncmldm` stays enabled, disables only the known update components inside that package.
- Removes only `/data/ota_package/metadata.pb`, `/data/ota_package/payload_metadata.bin`, and `/data/fota/update.zip`, and only when no OTA snapshot or recovery command is present.
- Does not disable Device Care, Knox Guard, Settings, Play services, Galaxy Store, CSC/OMC, or `update_engine`.
- Restore re-enables only recorded changes and deletes only the module-owned firewall file.
