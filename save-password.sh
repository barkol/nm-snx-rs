#!/usr/bin/env bash
# save-password.sh — store the VPN password in NM and switch the connection
# to password-flags=0 so activation is silent from any UI path (Quick Settings
# tile, Settings → Network, nmcli, etc.).
#
# Why: GNOME 48's Quick Settings VPN tile has a partially-working secret-agent
# implementation that does not always invoke a third-party VPN's auth-dialog.
# Storing the password locally side-steps the prompt entirely.
#
# Security: the password lives in plaintext in
#   /etc/NetworkManager/system-connections/<profile>.nmconnection
# (mode 0600, owned by root). That's the same place NM stores any
# password-flags=0 secret. Acceptable on a personal device; not for shared
# kiosks.
#
# Usage:
#   bash save-password.sh                     # default profile VPN_AMU_snx
#   VPN_PROFILE=other_vpn bash save-password.sh

set -euo pipefail

PROFILE="${VPN_PROFILE:-VPN_AMU_snx}"

if ! nmcli -t -f NAME connection show 2>/dev/null | grep -qx "$PROFILE"; then
    echo "Connection '$PROFILE' not found. Run install.sh first." >&2
    exit 1
fi

read -r -s -p "VPN password for $PROFILE: " PASS
echo
[[ -z "$PASS" ]] && { echo "Aborted (empty password)." >&2; exit 1; }

# Use 'nmcli connection edit' interactive mode so the password is delivered
# via stdin, not via argv (where it would be visible in /proc/<pid>/cmdline).
nmcli connection edit "$PROFILE" <<EOF >/dev/null
set vpn.secrets password=$PASS
set vpn.data password-flags = 0
save
quit
EOF
unset PASS

echo
echo "Saved. Current state:"
nmcli -f vpn.data,vpn.secrets connection show "$PROFILE" \
    | grep -iE 'password-flags|secrets' | sed 's/^/  /'

cat <<EOF

Done. Both the Quick Settings VPN toggle and Settings → Network should now
activate '$PROFILE' silently — no password dialog.

To revert (go back to "always ask"):
  nmcli connection modify "$PROFILE" \\
        +vpn.data password-flags=2
  nmcli connection clear-secrets "$PROFILE"
EOF
