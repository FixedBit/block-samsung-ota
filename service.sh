#!/system/bin/sh
MODDIR="/data/adb/modules/block_samsung_ota"
[ -f "$MODDIR/common.sh" ] || exit 1
. "$MODDIR/common.sh"

while [ "$(getprop sys.boot_completed)" != "1" ]; do sleep 5; done
sleep 15

logi "Boot completed; evaluating Samsung OTA rules"
apply_boot_rules
logi "Boot OTA rule evaluation finished"

# Samsung can turn a disabled system package back on. Re-check only the
# explicit FOTA package list. This never scans package names and never
# disables Device Care, Knox Guard, Settings, or Play services.
detect_device
[ "$VENDOR" = "samsung" ] || exit 0
while :; do
  sleep 300
  apply_boot_rules true
done
