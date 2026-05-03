#!/usr/bin/env bash
# diagnose-60s-drop.sh — kill zombies, crank NM's VPN logging to DEBUG,
# reinstall the plugin, then capture an entire activation cycle so we can
# see exactly which NM check rejects our Config / Ip4Config and tears the
# tunnel down at the 60-second mark.
#
# Use:
#   bash diagnose-60s-drop.sh
#
# The script:
#   1. Kills any leftover plugin / auth-dialog / snx-rs processes from
#      previous runs.
#   2. Reinstalls /usr/libexec/nm-snx-rs-service from this repo (so the
#      latest has-ip4 / supervisor patch is in place).
#   3. Bumps NetworkManager's VPN log domain to DEBUG (runtime only, no
#      restart needed; reverts to the previous level at the end).
#   4. Starts capturing journal lines from nm-snx-rs and NetworkManager
#      to /tmp/vpn-drop-<timestamp>.log.
#   5. Asks you to trigger an activation (Quick Settings or Settings →
#      Network) and waits ~120 seconds, well past the 60-second drop.
#   6. Stops capture, restores log level, prints the most relevant slice
#      and the full file path for further inspection.

set -uo pipefail

LOG=/tmp/vpn-drop-$(date +%Y%m%d-%H%M%S).log
PROFILE="${VPN_PROFILE:-VPN_AMU_snx}"
WAIT_SECS="${WAIT_SECS:-130}"

if ! command -v sudo >/dev/null; then
    echo "sudo required" >&2; exit 1
fi

echo "==> 1. Killing leftover plugin/auth-dialog/snx-rs processes"
sudo bash -c '
    pkill -TERM -f /usr/libexec/nm-snx-rs-service       2>/dev/null
    pkill -TERM -f /usr/libexec/nm-snx-rs-auth-dialog   2>/dev/null
    pkill -x -TERM snx-rs                               2>/dev/null
    sleep 1
    pkill -KILL -f /usr/libexec/nm-snx-rs-service       2>/dev/null
    pkill -KILL -f /usr/libexec/nm-snx-rs-auth-dialog   2>/dev/null
'
pgrep -af 'nm-snx-rs|^snx-rs' || echo "  (clean)"

echo
echo "==> 2. Bringing connection down and reinstalling latest plugin"
nmcli connection down "$PROFILE" 2>/dev/null || true
sudo bash "$(dirname "$0")/install.sh" 2>&1 | tail -5

echo
echo "==> 3. Bumping NetworkManager VPN log level to DEBUG (runtime)"
PREV_LEVEL=$(nmcli general logging --fields LEVEL 2>/dev/null | tail -1 || echo "INFO")
sudo nmcli general logging level DEBUG domains VPN,VPN_PLUGIN

echo
echo "==> 4. Starting capture to $LOG"
sudo bash -c "journalctl -t nm-snx-rs -t NetworkManager-dispatcher \
                _COMM=NetworkManager _COMM=python3 _COMM=snx-rs \
                --since now -f --no-pager" \
    >> "$LOG" 2>&1 &
TAIL_PID=$!
sleep 2

cat <<EOF

==> 5. NOW activate the VPN

   • Quick Settings (top-right) → VPN → $PROFILE → On
   • or Settings → Network → $PROFILE → On
   • or:  nmcli connection up $PROFILE

   Capture will run for $WAIT_SECS seconds (well past the 60s drop window).
   Just wait. Do not interact with the terminal until it returns.

EOF

# Countdown so user knows it's working
for ((i = WAIT_SECS; i > 0; i -= 10)); do
    printf "    waiting... %ds left\r" "$i"
    sleep 10
done
echo

echo "==> 6. Stopping capture, restoring log level"
sudo kill "$TAIL_PID" 2>/dev/null || true
sudo nmcli general logging level "${PREV_LEVEL:-INFO}" domains VPN,VPN_PLUGIN \
    2>/dev/null || sudo nmcli general logging level INFO domains VPN,VPN_PLUGIN

echo
echo "==> 7. Highlights (most relevant lines from $LOG)"
echo "──────────────────────────────────────────────────────────────"
grep -E '(VPN|vpn|snx|state changed|secrets|ip-config|ip4-config|gateway|tundev|TIMEOUT|disconnect|Failure|fail|reject)' "$LOG" \
    | tail -120
echo "──────────────────────────────────────────────────────────────"

echo
echo "==> Done."
echo "    Full log:    $LOG"
echo "    Plugin tag:  grep nm-snx-rs $LOG"
echo "    NM only:     grep -i 'vpn\\[0x' $LOG"
echo
echo "    Paste the highlights block above (or the relevant chunk of the"
echo "    full log) so the next fix targets the actual NM rejection cause."
