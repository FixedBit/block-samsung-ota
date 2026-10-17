#!/system/bin/sh

# Samsung OTA blocker. Adapted from manhgdev Block OTA Update v7.3.
# State changes are limited to the owner user and recorded so restore only
# undoes what this module changed.

MODDIR="/data/adb/modules/block_samsung_ota"
LOG="/data/local/tmp/block_samsung_ota.log"
STATE_DIR="/data/adb/block_samsung_ota"
APPLIED_LIST="$STATE_DIR/applied.txt"
REPORT_JSON="$STATE_DIR/report.json"
REPORT_HTML="/sdcard/BlockSamsungOTA/report.html"
SMART_SCAN_LIST="$STATE_DIR/smart_scan_targets.txt"
TOGGLE_DIR="$STATE_DIR/toggles"
DISABLE_FILE="$TOGGLE_DIR/disable"
DRYRUN_FILE="$TOGGLE_DIR/dryrun"
SMART_BLOCK_FILE="$TOGGLE_DIR/smart_block"
USER_WHITELIST="$TOGGLE_DIR/whitelist.txt"
USER_BLACKLIST="$TOGGLE_DIR/blacklist.txt"
IGNORED_FILE="$TOGGLE_DIR/ignored.txt"
MISS_RE='ota|fota|soagent|wssync|fotaclient|systemupdate|efota|softwareupdate|(^|\.)sdm(\.|$)'
IFW_DIR="/data/system/ifw"
IFW_RULE="$IFW_DIR/block_samsung_ota.xml"
IFW_SOURCE="$MODDIR/ifw/block_samsung_ota.xml"
IFW_RULE_OWNER="Block Samsung OTA: module-owned Samsung software update rule"
IFW_ACTION="android.settings.SYSTEM_UPDATE_SETTINGS"
IFW_SETTINGS_COMPONENT="com.android.settings/.Settings\$SoftwareUpdateSettingLaunchActivity"
IFW_DOWNLOAD_COMPONENT="com.wssyncmldm/com.idm.fotaagent.enabler.ui.downloadconfirm.DownloadConfirmActivity"
OTA_METADATA_FILE="/data/ota_package/metadata.pb"
OTA_PAYLOAD_METADATA_FILE="/data/ota_package/payload_metadata.bin"
FOTA_UPDATE_ZIP="/data/fota/update.zip"
OTA_SNAPSHOT_DIR="/metadata/ota/snapshots"
RECOVERY_COMMAND="/cache/recovery/command"

mkdir -p "$STATE_DIR" "$TOGGLE_DIR" 2>/dev/null
[ -f "$USER_WHITELIST" ] || cat > "$USER_WHITELIST" <<EOF
# One package per line. Packages here are never disabled.
# Example: com.samsung.android.kgclient
EOF
[ -f "$USER_BLACKLIST" ] || cat > "$USER_BLACKLIST" <<EOF
# One package per line. Extra packages disabled by blockota block and at boot.
# Do not list Device Care, Knox Guard, Settings, or Play services here.
# Example: com.vendor.ota
EOF

logi(){ echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG"; }
lower(){ echo "$1" | tr '[:upper:]' '[:lower:]'; }
prop(){ getprop "$1" 2>/dev/null; }
module_value(){ sed -n "s/^$1=//p" "$MODDIR/module.prop" 2>/dev/null | head -n 1; }
json_escape(){ printf '%s' "$1" | tr -d '\n' | sed 's/\\/\\\\/g; s/"/\\"/g'; }

detect_device(){
  BRAND="$(lower "$(prop ro.product.brand)")"
  MANUFACTURER="$(lower "$(prop ro.product.manufacturer)")"
  DEVICE="$(lower "$(prop ro.product.device)")"
  MODEL="$(lower "$(prop ro.product.model)")"
  FINGERPRINT="$(lower "$(prop ro.build.fingerprint)")"
  ROM="$(lower "$(prop ro.build.version.incremental)")"
  SDK="$(prop ro.build.version.sdk)"
  RELEASE="$(prop ro.build.version.release)"
  SLOT="$(prop ro.boot.slot_suffix)"
  AB_OTA="$(prop ro.build.ab_update)"
  ONEUI="$(prop ro.build.version.oneui)"
  ID="$BRAND $MANUFACTURER $DEVICE $MODEL $FINGERPRINT $ROM"
  VENDOR="generic"
  echo "$ID" | grep -qiE "google|pixel" && VENDOR="google"
  echo "$ID" | grep -qiE "samsung|oneui" && VENDOR="samsung"
  echo "$ID" | grep -qiE "xiaomi|redmi|poco|miui|hyperos" && VENDOR="xiaomi"
  echo "$ID" | grep -qiE "oppo|realme|oneplus|coloros|oxygen" && VENDOR="oppo"
  echo "$ID" | grep -qiE "vivo|iqoo|bbk" && VENDOR="vivo"
  echo "$ID" | grep -qiE "huawei|honor|emui|harmony" && VENDOR="huawei"
  echo "$ID" | grep -qiE "motorola|moto|lenovo" && VENDOR="motorola"
  echo "$ID" | grep -qiE "sony|xperia" && VENDOR="sony"
  echo "$ID" | grep -qiE "asus|rog" && VENDOR="asus"
  echo "$ID" | grep -qiE "nothing" && VENDOR="nothing"
  echo "$ID" | grep -qiE "nokia|hmd" && VENDOR="nokia"
  echo "$ID" | grep -qiE "lge|lg" && VENDOR="lg"
  [ -n "$ONEUI" ] && VENDOR="samsung"
}

is_user_whitelisted(){
  [ -f "$USER_WHITELIST" ] || return 1
  grep -v '^[[:space:]]*#' "$USER_WHITELIST" | sed '/^[[:space:]]*$/d' | grep -qx "$1"
}

is_protected_pkg(){
  is_user_whitelisted "$1" && return 0
  case "$1" in
    android|\
    com.android.systemui|\
    com.android.settings|\
    com.android.packageinstaller|\
    com.android.providers.settings|\
    com.android.providers.downloads|\
    com.android.phone|\
    com.android.vending|\
    com.google.android.gms|\
    com.samsung.android.kgclient|\
    com.samsung.android.knox.containercore|\
    com.samsung.android.knox.attestation|\
    com.samsung.android.lool|\
    com.samsung.android.app.omcagent|\
    com.sec.android.app.samsungapps|\
    com.samsung.android.app.updatecenter)
      return 0
      ;;
  esac
  return 1
}

