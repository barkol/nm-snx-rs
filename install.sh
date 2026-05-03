#!/usr/bin/env bash
# install.sh — install nm-snx-rs and create the AMU VPN profile.
#
# Idempotent. Safe to re-run after editing the plugin source.
#
# Usage:
#   sudo bash install.sh                   # install + create AMU profile
#   sudo VPN_USER=login@amu.edu.pl bash install.sh
#   sudo SKIP_PROFILE=1 bash install.sh    # only install plugin

set -euo pipefail

if [[ $EUID -ne 0 ]]; then
    echo "Run as root: sudo bash $0" >&2
    exit 1
fi

REPO_DIR="$(cd "$(dirname "$0")" && pwd)"

# ── install paths ────────────────────────────────────────────────────────────
LIBEXEC=/usr/libexec/nm-snx-rs-service
AUTH_DIALOG=/usr/libexec/nm-snx-rs-auth-dialog
NAME_FILE=/usr/lib/NetworkManager/VPN/nm-snx-rs-service.name
DBUS_POLICY=/etc/dbus-1/system.d/org.freedesktop.NetworkManager.snx-rs.conf

# ── settings for the AMU profile ─────────────────────────────────────────────
VPN_PROFILE="${VPN_PROFILE:-VPN_AMU_snx}"
VPN_SERVER="${VPN_SERVER:-oivpn.amu.edu.pl}"
VPN_USER="${VPN_USER:-bark@amu.edu.pl}"
VPN_TUNNEL="${VPN_TUNNEL:-ipsec}"     # ipsec | ssl
VPN_IFNAME="${VPN_IFNAME:-snx-xfrm}"

INVOKER="${SUDO_USER:-}"
[[ -n "$INVOKER" ]] || INVOKER="$(logname 2>/dev/null || true)"

# ── 1. Pre-flight ────────────────────────────────────────────────────────────
echo "==> 1. Pre-flight"
[[ -x /usr/bin/snx-rs ]] || { echo "    /usr/bin/snx-rs not found — install snx-rs first" >&2; exit 2; }
command -v nmcli >/dev/null || { echo "    nmcli not found" >&2; exit 2; }
python3 -c 'import dbus, dbus.service, dbus.mainloop.glib; from gi.repository import GLib' \
    || { echo "    install python3-dbus + python3-gobject" >&2; exit 2; }

# ── 2. Install plugin files ──────────────────────────────────────────────────
echo "==> 2. Installing plugin files"
install -o root -g root -m 0755 "$REPO_DIR/src/nm-snx-rs-service"     "$LIBEXEC"
install -o root -g root -m 0755 "$REPO_DIR/src/nm-snx-rs-auth-dialog" "$AUTH_DIALOG"
install -d -o root -g root -m 0755 /usr/lib/NetworkManager/VPN
install -o root -g root -m 0644 "$REPO_DIR/data/nm-snx-rs-service.name" "$NAME_FILE"
install -o root -g root -m 0644 "$REPO_DIR/data/org.freedesktop.NetworkManager.snx-rs.conf" "$DBUS_POLICY"

# Reload D-Bus so the policy file is picked up.
systemctl reload dbus 2>/dev/null || systemctl reload dbus-broker 2>/dev/null || true

# Reload NetworkManager so it rescans /usr/lib/NetworkManager/VPN/.
systemctl reload NetworkManager 2>/dev/null || systemctl restart NetworkManager

# ── 3. Disable conflicting standalone snx-rs.service ─────────────────────────
echo "==> 3. Stopping/disabling snx-rs.service (NM plugin owns the tunnel now)"
if systemctl is-enabled --quiet snx-rs.service 2>/dev/null; then
    systemctl disable --now snx-rs.service 2>&1 | sed 's/^/    /'
else
    systemctl stop snx-rs.service 2>/dev/null || true
fi

