# Fedora Package

Native RPM packages for Fedora (and RHEL-family distros with matching
dependency versions). One spec builds two packages:

| Package | Contents |
|---------|----------|
| `draytek-vpn-standalone` | GTK4 GUI app + Polkit-elevated helper |
| `draytek-vpn-networkmanager` | NetworkManager plugin (service, editors, auth-dialog) + tray |

## Build & install

```bash
# Build dependencies + rpmbuild
./install_dependencies.sh all
sudo dnf install rpm-build

# Build both RPMs (from the repo root)
./build.sh fedora
# → target/rpm/RPMS/x86_64/draytek-vpn-{standalone,networkmanager}-0.1.0-1.*.rpm

# Or build + install in one shot
./build.sh fedora install
```

Like the Arch package, the RPMs are built from the surrounding git checkout —
`build_rpm.sh` archives the working tree into a source tarball under
`target/rpm/SOURCES/` and runs `rpmbuild` with `_topdir` pointed at
`target/rpm/`, so nothing touches `~/rpmbuild`.

## What it installs

### draytek-vpn-networkmanager

| File | Path |
|------|------|
| VPN service daemon | `/usr/lib/NetworkManager/nm-draytek-service` |
| Editor plugin (base + GTK3 + GTK4) | `/usr/lib64/NetworkManager/libnm-*draytek*.so` |
| Auth dialog | `/usr/libexec/nm-draytek-auth-dialog` |
| NM service registration | `/usr/lib/NetworkManager/VPN/nm-draytek-service.name` |
| D-Bus system policy | `/usr/share/dbus-1/system.d/nm-draytek-service.conf` |
| Tray binary | `/usr/bin/draytek-vpn-tray` |
| XDG autostart entry (tray runs on session login) | `/etc/xdg/autostart/draytek-vpn-tray.desktop` |

Note the split: the service binary and `.name` file live in the
arch-independent `/usr/lib/NetworkManager` (matching the `program=` path in
the `.name` file), while the editor `.so` files live in Fedora's
arch-dependent `/usr/lib64/NetworkManager`, where libnm resolves the bare
`plugin=` name. The spec passes `NM_PLUGIN_DIR=/usr/lib64/NetworkManager`
to the editor Makefile so the compiled-in editor lookup path matches.

NetworkManager is restarted automatically on install/upgrade/remove via RPM
scriptlets.

### draytek-vpn-standalone

| File | Path |
|------|------|
| GUI app | `/usr/bin/draytek-vpn` |
| Privileged helper | `/usr/lib/draytek-vpn/draytek-vpn-helper` |
| Polkit policy | `/usr/share/polkit-1/actions/com.draytek.vpn.policy` |
| Desktop entry | `/usr/share/applications/draytek-vpn.desktop` |

The helper stays in `/usr/lib` (not `/usr/lib64`) because both the Polkit
policy and the app's helper lookup hardcode
`/usr/lib/draytek-vpn/draytek-vpn-helper`.

## SELinux

Fedora runs SELinux enforcing by default. The NM service binary installs
with the default context, which works on stock Fedora Workstation setups.
If the VPN fails to connect and `journalctl -u NetworkManager` shows
permission errors, check for AVC denials:

```bash
sudo ausearch -m avc -ts recent
```

If denials appear, confirm SELinux is the cause with
`sudo setenforce 0` (re-enable with `setenforce 1` afterwards) and report
an issue with the `ausearch` output so a proper policy module can be added.

## Tray visibility

Same as on other distros: the tray uses the StatusNotifierItem (SNI) D-Bus
protocol. GNOME needs the AppIndicator extension
(`gnome-shell-extension-appindicator`); KDE works out of the box; minimal
Wayland compositors need a bar with an SNI host (e.g. waybar's `tray`
module). Without an SNI host the VPN still works; you just won't see the
indicator.

## Uninstall

```bash
sudo dnf remove draytek-vpn-standalone draytek-vpn-networkmanager
```