pkg_exists(){ pm path "$1" >/dev/null 2>&1; }

pkg_state(){
  p="$1"
  if ! pkg_exists "$p"; then
    echo "absent"
  elif pm list packages -d --user 0 2>/dev/null | grep -qx "package:$p"; then
    echo "disabled"
  else
    echo "enabled"
  fi
}

component_package(){ echo "$1" | cut -d/ -f1; }
component_full_name(){
  c="$1"
  p="$(component_package "$c")"
  short="$(echo "$c" | cut -d/ -f2-)"
  case "$short" in
    .*) echo "$p$short" ;;
    *) echo "$short" ;;
  esac
}

clear_component_dump_cache(){
  rm -f "$STATE_DIR"/.block_ota_dump.$$.* 2>/dev/null
  unset COMPONENT_DUMP_FILE
}

load_component_package_dump(){
  p="$1"
  safe="$(printf '%s' "$p" | tr -c 'A-Za-z0-9_.-' '_')"
  dump_file="$STATE_DIR/.block_ota_dump.$$.$safe"
  if [ ! -f "$dump_file" ]; then
    pkg_exists "$p" || return 1
    dumpsys package "$p" > "$dump_file" 2>/dev/null || return 1
  fi
  [ -s "$dump_file" ] || return 1
  COMPONENT_DUMP_FILE="$dump_file"
}

component_exists(){
  c="$1"
  p="$(component_package "$c")"
  full="$(component_full_name "$c")"
  pkg_exists "$p" || return 1
  load_component_package_dump "$p" || return 1
  grep -Fq "$full" "$COMPONENT_DUMP_FILE"
}

ifw_rule_is_owned(){
  [ -f "$IFW_RULE" ] && grep -Fq "$IFW_RULE_OWNER" "$IFW_RULE" 2>/dev/null
}

ifw_source_is_safe(){
  [ -f "$IFW_SOURCE" ] &&
    grep -Fq "$IFW_RULE_OWNER" "$IFW_SOURCE" 2>/dev/null &&
    grep -Fq "<action name=\"$IFW_ACTION\" />" "$IFW_SOURCE" 2>/dev/null &&
    grep -Fq "<component-filter name=\"$IFW_SETTINGS_COMPONENT\" />" "$IFW_SOURCE" 2>/dev/null &&
    grep -Fq "<component-filter name=\"$IFW_DOWNLOAD_COMPONENT\" />" "$IFW_SOURCE" 2>/dev/null &&
    ! grep -Eq 'kgclient|com\.samsung\.android\.lool|update_engine|com\.android\.systemui|com\.google\.android\.gms|com\.android\.phone' "$IFW_SOURCE" 2>/dev/null
}

ifw_rule_state(){
  if [ ! -e "$IFW_RULE" ]; then
    echo "absent"
  elif ifw_rule_is_owned; then
    echo "installed"
  else
    echo "foreign (untouched)"
  fi
}

install_samsung_update_rule(){
  quiet="${1:-false}"
  [ -f "$DRYRUN_FILE" ] && { [ "$quiet" = true ] || logi "[DRYRUN] Would install Samsung Software update Intent Firewall rule"; return 0; }
  if ! ifw_source_is_safe; then
    logi "WARNING: Intent Firewall source failed its exact-target safety check; skipped"
    return 1
  fi
  if [ -e "$IFW_RULE" ] && ! ifw_rule_is_owned; then
    logi "WARNING: Existing Intent Firewall rule is not module-owned; left untouched: $IFW_RULE"
    return 1
  fi
  if [ -f "$IFW_RULE" ] && cmp -s "$IFW_SOURCE" "$IFW_RULE" 2>/dev/null; then
    [ "$quiet" = true ] || logi "Samsung Software update Intent Firewall rule already installed"
    return 0
  fi
  mkdir -p "$IFW_DIR" 2>/dev/null || { logi "WARNING: Cannot access Intent Firewall directory: $IFW_DIR"; return 1; }
  tmp="$IFW_DIR/.block_samsung_ota.$$"
  rm -f "$tmp"
  if cp "$IFW_SOURCE" "$tmp" 2>/dev/null &&
     chown system:system "$tmp" 2>/dev/null &&
     chmod 600 "$tmp" 2>/dev/null &&
     { restorecon "$tmp" >/dev/null 2>&1 || true; } &&
     mv "$tmp" "$IFW_RULE" 2>/dev/null; then
    logi "Installed Samsung Software update Intent Firewall rule"
    return 0
  fi
  rm -f "$tmp"
  logi "WARNING: Could not install Samsung Software update Intent Firewall rule"
  return 1
}

