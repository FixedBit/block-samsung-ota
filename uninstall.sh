#!/system/bin/sh
MODDIR="/data/adb/modules/block_samsung_ota"
[ -f "$MODDIR/common.sh" ] && { . "$MODDIR/common.sh"; restore_all; }
