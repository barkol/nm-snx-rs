#!/usr/bin/env bash
# test-with-saved-password.sh
#
# Diagnostyczny: zabija zawieszone procesy, instaluje brakujące zależności,
# reinstaluje wtyczkę, a następnie WPISUJE HASŁO BEZPOŚREDNIO do profilu NM
# (password-flags=0) i próbuje połączyć się BEZ pośrednictwa agenta sekretów.
# Dzięki temu izolujemy: czy wtyczka + snx-rs działają, czy problem leży w
# obsłudze haseł przez nmcli --ask / GNOME secret agent.
#
# WAŻNE: hasło zostanie zapisane plain-text w /etc/NetworkManager/system-connections/.
# Po teście (działa lub nie) skrypt OFERUJE przywrócenie password-flags=2.
#
# Uruchomienie:  bash ~/git/nm-snx-rs/test-with-saved-password.sh

set -uo pipefail

PROFILE="${VPN_PROFILE:-VPN_AMU_snx}"

# ── 1. Czyszczenie ──────────────────────────────────────────────────────────
echo "==> 1. Sprzątam wcześniejsze zawieszone procesy / połączenia"
pkill -INT -f "nmcli.*${PROFILE}"        2>/dev/null || true
pkill -TERM -f "nm-snx-rs-service"       2>/dev/null || true
sleep 1
nmcli connection down "${PROFILE}"        2>/dev/null || true
sudo pkill -TERM -f "snx-rs"             2>/dev/null || true
sleep 1
echo "    aktualne procesy snx-rs:"
pgrep -af snx-rs 2>&1 | sed 's/^/      /' || echo "      (brak)"

# ── 2. Doinstaluj python313-systemd (dla -t nm-snx-rs w journalctl) ─────────
echo
echo "==> 2. Instaluję python313-systemd (do logów wtyczki w journalu)"
if python3 -c 'from systemd.journal import JournalHandler' 2>/dev/null; then
    echo "    (już zainstalowany)"
else
    sudo zypper --non-interactive install python313-systemd 2>&1 | tail -5
fi

# ── 3. Reinstaluj wtyczkę ───────────────────────────────────────────────────
echo
echo "==> 3. Reinstaluję wtyczkę"
sudo bash ~/git/nm-snx-rs/install.sh 2>&1 | tail -10

# ── 4. Pobierz hasło i wpisz do profilu ─────────────────────────────────────
echo
echo "==> 4. Wpisuję hasło VPN bezpośrednio do profilu (TEST)"
read -r -s -p "    Hasło VPN UAM (bark@amu.edu.pl): " VPN_PASS
echo
[[ -z "$VPN_PASS" ]] && { echo "    Pominięto (puste hasło). Wyjście." >&2; exit 1; }

# Zapisz hasło i ustaw flags=0 (saved). Cudzysłowy + escape, żeby przeszło bez kombinacji.
nmcli connection modify "${PROFILE}" \
    vpn.secrets "password=${VPN_PASS}" \
    +vpn.data   "password-flags=0"
unset VPN_PASS

echo "    flagi i obecność hasła:"
nmcli -f vpn.data,vpn.secrets connection show "${PROFILE}" | sed 's/^/      /'

# ── 5. Live tail loga wtyczki w tle ─────────────────────────────────────────
echo
echo "==> 5. Tłem włączam live-tail loga wtyczki (PID zostanie pokazany)"
sudo journalctl -t nm-snx-rs -f --no-pager &
TAIL_PID=$!
sleep 1

# ── 6. Próba połączenia ─────────────────────────────────────────────────────
echo
echo "==> 6. Łączę: nmcli connection up ${PROFILE}"
nmcli connection up "${PROFILE}" 2>&1 | tee /tmp/nmcli-up.out
RC=$?

sleep 3
echo
echo "==> 7. Stan po próbie"
ip -o link show 2>&1 | grep -iE 'tun|xfrm|snx' | sed 's/^/    /' || echo "    (brak interfejsu tunelu)"
ip -4 addr show snx-xfrm 2>/dev/null | sed 's/^/    /' || true

# ── 8. Sprzątanie tail-a ────────────────────────────────────────────────────
sleep 2
sudo kill "$TAIL_PID" 2>/dev/null || true
wait "$TAIL_PID" 2>/dev/null || true

# ── 9. Oferta przywrócenia bezpiecznych ustawień ────────────────────────────
echo
echo "==> 9. Czyszczenie hasła z profilu"
read -r -p "    Wyczyścić hasło i wrócić do password-flags=2? [T/n] " ANS
ANS="${ANS:-T}"
if [[ "$ANS" =~ ^[TtYy]$ ]]; then
    nmcli connection modify "${PROFILE}" \
        +vpn.data "password-flags=2" \
        -vpn.secrets password 2>/dev/null || \
        nmcli connection modify "${PROFILE}" \
            +vpn.data "password-flags=2" \
            vpn.secrets ""
    echo "    OK — hasło wyczyszczone, flagi przywrócone."
else
    echo "    Hasło pozostaje zapisane w /etc/NetworkManager/system-connections/${PROFILE}.nmconnection"
fi

echo
echo "============================================================"
if [[ $RC -eq 0 ]]; then
    echo " WYNIK: nmcli zwrócił 0. Sprawdź:  ip -4 addr show snx-xfrm"
    echo "        Jeśli interfejs jest UP -> wtyczka i snx-rs działają,"
    echo "        a poprzedni FREEZE to wina tylko obsługi haseł."
else
    echo " WYNIK: nmcli zwrócił $RC. Wklej powyższe + zawartość /tmp/nmcli-up.out"
    echo "        oraz log z punktu 5 (wyświetlał się live)."
fi
echo "============================================================"