remove_samsung_update_rule(){
  quiet="${1:-false}"
  if [ ! -e "$IFW_RULE" ]; then
    [ "$quiet" = true ] || logi "Samsung Software update Intent Firewall rule already absent"
    return 0
  fi
  if ! ifw_rule_is_owned; then
    logi "WARNING: Refusing to remove non-module Intent Firewall rule: $IFW_RULE"
    return 1
  fi
  if rm -f "$IFW_RULE"; then
    logi "Removed module-owned Samsung Software update Intent Firewall rule"
    return 0
  fi
  logi "WARNING: Could not remove module-owned Intent Firewall rule: $IFW_RULE"
  return 1
}

samsung_ota_cleanup_is_safe(){
  [ -f "$RECOVERY_COMMAND" ] && return 1
  [ -d "$OTA_SNAPSHOT_DIR" ] || return 0
  snapshot_entry="$(find "$OTA_SNAPSHOT_DIR" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)"
  [ -z "$snapshot_entry" ]
}

remove_exact_ota_metadata_file(){
  target="$1"
  case "$target" in
    "$OTA_METADATA_FILE"|"$OTA_PAYLOAD_METADATA_FILE"|"$FOTA_UPDATE_ZIP") ;;
    *) logi "WARNING: Refusing unexpected OTA cleanup target: $target"; return 1 ;;
  esac
  [ -f "$target" ] || return 0
  bytes="$(wc -c < "$target" 2>/dev/null | tr -d ' ')"
  if rm -f "$target"; then
    logi "Removed stale Samsung OTA metadata: $target bytes=${bytes:-unknown}"
  else
    logi "WARNING: Could not remove stale Samsung OTA metadata: $target"
    return 1
  fi
}

cleanup_samsung_ota_metadata(){
  quiet="${1:-false}"
  if [ -f "$DRYRUN_FILE" ]; then
    [ "$quiet" = true ] || logi "[DRYRUN] Would remove exact Samsung OTA metadata files when no update is in progress"
    return 0
  fi
  if ! samsung_ota_cleanup_is_safe; then
    [ "$quiet" = true ] || logi "WARNING: OTA snapshot or recovery command exists; skipped metadata cleanup"
    return 1
  fi
  remove_exact_ota_metadata_file "$OTA_METADATA_FILE"
  remove_exact_ota_metadata_file "$OTA_PAYLOAD_METADATA_FILE"
  remove_exact_ota_metadata_file "$FOTA_UPDATE_ZIP"
}

component_state(){
  c="$1"
  p="$(component_package "$c")"
  full="$(component_full_name "$c")"
  load_component_package_dump "$p" || { echo "unknown"; return; }
  grep -q '^[[:space:]]*User 0:' "$COMPONENT_DUMP_FILE" || { echo "unknown"; return; }
  awk -v target="$full" '
    $1 == "User" && $2 == "0:" { in_user=1; section=""; next }
    $1 == "User" && $2 ~ /^[0-9]+:$/ && in_user { exit }
    !in_user { next }
    $0 ~ /^[[:space:]]*disabledComponents:/ { section="disabled"; next }
    $0 ~ /^[[:space:]]*enabledComponents:/ { section="enabled"; next }
    section == "disabled" && index($0, target) > 0 { found=1; exit }
    END { if (found) print "disabled"; else print "enabled" }
  ' "$COMPONENT_DUMP_FILE"
}

record_applied(){
  entry="$1|$2"
  grep -Fqx "$entry" "$APPLIED_LIST" 2>/dev/null || echo "$entry" >> "$APPLIED_LIST"
}

disable_component_safely(){
  c="$1"
  p="$(component_package "$c")"
  quiet="${2:-false}"
  [ -f "$DRYRUN_FILE" ] && { [ "$quiet" = true ] || logi "[DRYRUN] Would disable component user=0: $c"; return; }
  is_user_whitelisted "$p" && { [ "$quiet" = true ] || logi "Skip whitelisted component package: $p"; return; }
  is_protected_pkg "$p" && { [ "$quiet" = true ] || logi "Skip protected component package: $p"; return; }
  component_exists "$c" || { [ "$quiet" = true ] || logi "Skip unavailable OTA component: $c"; return; }
  state="$(component_state "$c")"
  case "$state" in
    disabled) [ "$quiet" = true ] || logi "Component already disabled user=0: $c"; return ;;
    unknown) [ "$quiet" = true ] || logi "WARNING: State unknown; skipped component: $c"; return ;;
  esac
  err="$(pm disable --user 0 "$c" 2>&1)"
  status=$?
  if [ "$status" -eq 0 ]; then
    record_applied component "$c"
    logi "Disabled OTA component user=0: $c"
  else
    err="$(printf '%s' "$err" | tr '\n' ' ' | cut -c 1-180)"
    logi "WARNING: Could not disable OTA component: $c $err"
  fi
}

