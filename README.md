# nm-snx-rs

NetworkManager VPN plugin that wraps [snx-rs](https://github.com/ancwrd1/snx-rs),
the unofficial Rust client for Check Point VPN gateways. Lets you connect a
Check Point "Mobile Access" / IPsec or SSL tunnel from the standard
NetworkManager UI (GNOME quick‑settings, `nmcli`, KDE Plasma's network
applet, etc.) instead of running `snxctl` and a separate tray app.

## Why this exists

Check Point gateways speak a proprietary mix of IPsec and TLS‑wrapped IKE/ESP
("Visitor Mode" on TCP/443) that strongSwan and the bundled
`NetworkManager-strongswan` plugin cannot handle. snx‑rs reverse‑engineered
that protocol; this plugin lets NetworkManager drive snx‑rs, so the resulting
tunnel shows up in the OS networking UI like any other VPN.

The plugin spawns a per‑connection `snx-rs` subprocess in standalone mode,
waits for it to bring up the `snx-xfrm` interface, reads the assigned IPv4,
reports the config back to NM via the standard
`org.freedesktop.NetworkManager.VPN.Plugin` D‑Bus interface, and tears the
subprocess down on `Disconnect`. A supervisor thread emits
`Failure` to NM cleanly if snx‑rs dies mid‑tunnel (rekey failure, network
drop, etc.) so the connection state in NM stays in sync with reality.

## Repository layout

```
nm-snx-rs/
├── src/nm-snx-rs-service                          # Python plugin daemon
├── src/nm-snx-rs-auth-dialog                      # GNOME secret-agent companion
├── data/nm-snx-rs-service.name                    # NM plugin descriptor
├── data/org.freedesktop.NetworkManager.snx-rs.conf # D-Bus policy
├── examples/VPN_AMU_snx.nmconnection              # Example NM connection profile
├── install.sh                                     # Installer (also creates an AMU profile)
├── uninstall.sh
├── save-password.sh                               # Switch profile to silent activation
├── diag.sh                                        # One-shot diagnostic dump
└── fix-selinux-execmem.sh                         # Grant NetworkManager_t the execmem dbus-python needs
```

## Requirements

- Linux with NetworkManager ≥ 1.30
- snx‑rs ≥ 6.0 (`/usr/bin/snx-rs`, `/usr/bin/snxctl`)
- Python 3.10+ with `dbus-python` and `python3-gobject`
- D‑Bus, `iproute2`
- On openSUSE/Fedora‑style targeted SELinux: `policycoreutils` and
  `python3-systemd` (for proper journal logging)

Tested on openSUSE Leap 16, GNOME Shell 48 / Wayland, snx‑rs v6.0.4,
NetworkManager 1.52.

## Install

```bash
git clone https://github.com/barkol/nm-snx-rs ~/git/nm-snx-rs
cd ~/git/nm-snx-rs
sudo bash install.sh
```

The installer:

1. Copies the plugin to `/usr/libexec/nm-snx-rs-service`.
2. Copies the auth‑dialog to `/usr/libexec/nm-snx-rs-auth-dialog`.
3. Installs the NM plugin descriptor (`/usr/lib/NetworkManager/VPN/nm-snx-rs-service.name`).
4. Installs the D‑Bus policy and reloads dbus + NetworkManager.
5. Stops and disables the standalone `snx-rs.service` (the plugin owns the
   tunnel now; if you also want CLI use, re‑enable with
   `sudo systemctl enable --now snx-rs.service`).
6. Removes any leftover dead `VPN_UAM_checkpoint` strongSwan profile.
7. Creates an NM VPN connection `VPN_AMU_snx` for AMU's gateway
   (`oivpn.amu.edu.pl`, user `bark@amu.edu.pl` by default — override with
   env vars, see below). Idempotent: if the profile exists, fields are
   updated in place and existing `password-flags` / saved secrets are
   preserved.

## Use

```
nmcli --ask connection up VPN_AMU_snx
```

Or click the network indicator → **VPN** → **VPN_AMU_snx** (Settings →
Network for the most reliable prompt; see Known issues below for Quick
Settings). NM prompts for the VPN password (you can tick "remember" to store
in the keyring).

The connection appears with normal NM state in `nmcli connection show
--active`, and GNOME's network panel shows it as a connected VPN.

```
nmcli connection up   VPN_AMU_snx        # start
nmcli connection down VPN_AMU_snx        # stop
ip -4 addr show snx-xfrm                 # see the assigned address
sudo journalctl -t nm-snx-rs -f          # live plugin logs
bash diag.sh                             # one-shot full diagnostic dump
```

## Configuring a different gateway

The connection profile carries everything snx‑rs needs:

| field          | meaning                                          | default      |
|----------------|--------------------------------------------------|--------------|
| `vpn.user-name`| login (e.g. `bark@amu.edu.pl`)                  | (required)   |
| `server-name`  | gateway hostname                                 | (required)   |
| `login-type`   | snx‑rs login type (`vpn`, `microsoft_authenticator`, etc.) | `vpn`     |
| `tunnel-type`  | `ipsec` (Check Point IPsec) or `ssl` (TCP/443)  | `ipsec`      |
| `if-name`      | TUN/XFRM interface name                          | `snx-xfrm`   |

`vpn.user-name` lives at the top level of `[vpn]` in the connection (NM
filters unknown keys out of `vpn.data`); the rest go into `vpn.data`.
`password-flags` controls how NM stores the secret (`0`=save, `2`=ask each
time, `4`=not‑required). Edit with `nmcli connection modify <name>`
or through your network UI.

To create a profile for a different gateway from scratch:

```
sudo VPN_PROFILE=VPN_corp \
     VPN_SERVER=vpn.corp.example.com \
     VPN_USER=alice@corp \
     VPN_TUNNEL=ssl \
     VPN_ROUTES="10.0.0.0/8, 192.168.0.0/16" \
     bash install.sh
```

The default AMU split-tunnel routes are
`150.254.0.0/16, 10.0.0.0/8, 62.3.161.0/24, 62.3.164.0/24, 172.29.0.0/16, 192.168.100.0/24`
(from AMU's published prefix list). For full‑tunnel mode set
`ipv4.never-default no` after install.

## Known issues

### GNOME 48 Quick Settings tile doesn't prompt for password

GNOME Shell 48's Quick Settings VPN tile (top‑right panel) has a partial
secret‑agent implementation and does not always invoke this plugin's
auth‑dialog.

- Click the VPN toggle in Quick Settings → nothing happens, no dialog.
- Open **Settings → Network → VPN_AMU_snx → toggle on** → the password
  dialog appears and the connection works.

Two fixes:

1. **Use Settings → Network instead of Quick Settings.** Annoying but works.
2. **Save the password into the connection** (one time):
   ```
   bash save-password.sh
   ```
   After this, both Quick Settings and Settings → Network activate the
   connection silently with no dialog. The password is stored in
   `/etc/NetworkManager/system-connections/VPN_AMU_snx.nmconnection`
   (mode 0600, root‑only) just like any other `password-flags=0` NM
   secret. Revert any time with the commands the script prints.

### "Connection failed at ~60 s" with `python3[…]: could not allocate closure`

On distros with SELinux targeted policy (openSUSE Leap 16, Fedora,
RHEL/CentOS, Rocky, Alma…) the plugin runs as `NetworkManager_t`, which by
default lacks the `execmem` permission that libffi needs to build dbus
trampolines. The plugin can't emit any D‑Bus signals, NM never gets a
secrets/Ip4Config response, and the connection is killed by NM's IP‑config
timeout at ~60 s. Symptom in journal:

```
python3[<pid>]: could not allocate closure
```

Fix:

```
sudo bash fix-selinux-execmem.sh
```

The script flips SELinux to permissive momentarily, triggers an activation
to make the kernel log every needed denial, runs `audit2allow -M nm_snx_rs_local`
on the captured AVCs, shows you the generated `.te`, installs the module,
and restores enforcing. Idempotent: rerun if a second layer of denials gets
revealed once the first set is allowed.

### snx-xfrm interface label

NM may show the device as "unmanaged" (`snx-xfrm:xfrm:unmanaged`) — this is
fine, the plugin reports IP/routes through the VPN D‑Bus interface so NM
manages the connection logically without managing the kernel device.

## Troubleshooting

```
bash diag.sh                          # whole-system snapshot
sudo journalctl -t nm-snx-rs -f       # live plugin log
sudo journalctl -t NetworkManager --since '5 minutes ago' | grep -iE 'vpn|snx'
```

## Uninstall

```
sudo bash uninstall.sh
# add KEEP_PROFILE=1 to leave the NM connection in place
```

To also remove the SELinux module installed by `fix-selinux-execmem.sh`:

```
sudo semodule -r nm_snx_rs_local
```

## License

MIT — see `LICENSE`.

## Acknowledgements

- [ancwrd1/snx-rs](https://github.com/ancwrd1/snx-rs) — the actual Check Point
  client doing all the protocol heavy lifting.
- NetworkManager VPN plugin authors (strongSwan, OpenVPN, OpenConnect, vpnc,
  l2tp) whose D‑Bus surface and auth‑dialog protocol this plugin emulates.
