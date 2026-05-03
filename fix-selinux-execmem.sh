#!/usr/bin/env bash
# fix-selinux-execmem.sh
#
# Diagnose+fix for "python3[...]: could not allocate closure" when the plugin
# tries to register its dbus methods/signals.
#
# Cause: NetworkManager spawns the plugin in domain NetworkManager_t. The
# default openSUSE/Fedora targeted policy does NOT grant NetworkManager_t the
# 'execmem' process permission. dbus-python uses libffi to build trampoline
# closures, libffi calls mmap(... PROT_EXEC ...), the kernel asks SELinux,
# SELinux says no, the closure allocation fails, plugin silently can't emit
# SecretsRequired or any other signal, NM times out at 60-90s.
#
# Fix: install a local SELinux module granting NetworkManager_t execmem.
# Same shape as the earlier fix for charon-nm itself.
#
# Strategy:
#   1. Switch to permissive temporarily, trigger the activation that fails,
#      capture audit denials related to our plugin.
#   2. Run audit2allow on those denials to generate a minimal local module.
#   3. Show the .te, install if user confirms.
#   4. Restore enforcing.

set -uo pipefail

PROFILE="${VPN_PROFILE:-VPN_AMU_snx}"
MODULE=nm_snx_rs_local
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

if [[ $EUID -ne 0 ]]; then
    echo "Run as root: sudo bash $0" >&2
    exit 1
fi

export PATH="/usr/sbin:/sbin:$PATH"

for c in sestatus setenforce ausearch audit2allow semodule nmcli; do
    command -v "$c" >/dev/null \
        || { echo "Missing $c — install audit/policycoreutils*" >&2; exit 2; }
done

if ! sestatus | grep -q 'Loaded policy'; then
    echo "SELinux not enabled — nothing to fix." >&2; exit 0
fi

ORIG_MODE=$(getenforce 2>/dev/null || echo Enforcing)
echo "==> SELinux currently: $ORIG_MODE"

# ── 1. Permissive + drop pending plugins ───────────────────────────────────
echo
echo "==> 1. Permissive mode and clean plugin state"
setenforce 0
pkill -KILL -f /usr/libexec/nm-snx-rs-service     2>/dev/null || true
pkill -KILL -f /usr/libexec/nm-snx-rs-auth-dialog 2>/dev/null || true
pkill -KILL -x snx-rs                             2>/dev/null || true
nmcli connection down "$PROFILE" 2>/dev/null || true
sleep 1

MARK=$(date '+%H:%M:%S')
echo "    Mark: $MARK"

# ── 2. Trigger an activation; we don't care if it fully succeeds, we just
#     need the kernel to attempt the operations that get denied so audit
#     logs them.
echo
echo "==> 2. Trigger nmcli connection up (5..15s window typically enough)"
nmcli --wait 25 connection up "$PROFILE" 2>&1 | sed 's/^/    /' || true
sleep 3

# ── 3. Collect AVCs ────────────────────────────────────────────────────────
echo
echo "==> 3. Collect AVC denials related to the plugin"
RAW="$WORK/avc.raw"
ausearch -m AVC,USER_AVC -ts "$MARK" 2>/dev/null > "$RAW" || true

FILT="$WORK/avc.filt"
grep -E 'comm="(python3|nm-snx-rs|snx-rs)"|scontext=[^ ]*NetworkManager_t' "$RAW" > "$FILT" || true

COUNT=$(grep -c '^type=AVC' "$FILT" 2>/dev/null || echo 0)
echo "    Matching AVC events: $COUNT"
if [[ "$COUNT" -eq 0 ]]; then
    echo
    echo "    No AVC denials matched. Either the closure error is NOT SELinux"
    echo "    or our filter missed it. Showing raw AVCs since $MARK for review:"
    head -80 "$RAW" | sed 's/^/      /'
    echo
    echo "    Leaving SELinux permissive. Try the connection now to see if it"
    echo "    works; if it does, the cause IS SELinux but our filter was too"
    echo "    narrow. Restore with:  sudo setenforce 1"
    exit 3
fi

# ── 4. audit2allow ─────────────────────────────────────────────────────────
echo
echo "==> 4. Generate policy module: $MODULE"
cd "$WORK"
ausearch -m AVC,USER_AVC -ts "$MARK" 2>/dev/null \
    | audit2allow -M "$MODULE" >/dev/null

if [[ ! -f "${MODULE}.te" || ! -f "${MODULE}.pp" ]]; then
    echo "    audit2allow produced nothing." >&2
    exit 4
fi

echo "    Generated rules (${MODULE}.te):"
echo "    --------------------------------------------------------"
sed 's/^/      /' "${MODULE}.te"
echo "    --------------------------------------------------------"

read -r -p "    Install module? [t/N] " ANS
if [[ ! "${ANS:-}" =~ ^[tTyY]$ ]]; then
    echo "    Not installing. Restoring $ORIG_MODE."
    [[ "$ORIG_MODE" == "Enforcing" ]] && setenforce 1
    exit 0
fi

# ── 5. Install + restore enforcing + retest ────────────────────────────────
echo
echo "==> 5. Install module"
semodule -i "${MODULE}.pp"
semodule -l | grep "$MODULE" | sed 's/^/      /' || true

echo
echo "==> 6. Restore SELinux: $ORIG_MODE"
[[ "$ORIG_MODE" == "Enforcing" ]] && setenforce 1
echo "    Now: $(getenforce)"

cat <<EOF

============================================================================
 Done.

 Test:    nmcli connection up $PROFILE
 Verify:  ip -4 addr show snx-xfrm
 Logs:    sudo journalctl -t nm-snx-rs -f

 Re-running this script is safe — pass 1 may grant just the first denied
 op (e.g. execmem); the next attempt may hit a different one (e.g. execstack).
 Run again if needed to layer on more rules.

 Remove module:    sudo semodule -r $MODULE
 List modules:     sudo semodule -l | grep $MODULE
============================================================================
EOF