disable_package_safely(){
  p="$1"
  quiet="${2:-false}"
  if [ -f "$DRYRUN_FILE" ]; then
    [ "$quiet" = true ] || logi "[DRYRUN] Would disable package user=0: $p"
    return 0
  fi
  if ! pkg_exists "$p"; then
    [ "$quiet" = true ] || logi "Skip unavailable package: $p"
    return 0
  fi
  if is_protected_pkg "$p"; then
    [ "$quiet" = true ] || logi "Skip protected/whitelisted package: $p"
    return 0
  fi
  state="$(pkg_state "$p")"
  if [ "$state" = "disabled" ]; then
    [ "$quiet" = true ] || logi "Package already disabled user=0: $p"
    return 0
  fi
  err="$(pm disable-user --user 0 "$p" 2>&1)"
  status=$?
  if [ "$status" -eq 0 ]; then
    record_applied package "$p"
    logi "Disabled OTA package user=0: $p"
  else
    err="$(printf '%s' "$err" | tr '\n' ' ' | cut -c 1-180)"
    logi "WARNING: Could not disable OTA package: $p $err"
  fi
}

# Dedicated Samsung update packages. Each one is the updater itself.
# Device Care (com.samsung.android.lool) is intentionally absent.
samsung_ota_packages(){
  printf '%s\n' \
    'com.wssyncmldm' \
    'com.sec.android.soagent' \
    'com.sec.android.fotaclient' \
    'com.sec.android.systemupdate' \
    'com.samsung.android.knox.efota' \
    'com.samsung.android.knox.efota.plugin' \
    'com.samsung.sdm' \
    'com.samsung.sdm.sdmviewer'
}

# Used only when the FOTA package is installed but package disable failed.
wssync_fallback_components(){
  printf '%s\n' \
    'com.wssyncmldm/com.idm.fotaagent.enabler.ui.userinit.UserInitEntryActivity' \
    'com.wssyncmldm/com.idm.fotaagent.enabler.ui.dialog.IDMUIActivityForDialog' \
    'com.wssyncmldm/com.idm.fotaagent.enabler.ui.reschedulepostpone.ReschedulePostponeActivity' \
    'com.wssyncmldm/com.idm.fotaagent.enabler.ui.downloadconfirm.DownloadConfirmActivity' \
    'com.wssyncmldm/com.idm.fotaagent.enabler.ui.downloadprogress.DownloadProgressActivity' \
    'com.wssyncmldm/com.idm.fotaagent.enabler.ui.installconfirm.InstallConfirmActivity' \
    'com.wssyncmldm/com.idm.fotaagent.enabler.ui.noupdatable.NoUpdatableVersionActivity' \
    'com.wssyncmldm/com.idm.fotaagent.enabler.ui.lastupdate.LastUpdateActivity' \
    'com.wssyncmldm/com.idm.fotaagent.enabler.ui.checkingforupdate.CheckingForUpdateActivity' \
    'com.wssyncmldm/com.idm.fotaagent.enabler.ui.maindescription.MainDescriptionActivity' \
    'com.wssyncmldm/com.idm.fotaagent.enabler.ui.uic.IDMUICActivity' \
    'com.wssyncmldm/com.idm.fotaagent.enabler.ui.admin.main.AdminMainActivity' \
    'com.wssyncmldm/com.idm.fotaagent.enabler.ui.admin.feature.AdminFeatureAndActionActivity' \
    'com.wssyncmldm/com.idm.fotaagent.enabler.ui.admin.profile.AdminProfileActivity' \
    'com.wssyncmldm/com.samsung.android.fotaagent.common.feature.FeatureInjectionActivity' \
    'com.wssyncmldm/com.samsung.android.fotaagent.device.push.campaign.ui.CampaignMessageActivity' \
    'com.wssyncmldm/com.samsung.android.fotaagent.ui.CampaignActivity' \
    'com.wssyncmldm/com.idm.fotaagent.abupdate.abenabler.ui.downloadandinstallprogress.DownloadAndInstallProgressActivity' \
    'com.wssyncmldm/com.samsung.android.fotaagent.receiver.GenericBroadcastReceiver' \
    'com.wssyncmldm/com.samsung.android.fotaagent.receiver.SecureBroadcastReceiver' \
    'com.wssyncmldm/com.samsung.android.fotaagent.receiver.LaunchReceiver' \
    'com.wssyncmldm/com.samsung.android.fotaagent.receiver.SecretCodeReceiver' \
    'com.wssyncmldm/com.samsung.android.fotaagent.device.push.campaign.notification.CampaignNotificationReceiver' \
    'com.wssyncmldm/com.samsung.android.fotaagent.device.push.message.spp.SppReceiver' \
    'com.wssyncmldm/com.idm.fotaagent.enabler.ui.notification.manager.NotificationReceiver' \
    'com.wssyncmldm/com.idm.fotaagent.enabler.fumo.postpone.PostponeAlarmReceiver' \
    'com.wssyncmldm/com.samsung.android.fotaagent.policy.afw.duration.PolicyManager$PolicyExpirationAlarmReceiver' \
    'com.wssyncmldm/com.samsung.android.fotaagent.device.services.PollingIntentService' \
    'com.wssyncmldm/com.samsung.android.fotaagent.device.heartbeat.intentservice.PeriodicHeartbeatIntentService' \
    'com.wssyncmldm/com.samsung.android.fotaagent.device.heartbeat.intentservice.OneShotHeartbeatIntentService' \
    'com.wssyncmldm/com.samsung.android.fotaagent.device.push.message.fcm.FcmReceiveService' \
    'com.wssyncmldm/com.samsung.android.fotaagent.device.push.message.spp.SppIntentService' \
    'com.wssyncmldm/com.idm.fotaagent.scheduler.jobschedule.NetworkResumeJobService' \
    'com.wssyncmldm/com.idm.fotaagent.InitExecutor$InitService'
}

