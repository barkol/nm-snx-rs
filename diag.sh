#!/usr/bin/env bash
# diag.sh — zbiera diagnostykę nm-snx-rs / snx-rs po próbie połączenia.
#
# Wymaga sudo (czytanie systemowego journala). Wszystkie wywołania, które
# wymagają roota, są wewnątrz jednego sudo, żeby pytać o hasło tylko raz.
#
# Uruchomienie:  bash ~/git/nm-snx-rs/diag.sh
#                bash ~/git/nm-snx-rs/diag.sh 10        # ostatnie 10 minut

set -u

PROFILE="${VPN_PROFILE:-VPN_AMU_snx}"
IFACE="${VPN_IFACE:-snx-xfrm}"
MINUTES="${1:-5}"
SINCE="${MINUTES} minutes ago"

bar() { printf '\n=== %s ===\n' "$*"; }

bar "A. Profil w NM (zapisany)"
nmcli -f connection.id,connection.permissions,vpn.user-name,vpn.data,vpn.secrets,ipv4.routes,ipv4.never-default,ipv4.dns,ipv4.method \
    connection show "$PROFILE" 2>&1 | head -25

bar "B. Aktywne połączenia"
nmcli connection show --active 2>&1

bar "C. Wszystkie interfejsy TUN/XFRM/SNX"
ip -o link show 2>&1 | grep -iE 'tun|xfrm|snx' || echo "  (brak)"

bar "D. Adresy IPv4 na tych interfejsach"
for IF in $(ip -o link show 2>/dev/null | awk -F': ' '/tun|xfrm|snx/{print $2}' | cut -d@ -f1); do
    echo "  ── $IF ──"
    ip -4 -o addr show dev "$IF" 2>&1 | sed 's/^/    /' || true
done
[[ -z "$IF" ]] && echo "  (brak)"

bar "E. Trasy w głównej tablicy"
ip route 2>&1

bar "F. Trasa do amurap.amu.edu.pl (150.254.65.110)"
ip route get 150.254.65.110 2>&1

bar "G. DNS i resolv.conf"
cat /etc/resolv.conf 2>&1
echo "---"
command -v resolvectl >/dev/null && resolvectl status 2>&1 | head -25 || echo "  (brak resolvectl)"

bar "H. Procesy snx-rs"
pgrep -af 'snx-rs|nm-snx-rs' 2>&1 || echo "  (brak)"

bar "I. Pliki wtyczki na dysku"
ls -laZ /usr/libexec/nm-snx-rs-service \
        /usr/lib/NetworkManager/VPN/nm-snx-rs-service.name \
        /etc/dbus-1/system.d/org.freedesktop.NetworkManager.snx-rs.conf 2>&1

# ── Logi (sudo) ──────────────────────────────────────────────────────────────
bar "J/K/L. Logi (sudo)"
echo "Pytam o hasło sudo dla journalctl..."
sudo -p "[sudo] hasło: " bash -s <<EOF
echo
echo '── J. Log wtyczki nm-snx-rs (ostatnie ${MINUTES} min) ──'
journalctl -t nm-snx-rs --since '${SINCE}' --no-pager 2>/dev/null | tail -60 \
    || echo '  (brak logów)'

echo
echo '── K. Log NetworkManagera dla VPN (ostatnie ${MINUTES} min) ──'
journalctl _COMM=NetworkManager --since '${SINCE}' --no-pager 2>/dev/null \
    | grep -iE 'vpn|snx|${PROFILE}' | tail -40 \
    || echo '  (brak logów)'

echo
echo '── L. Polkit / błędy uwierzytelniania (ostatnie ${MINUTES} min) ──'
journalctl --since '${SINCE}' --no-pager 2>/dev/null \
    | grep -iE 'polkit|FAILED to authenticate' | tail -10 \
    || echo '  (brak)'
EOF

bar "M. snxctl status (jeśli daemon działa)"
snxctl status 2>&1 | head -20

bar "Gotowe"
echo "Skopiuj WSZYSTKO powyżej i wklej w odpowiedzi."