# Tear down the legacy NetworkManager-strongswan profile if it exists,
# so it does not show up in the menu next to the new working one.
if nmcli -t -f NAME connection show 2>/dev/null | grep -qx VPN_UAM_checkpoint; then
    echo "    deleting old VPN_UAM_checkpoint (strongswan) profile"
    nmcli connection delete VPN_UAM_checkpoint 2>&1 | sed 's/^/    /' || true
fi

# ── 4. Create / refresh the AMU profile ──────────────────────────────────────
if [[ "${SKIP_PROFILE:-0}" -eq 1 ]]; then
    echo "==> 4. SKIP_PROFILE=1 — leaving NM connections alone"
else
    echo "==> 4. Creating NM VPN profile: $VPN_PROFILE  (server=$VPN_SERVER user=$VPN_USER)"

    # Preserve existing password-flags if the user previously ran
    # save-password.sh and chose 0 (saved). Default to 2 (always-ask) for
    # fresh installs.
    EXISTING_FLAGS=$(nmcli -t -f vpn.data connection show "$VPN_PROFILE" 2>/dev/null \
        | sed -nE 's/.*password-flags = ([0-9]+).*/\1/p')
    PWD_FLAGS="${EXISTING_FLAGS:-2}"

    if nmcli -t -f NAME connection show 2>/dev/null | grep -qx "$VPN_PROFILE"; then
        # Preserve secrets across the recreate by exporting and re-importing
        # them, but simpler: just keep the existing connection and update its
        # fields in place.
        nmcli connection modify "$VPN_PROFILE" \
            vpn.user-name "$VPN_USER" \
            vpn.data "server-name = $VPN_SERVER, login-type = vpn, tunnel-type = $VPN_TUNNEL, if-name = $VPN_IFNAME, password-flags = $PWD_FLAGS" \
            ipv4.method auto \
            ipv4.never-default true \
            ipv4.routes "${VPN_ROUTES:-150.254.0.0/16, 10.0.0.0/8, 62.3.161.0/24, 62.3.164.0/24, 172.29.0.0/16, 192.168.100.0/24}" \
            ipv6.method auto \
            connection.permissions "${INVOKER:+user:$INVOKER}"
    else
        nmcli connection add \
            type vpn \
            con-name "$VPN_PROFILE" \
            vpn-type org.freedesktop.NetworkManager.snx-rs \
            ifname "--" \
            autoconnect no >/dev/null
        nmcli connection modify "$VPN_PROFILE" \
            vpn.user-name "$VPN_USER" \
            vpn.data "server-name = $VPN_SERVER, login-type = vpn, tunnel-type = $VPN_TUNNEL, if-name = $VPN_IFNAME, password-flags = $PWD_FLAGS" \
            ipv4.method auto \
            ipv4.never-default true \
            ipv4.routes "${VPN_ROUTES:-150.254.0.0/16, 10.0.0.0/8, 62.3.161.0/24, 62.3.164.0/24, 172.29.0.0/16, 192.168.100.0/24}" \
            ipv6.method auto \
            connection.permissions "${INVOKER:+user:$INVOKER}"
    fi

    echo "    profile saved:"
    nmcli -f connection.id,connection.type,vpn.service-type,vpn.data \
          connection show "$VPN_PROFILE" 2>&1 | sed 's/^/      /'
fi

# ── 5. Done ──────────────────────────────────────────────────────────────────
cat <<EOF

============================================================================
 nm-snx-rs installed.

 Connect (will prompt once for VPN password — save in keyring if you like):
   nmcli --ask connection up $VPN_PROFILE
 …or click the GNOME network indicator → VPN → $VPN_PROFILE.

 Live status:    nmcli connection show --active
 Tunnel:         ip -4 addr show $VPN_IFNAME
 Plugin logs:    sudo journalctl -t nm-snx-rs -f
 Uninstall:      sudo bash $REPO_DIR/uninstall.sh

 You can override defaults next time:
   sudo VPN_USER=login@amu.edu.pl VPN_TUNNEL=ssl bash install.sh
============================================================================
EOF