resolve_system_update_activity(){
  cmd package resolve-activity --brief --user 0 -a android.settings.SYSTEM_UPDATE_SETTINGS -c android.intent.category.DEFAULT 2>/dev/null | grep '/' | head -n 1
}

note_resolved_system_update_activity(){
  quiet="${1:-false}"
  activity="$(resolve_system_update_activity)"
  if [ -z "$activity" ]; then
    [ "$quiet" = true ] || logi "No handler resolved for $IFW_ACTION"
    return 0
  fi
  [ "$quiet" = true ] || logi "Resolved software-update activity: $activity"
}

user_blacklist_targets(){
  [ -f "$USER_BLACKLIST" ] || return 0
  grep -v '^[[:space:]]*#' "$USER_BLACKLIST" | sed '/^[[:space:]]*$/d'
}

valid_package_name(){
  printf '%s' "$1" | grep -qxE '[A-Za-z][A-Za-z0-9_]*(\.[A-Za-z][A-Za-z0-9_]*)+'
}

list_file_entries(){
  [ -f "$1" ] || return 0
  grep -v '^[[:space:]]*#' "$1" | sed '/^[[:space:]]*$/d'
}

list_contains(){
  list_file_entries "$1" | grep -qx "$2"
}

list_add(){
  valid_package_name "$2" || return 1
  list_contains "$1" "$2" && return 0
  echo "$2" >> "$1"
}

list_remove(){
  [ -f "$1" ] || return 0
  pending="$STATE_DIR/list.$$"
  grep -Fvx "$2" "$1" > "$pending" 2>/dev/null || true
  mv "$pending" "$1"
}

is_builtin_ota_pkg(){
  samsung_ota_packages | grep -qx "$1"
}

drop_applied_record(){
  entry="$1|$2"
  [ -f "$APPLIED_LIST" ] || return 0
  pending="$STATE_DIR/applied.drop.$$"
  grep -Fvx "$entry" "$APPLIED_LIST" > "$pending" 2>/dev/null || true
  if [ -s "$pending" ]; then
    mv "$pending" "$APPLIED_LIST"
  else
    rm -f "$pending" "$APPLIED_LIST"
  fi
}

release_recorded_package(){
  p="$1"
  entry="package|$p"
  grep -Fqx "$entry" "$APPLIED_LIST" 2>/dev/null || return 0
  if pm enable --user 0 "$p" >/dev/null 2>&1; then
    drop_applied_record package "$p"
    logi "Released extra package user=0: $p"
  else
    logi "WARNING: Could not release package: $p"
    return 1
  fi
}

matching_update_packages(){
  pm list packages 2>/dev/null | cut -d: -f2 | grep -iE "$MISS_RE" | sort
}

json_pkg(){
  printf '{"name":"%s","state":"%s"}' "$(json_escape "$1")" "$(json_escape "$2")"
}

emit_state_array(){
  first=1
  printf '['
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    [ "$first" = 1 ] || printf ','
    first=0
    printf '%s' "$(json_pkg "$p" "$(pkg_state "$p")")"
  done
  printf ']'
}

blacklist_add_pkg(){
  p="$1"
  valid_package_name "$p" || { echo "invalid package name"; return 1; }
  if is_builtin_ota_pkg "$p"; then
    echo "already in the built-in list"
    return 0
  fi
  if is_protected_pkg "$p"; then
    echo "protected package, left enabled"
    return 1
  fi
  list_remove "$IGNORED_FILE" "$p"
  list_add "$USER_BLACKLIST" "$p" || return 1
  if [ -f "$DISABLE_FILE" ]; then
    echo "saved; turn blocking back on to disable it"
    return 0
  fi
  disable_package_safely "$p"
  state="$(pkg_state "$p")"
  if [ "$state" = "disabled" ]; then
    echo "blocked $p"
    return 0
  fi
  if [ "$state" = "absent" ]; then
    echo "saved; package is not installed"
    return 0
  fi
  echo "saved, but the package is still enabled"
  return 1
}

