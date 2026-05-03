#!/usr/bin/env bash
# diagnose-60s-drop.sh — auto-triggers a VPN activation with NetworkManager
# at DEBUG, records EVERYTHING to disk, then prints the relevant slice.
#
# Use:
#   bash diagnose-60s-drop.sh
#
# Requirements:
#   - VPN profile already configured (default: VPN_AMU_snx)
#   - Password saved in the profile (password-flags=0) so no prompt
#     interactive dance is needed. Run save-password.sh first if not.

set -uo pipefail

PROFILE="${VPN_PROFILE:-VPN_AMU_snx}"
WAIT_SECS="${WAIT_SECS:-90}"
STAMP=$(date +%Y%m%d-%H%M%S)
LOG=/tmp/vpn-drop-$STAMP.log
NM_LOG=/tmp/nm-monitor-$STAMP.log
NMCLI_LOG=/tmp/nmcli-result-$STAMP.txt

# ── 0. Pre-flight ────────────────────────────────────────────────────────────
if ! nmcli -t -f NAME connection show 2>/dev/null | grep -qx "$PROFILE"; then
    echo "Connection '$PROFILE' not found." >&2; exit 1
fi
echo "==> Authenticating sudo upfront"
sudo -v

# ── 1. Clean slate ───────────────────────────────────────────────────────────
echo "==> 1. Cleanup leftover processes / connections"
sudo pkill -KILL -f /usr/libexec/nm-snx-rs-service     2>/dev/null
sudo pkill -KILL -f /usr/libexec/nm-snx-rs-auth-dialog 2>/dev/null
sudo pkill -KILL -x snx-rs                             2>/dev/null
nmcli connection down "$PROFILE" 2>/dev/null
sleep 2
pgrep -af 'nm-snx-rs|^snx-rs' || echo "  (clean)"

# ── 2. Latest plugin code ────────────────────────────────────────────────────
echo
echo "==> 2. Reinstall plugin (latest code from this checkout)"
sudo bash "$(dirname "$0")/install.sh" 2>&1 | tail -3

# ── 3. NM debug logging ─────────────────────────────────────────────────────
echo
echo "==> 3. NetworkManager VPN+DEVICE logging -> DEBUG"
PREV_LEVEL=$(nmcli general logging | awk 'NR==2 {print $1}')
sudo nmcli general logging level DEBUG domains VPN,VPN_PLUGIN,DEVICE,IP4

# ── 4. Background capture ───────────────────────────────────────────────────
echo
echo "==> 4. Start journal + nmcli monitor capture"
# stdbuf -o0 -e0 disables stdio buffering so logs hit disk immediately.
sudo bash -c "stdbuf -o0 -e0 journalctl -f --no-pager --since now \
        -o short-iso PRIORITY=7 PRIORITY=6 PRIORITY=5 PRIORITY=4 PRIORITY=3 \
        > '$LOG' 2>&1" &
JCTL_PID=$!

stdbuf -o0 nmcli monitor > "$NM_LOG" 2>&1 &
NMM_PID=$!

sleep 2

# ── 5. Trigger activation ───────────────────────────────────────────────────
echo
echo "==> 5. Trigger:  nmcli --wait $WAIT_SECS connection up $PROFILE"
nmcli --wait "$WAIT_SECS" connection up "$PROFILE" > "$NMCLI_LOG" 2>&1 &
NMCLI_PID=$!

echo "    Waiting up to ${WAIT_SECS}s for activation result..."
wait "$NMCLI_PID" 2>/dev/null
RC=$?
echo "    nmcli returned rc=$RC after $(($(date +%s) - $(stat -c %Y "$NMCLI_LOG")))s"
echo "    nmcli output:"
sed 's/^/      /' "$NMCLI_LOG"

# ── 6. Let the supervisor / state settle for a moment ───────────────────────
echo
echo "==> 6. Continuing capture for 15s to catch post-activation state changes"
sleep 15

# ── 7. Stop captures, restore logging ───────────────────────────────────────
echo
echo "==> 7. Stop captures, restore log level"
sudo kill "$JCTL_PID" 2>/dev/null
kill "$NMM_PID"   2>/dev/null
sleep 1
sudo nmcli general logging level "${PREV_LEVEL:-INFO}" domains VPN,VPN_PLUGIN,DEVICE,IP4 \
    2>/dev/null || sudo nmcli general logging level INFO

# ── 8. Quick post-mortem ────────────────────────────────────────────────────
echo
echo "==> 8. Sizes:"
ls -la "$LOG" "$NM_LOG" "$NMCLI_LOG"

echo
echo "──────────────────── nmcli monitor events ────────────────────"
cat "$NM_LOG"
echo "──────────────────────────────────────────────────────────────"

echo
echo "──────────────────── VPN-relevant journal lines ──────────────"
grep -iE 'snx|VPN_AMU|vpn[ \[:]|state.*(chang|trans)|secret|ip4-config|ip-config|gateway|tundev|disconnect|fail|reject|timeout' "$LOG" \
  | head -200
echo "──────────────────────────────────────────────────────────────"

echo
echo "==> Done. Full files:"
echo "    $LOG"
echo "    $NM_LOG"
echo "    $NMCLI_LOG"
echo
echo "    Paste the 'nmcli monitor events' block + the 'VPN-relevant"
echo "    journal lines' block above. The line where NM transitions"
echo "    out of 'ip-config' is the smoking gun."
