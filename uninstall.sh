#!/usr/bin/env bash
# uninstall.sh — remove nm-snx-rs and its NM profile.
#
# Usage:
#   sudo bash uninstall.sh
#   sudo KEEP_PROFILE=1 bash uninstall.sh   # leave NM connection in place

set -euo pipefail

if [[ $EUID -ne 0 ]]; then
    echo "Run as root: sudo bash $0" >&2
    exit 1
fi

VPN_PROFILE="${VPN_PROFILE:-VPN_AMU_snx}"

LIBEXEC=/usr/libexec/nm-snx-rs-service
AUTH_DIALOG=/usr/libexec/nm-snx-rs-auth-dialog
NAME_FILE=/usr/lib/NetworkManager/VPN/nm-snx-rs-service.name
DBUS_POLICY=/etc/dbus-1/system.d/org.freedesktop.NetworkManager.snx-rs.conf

echo "==> Removing plugin files"
rm -fv "$LIBEXEC" "$AUTH_DIALOG" "$NAME_FILE" "$DBUS_POLICY"

echo "==> Reloading dbus / NetworkManager"
systemctl reload dbus 2>/dev/null || systemctl reload dbus-broker 2>/dev/null || true
systemctl reload NetworkManager 2>/dev/null || systemctl restart NetworkManager || true

if [[ "${KEEP_PROFILE:-0}" -ne 1 ]]; then
    if nmcli -t -f NAME connection show 2>/dev/null | grep -qx "$VPN_PROFILE"; then
        echo "==> Removing NM connection $VPN_PROFILE"
        nmcli connection delete "$VPN_PROFILE"
    fi
fi

echo
echo "Done. The snx-rs daemon is left in place; re-enable for CLI use with:"
echo "  sudo systemctl enable --now snx-rs.service"