blacklist_remove_pkg(){
  p="$1"
  valid_package_name "$p" || { echo "invalid package name"; return 1; }
  list_remove "$USER_BLACKLIST" "$p"
  release_recorded_package "$p" || return 1
  echo "unblocked $p"
}

ignore_add_pkg(){
  p="$1"
  valid_package_name "$p" || { echo "invalid package name"; return 1; }
  list_remove "$USER_BLACKLIST" "$p"
  release_recorded_package "$p" || return 1
  list_add "$IGNORED_FILE" "$p" || return 1
  echo "ignored $p"
}

ui_report(){
  detect_device
  version="$(module_value version)"
  version_code="$(module_value versionCode)"
  case "$version_code" in
    ''|*[!0-9]*) version_code=0 ;;
  esac
  paused=false
  [ -f "$DISABLE_FILE" ] && paused=true
  dryrun=false
  [ -f "$DRYRUN_FILE" ] && dryrun=true
  ifw="$(ifw_rule_state)"
  activity="$(resolve_system_update_activity)"
  summary="blocking"
  if [ "$VENDOR" != "samsung" ]; then
    summary="wrong-device"
  elif [ "$paused" = true ]; then
    summary="paused"
  elif [ "$ifw" != "installed" ]; then
    summary="incomplete"
  else
    for p in $(samsung_ota_packages); do
      [ "$(pkg_state "$p")" = "enabled" ] && summary="incomplete"
    done
  fi
  printf '{'
  printf '"version":"%s",' "$(json_escape "$version")"
  printf '"versionCode":%s,' "$version_code"
  printf '"paused":%s,' "$paused"
  printf '"dryrun":%s,' "$dryrun"
  printf '"summary":"%s",' "$summary"
  printf '"vendor":"%s",' "$(json_escape "$VENDOR")"
  printf '"brand":"%s",' "$(json_escape "$BRAND")"
  printf '"model":"%s",' "$(json_escape "$MODEL")"
  printf '"device":"%s",' "$(json_escape "$DEVICE")"
  printf '"android":"%s",' "$(json_escape "$RELEASE")"
  printf '"sdk":"%s",' "$(json_escape "$SDK")"
  printf '"oneui":"%s",' "$(json_escape "$ONEUI")"
  printf '"ifw":"%s",' "$(json_escape "$ifw")"
  printf '"resolvedActivity":"%s",' "$(json_escape "$activity")"
  printf '"packages":'
  samsung_ota_packages | emit_state_array
  printf ',"missed":'
  matching_update_packages | while IFS= read -r p; do
    [ -n "$p" ] || continue
    is_builtin_ota_pkg "$p" && continue
    is_protected_pkg "$p" && continue
    list_contains "$USER_BLACKLIST" "$p" && continue
    list_contains "$IGNORED_FILE" "$p" && continue
    printf '%s\n' "$p"
  done | emit_state_array
  printf ',"protectedMatches":'
  matching_update_packages | while IFS= read -r p; do
    [ -n "$p" ] || continue
    is_protected_pkg "$p" || continue
    printf '%s\n' "$p"
  done | emit_state_array
  printf ',"blockedExtra":'
  user_blacklist_targets | emit_state_array
  printf ',"ignored":['
  first=1
  list_file_entries "$IGNORED_FILE" | while IFS= read -r p; do
    [ "$first" = 1 ] || printf ','
    first=0
    printf '"%s"' "$(json_escape "$p")"
  done
  printf ']}\n'
}

block_samsung_packages(){
  quiet="${1:-false}"
  for p in $(samsung_ota_packages; user_blacklist_targets); do
    disable_package_safely "$p" "$quiet"
  done
}

block_wssync_fallback(){
  quiet="${1:-false}"
  state="$(pkg_state com.wssyncmldm)"
  [ "$state" = "enabled" ] || return 0
  [ "$quiet" = true ] || logi "com.wssyncmldm is still enabled; disabling its known update components"
  for c in $(wssync_fallback_components); do
    disable_component_safely "$c" "$quiet"
  done
}

fota_dir_state(){
  if [ ! -d /data/fota ]; then
    echo "absent"
  elif [ -n "$(find /data/fota -mindepth 1 -print -quit 2>/dev/null)" ]; then
    echo "present"
  else
    echo "empty"
  fi
}

block_samsung(){
  quiet="${1:-false}"
  [ "$quiet" = true ] || logi "Applying Samsung OTA rule set model=$MODEL android=$RELEASE oneui=${ONEUI:-none} sdk=$SDK"
  if install_samsung_update_rule "$quiet"; then
    cleanup_samsung_ota_metadata "$quiet" || true
  fi
  block_samsung_packages "$quiet"
  block_wssync_fallback "$quiet"
  note_resolved_system_update_activity "$quiet"
}

scan_ota_packages(){
  echo "Installed packages matching OTA/update keywords:"
  pm list packages 2>/dev/null | cut -d: -f2 | grep -iE "ota|fota|update|updater|systemupdate|fotaclient|soagent|wssync|sdm|efota" | sort
}

