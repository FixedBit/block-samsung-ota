#!/system/bin/sh
LOG="/data/local/tmp/block_samsung_ota.log"

# Package Manager is not reliable at post-fs-data time. The service script
# waits until Android has finished booting before it touches packages or the
# Intent Firewall directory.
echo "[$(date)] post-fs-data complete; Samsung OTA rules deferred until boot" >> "$LOG"
