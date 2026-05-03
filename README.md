# nm-snx-rs

NetworkManager VPN plugin that wraps [snx-rs](https://github.com/ancwrd1/snx-rs),
the Rust client for Check Point VPN gateways. Lets you connect a Check Point
"Mobile Access" / IPsec or SSL tunnel from the standard NetworkManager UI
(GNOME quick‑settings, `nmcli`, KDE Plasma's network applet, etc.) instead of
running `snxctl` and a separate tray app.

## Why this exists

Check Point gateways speak a proprietary mix of IPsec and TLS‑wrapped IKE/ESP
("Visitor Mode" on TCP/443) that strongSwan and the bundled
`NetworkManager-strongswan` plugin cannot handle. snx-rs reverse‑engineered
that protocol; this plugin lets NetworkManager drive snx-rs, so the resulting
tunnel shows up in the OS networking UI like any other VPN.

The plugin spawns a per‑connection `snx-rs` subprocess in standalone mode,
waits for it to bring up the `snx-xfrm` interface, reads the assigned IPv4,
reports the config back to NM via the standard
`org.freedesktop.NetworkManager.VPN.Plugin` D‑Bus interface, and tears the
subprocess down on `Disconnect`.

## Supplied components

```
nm-snx-rs/
├── src/nm-snx-rs-service                       # Python plugin daemon
├── data/nm-snx-rs-service.name                 # NM plugin descriptor
├── data/org.freedesktop.NetworkManager.snx-rs.conf  # D-Bus policy
├── examples/VPN_AMU_snx.nmconnection           # Example NM connection profile
├── install.sh                                  # Installer (also creates the AMU profile)
└── uninstall.sh
```

## Requirements

- Linux with NetworkManager ≥ 1.30
- snx-rs ≥ 6.0 (`/usr/bin/snx-rs`, `/usr/bin/snxctl`)
- Python 3.10+ with `dbus-python` and `python3-gobject`
- D‑Bus, `iproute2`

Tested on openSUSE Leap 16 / GNOME Shell 48 / Wayland.

## Install

```bash
git clone https://github.com/<you>/nm-snx-rs ~/git/nm-snx-rs
cd ~/git/nm-snx-rs
sudo bash install.sh
```

The installer:

1. Copies the plugin to `/usr/libexec/nm-snx-rs-service`.
2. Installs the NM plugin descriptor `nm-snx-rs-service.name`.
3. Installs the D‑Bus policy and reloads dbus + NetworkManager.
4. Stops and disables the standalone `snx-rs.service` (the plugin owns the
   tunnel now; if you still want CLI use, re‑enable with
   `sudo systemctl enable --now snx-rs.service`).
5. Creates an NM VPN connection `VPN_AMU_snx` for AMU's gateway
   (`oivpn.amu.edu.pl`, user `bark@amu.edu.pl` by default — override with
   `VPN_USER=` env).

## Use

```
nmcli --ask connection up VPN_AMU_snx
```

Or click the network indicator → **VPN** → **VPN_AMU_snx**. NM prompts for
the VPN password (you can tick "remember" to store in the keyring).

The connection appears with normal NM state in `nmcli connection show
--active`, and GNOME's network panel shows it as a connected VPN.

```
nmcli connection up   VPN_AMU_snx        # start
nmcli connection down VPN_AMU_snx        # stop
ip -4 addr show snx-xfrm                 # see the assigned address
sudo journalctl -t nm-snx-rs -f          # live plugin logs
```

## Known issue: GNOME 48 Quick Settings tile doesn't prompt for password

GNOME Shell 48's Quick Settings VPN tile (top‑right panel) has a partial
secret‑agent implementation and does not always invoke this plugin's
auth‑dialog. Symptoms:

- Click the VPN toggle in Quick Settings → nothing happens, no dialog.
- Open **Settings → Network → VPN_AMU_snx → toggle on** → the password
  dialog appears and the connection works.

Two fixes:

1. **Use Settings → Network instead of Quick Settings.** Annoying but works.
2. **Save the password into the connection** (one time):
   ```
   bash ~/git/nm-snx-rs/save-password.sh
   ```
   After this, both Quick Settings and Settings → Network activate the
   connection silently with no dialog. The password is stored in
   `/etc/NetworkManager/system-connections/VPN_AMU_snx.nmconnection`
   (mode 0600, root‑only) just like any other `password-flags=0` NM
   secret. Revert any time with the commands the script prints.

## Configuring a different gateway

The connection profile carries everything snx-rs needs in `vpn.data`:

| key            | meaning                                          | default      |
|----------------|--------------------------------------------------|--------------|
| `server-name`  | gateway hostname                                 | (required)   |
| `user-name`    | login (e.g. `bark@amu.edu.pl`)                  | (required)   |
| `login-type`   | snx-rs login type (`vpn`, `microsoft_authenticator`, etc.) | `vpn`     |
| `tunnel-type`  | `ipsec` (Check Point IPsec) or `ssl` (TCP/443)  | `ipsec`      |
| `if-name`      | TUN/XFRM interface name                          | `snx-xfrm`   |

`password-flags` controls how NM stores the secret (`0`=save, `2`=ask each
time). Edit with `nmcli connection modify <name> vpn.data "key = val, …"` or
through your network UI.

To create a profile for a different gateway from scratch:

```
sudo VPN_PROFILE=VPN_corp \
     VPN_SERVER=vpn.corp.example.com \
     VPN_USER=alice@corp \
     VPN_TUNNEL=ssl \
     bash install.sh
```

## Uninstall

```
sudo bash uninstall.sh
# add KEEP_PROFILE=1 to leave the NM connection in place
```

## License

MIT.

## Acknowledgements

- [ancwrd1/snx-rs](https://github.com/ancwrd1/snx-rs) — the actual Check Point
  client doing all the protocol heavy lifting.
- NetworkManager VPN plugin authors (strongswan, openvpn, openconnect) whose
  D‑Bus surface this plugin emulates.