scan_smart(){
  pm list packages 2>/dev/null | cut -d: -f2 | grep -iE "ota|fota|systemupdate|fotaclient|soagent|wssync|efota|romupdate|updater|updatecenter" | sort > "$SMART_SCAN_LIST"
  logi "Smart scan saved: $SMART_SCAN_LIST"
  cat "$SMART_SCAN_LIST"
}

block_smart_targets(){
  [ -f "$SMART_SCAN_LIST" ] || { logi "Smart block skipped: run scan-smart first"; return; }
  logi "WARNING: Applying user-requested Smart Block targets"
  while IFS= read -r p; do
    [ -n "$p" ] && disable_package_safely "$p"
  done < "$SMART_SCAN_LIST"
}

health_check(){
  clear_component_dump_cache
  detect_device
  echo "Vendor: $VENDOR"
  echo "Model: $MODEL"
  echo "Android: $RELEASE / SDK $SDK / One UI ${ONEUI:-none}"
  state="$(ifw_rule_state)"
  echo "Samsung Software update Intent Firewall rule: $state"
  logi "Health Intent Firewall rule: $state"
  if samsung_ota_cleanup_is_safe; then
    echo "OTA snapshot/recovery state: clear"
    logi "Health OTA snapshot/recovery state: clear"
  else
    echo "OTA snapshot/recovery state: present (metadata cleanup skipped)"
    logi "Health OTA snapshot/recovery state: present; metadata cleanup skipped"
  fi
  [ -e "$OTA_METADATA_FILE" ] && state="present" || state="absent"
  echo "OTA metadata: $state"
  logi "Health OTA metadata: $state"
  [ -e "$OTA_PAYLOAD_METADATA_FILE" ] && state="present" || state="absent"
  echo "OTA payload metadata: $state"
  logi "Health OTA payload metadata: $state"
  [ -e "$FOTA_UPDATE_ZIP" ] && state="present" || state="absent"
  echo "FOTA update.zip: $state"
  logi "Health FOTA update.zip: $state"
  state="$(fota_dir_state)"
  echo "FOTA data directory: $state"
  logi "Health FOTA data directory: $state"
  for p in $(samsung_ota_packages); do
    state="$(pkg_state "$p")"
    echo "Package $p: $state"
    logi "Health package $p: $state"
  done
  activity="$(resolve_system_update_activity)"
  if [ -z "$activity" ]; then
    echo "Resolved software-update activity: unavailable"
    logi "Health resolved software-update activity: unavailable"
  else
    echo "Resolved software-update activity: $activity"
    logi "Health resolved software-update activity: $activity"
  fi
  clear_component_dump_cache
}

write_json_report(){
  detect_device
  active=true
  [ -f "$DISABLE_FILE" ] && active=false
  dryrun=false
  [ -f "$DRYRUN_FILE" ] && dryrun=true
  smart_block=false
  [ -f "$SMART_BLOCK_FILE" ] && smart_block=true
  applied_count=0
  [ -f "$APPLIED_LIST" ] && applied_count="$(wc -l < "$APPLIED_LIST" | tr -d ' ')"
  smart_count=0
  [ -f "$SMART_SCAN_LIST" ] && smart_count="$(wc -l < "$SMART_SCAN_LIST" | tr -d ' ')"
  version="$(module_value version)"
  version_code="$(module_value versionCode)"
  case "$version_code" in
    ''|*[!0-9]*) version_code=0 ;;
  esac
  cat > "$REPORT_JSON" <<EOF
{"module":"Block Samsung OTA","version":"$(json_escape "$version")","versionCode":$version_code,"active":$active,"dryrun":$dryrun,"smart_block":$smart_block,"vendor":"$(json_escape "$VENDOR")","brand":"$(json_escape "$BRAND")","manufacturer":"$(json_escape "$MANUFACTURER")","model":"$(json_escape "$MODEL")","device":"$(json_escape "$DEVICE")","android_release":"$(json_escape "$RELEASE")","sdk":"$(json_escape "$SDK")","oneui":"$(json_escape "$ONEUI")","ab_ota":"$(json_escape "$AB_OTA")","slot":"$(json_escape "$SLOT")","ifw_rule":"$(json_escape "$(ifw_rule_state)")","applied_record_count":$applied_count,"smart_scan_count":$smart_count,"log":"$LOG"}
EOF
}

