#!/system/bin/sh
SKIPUNZIP=0
ui_print " "
ui_print "===================================="
ui_print "       Block Samsung OTA"
ui_print "===================================="
ui_print "Disables Samsung FOTA packages for the owner user."
ui_print "Device Care, Knox Guard, Settings, and Play services are not disabled."
ui_print "Reboot is required before the rules run."
ui_print "Then check: su -c blockota health"
if [ -n "$MODPATH" ]; then
  if type set_perm >/dev/null 2>&1; then
    set_perm "$MODPATH/system/bin/blockota" 0 0 0755
  fi
  chmod 0755 "$MODPATH/system/bin/blockota" 2>/dev/null || true
fi
