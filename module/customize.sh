#!/system/bin/sh
# KernelSU extracts ZIP entries as non-executable. Mark only module programs
# and lifecycle scripts executable; data files remain root-readable only.
chmod 0755 "$MODPATH/service.sh" "$MODPATH/uninstall.sh" "$MODPATH/action.sh" \
  "$MODPATH/scripts/server.sh" "$MODPATH/bin/wireguard-go" "$MODPATH/bin/wgctl" "$MODPATH/bin/wgpanel"
# Mutable data intentionally lives outside $MODPATH because KernelSU replaces
# that directory during an in-place ZIP update.
mkdir -p /data/adb/wireguard-server-ksu
chmod 0700 /data/adb/wireguard-server-ksu