write_html_report(){
  write_json_report
  mkdir -p /sdcard/BlockSamsungOTA 2>/dev/null
  cat > "$REPORT_HTML" <<EOF
<!doctype html><html><head><meta charset="utf-8"><title>Block Samsung OTA</title><style>body{font-family:Arial;background:#111;color:#eee;padding:20px}.card{background:#1d1d1d;border-radius:12px;padding:16px;margin:12px 0}.ok{color:#6ee77a}.warn{color:#ffd166}pre{white-space:pre-wrap;background:#0b0b0b;padding:12px;border-radius:8px}</style></head><body><h1>Block Samsung OTA</h1><div class="card"><b>Vendor:</b> $VENDOR<br><b>Brand:</b> $BRAND<br><b>Manufacturer:</b> $MANUFACTURER<br><b>Model:</b> $MODEL<br><b>Android:</b> $RELEASE / SDK $SDK<br><b>One UI:</b> ${ONEUI:-none}<br><b>A/B OTA:</b> $AB_OTA</div><div class="card"><b>Status:</b> $( [ -f "$DISABLE_FILE" ] && echo '<span class="warn">PAUSED</span>' || echo '<span class="ok">ACTIVE</span>' )<br><b>Dry-run:</b> $( [ -f "$DRYRUN_FILE" ] && echo yes || echo no )<br><b>Smart block:</b> $( [ -f "$SMART_BLOCK_FILE" ] && echo armed || echo off )<br><b>Intent Firewall:</b> $(ifw_rule_state)</div><div class="card"><h2>Module-owned changes</h2><pre>$( [ -f "$APPLIED_LIST" ] && cat "$APPLIED_LIST" || echo none )</pre></div><div class="card"><h2>Smart scan targets</h2><pre>$( [ -f "$SMART_SCAN_LIST" ] && cat "$SMART_SCAN_LIST" || echo none )</pre></div><div class="card"><h2>Log tail</h2><pre>$( tail -n 80 "$LOG" 2>/dev/null )</pre></div></body></html>
EOF
  echo "$REPORT_HTML"
}

status_report(){
  detect_device
  write_json_report
  echo "Block Samsung OTA"
  echo "Vendor: $VENDOR"
  echo "Brand: $BRAND"
  echo "Manufacturer: $MANUFACTURER"
  echo "Model: $MODEL"
  echo "Android: $RELEASE / SDK $SDK / One UI ${ONEUI:-none}"
  echo "A/B OTA: $AB_OTA Slot: $SLOT"
  echo "Intent Firewall: $(ifw_rule_state)"
  [ -f "$DISABLE_FILE" ] && echo "Status: PAUSED" || echo "Status: ACTIVE"
  [ -f "$SMART_BLOCK_FILE" ] && echo "Smart block: ARMED (manual only)" || echo "Smart block: OFF"
  [ -f "$DRYRUN_FILE" ] && echo "Dry-run: ON" || echo "Dry-run: OFF"
  echo "JSON report: $REPORT_JSON"
  echo "HTML report: $REPORT_HTML"
  tail -n 30 "$LOG" 2>/dev/null
}

block_all(){
  quiet="${1:-false}"
  if [ -f "$DISABLE_FILE" ]; then
    remove_samsung_update_rule "$quiet" || true
    [ "$quiet" = true ] || { logi "Paused: $DISABLE_FILE exists"; write_json_report; }
    return 0
  fi
  detect_device
  if [ "$VENDOR" != "samsung" ]; then
    logi "Refusing OTA block: detected vendor=$VENDOR brand=$BRAND model=$MODEL. This module only changes Samsung."
    write_json_report
    return 1
  fi
  clear_component_dump_cache
  block_samsung "$quiet"
  if [ "$quiet" != true ]; then
    clear_component_dump_cache
    health_check >/dev/null
  fi
  clear_component_dump_cache
  [ "$quiet" = true ] || write_json_report
  [ "$quiet" = true ] || logi "Samsung OTA block cycle complete"
}

apply_boot_rules(){
  quiet="${1:-false}"
  detect_device
  if [ "$VENDOR" = "samsung" ]; then
    block_all "$quiet"
  else
    [ "$quiet" = true ] || logi "Boot auto-block skipped for vendor=$VENDOR; this module only blocks Samsung OTA"
    write_json_report
  fi
}

restore_all(){
  remove_samsung_update_rule || true
  pending="$STATE_DIR/applied.pending.$$"
  [ -f "$APPLIED_LIST" ] || { logi "No module-owned changes to restore"; write_json_report; return 0; }
  : > "$pending" || { logi "WARNING: Cannot create restore state file"; return 1; }
  while IFS='|' read -r kind target; do
    [ -n "$kind" ] || continue
    restored=false
    case "$kind" in
      component)
        if ! component_exists "$target"; then
          restored=true
          logi "Component no longer present; dropped restore record: $target"
        elif pm enable --user 0 "$target" >/dev/null 2>&1; then
          restored=true
          logi "Restored component user=0: $target"
        fi
        ;;
      package)
        if ! pkg_exists "$target"; then
          restored=true
          logi "Package no longer present; dropped restore record: $target"
        elif pm enable --user 0 "$target" >/dev/null 2>&1; then
          restored=true
          logi "Restored package user=0: $target"
        fi
        ;;
      *)
        restored=true
        logi "Dropped invalid restore record: $kind|$target"
        ;;
    esac
    if [ "$restored" = true ]; then
      :
    else
      echo "$kind|$target" >> "$pending"
      logi "WARNING: Restore failed; keeping record: $kind|$target"
    fi
  done < "$APPLIED_LIST"
  if [ -s "$pending" ]; then
    mv "$pending" "$APPLIED_LIST"
  else
    rm -f "$pending" "$APPLIED_LIST"
  fi
  clear_component_dump_cache
  write_json_report
  logi "Restore cycle complete"
}
