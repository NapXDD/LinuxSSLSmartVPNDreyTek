# RPM spec for the DrayTek SSL VPN client.
#
# Produces two binary packages from one source build:
#   draytek-vpn-standalone      — GTK4/libadwaita GUI app + polkit helper
#   draytek-vpn-networkmanager  — NM plugin (service, editors, auth-dialog) + tray
#
# Built from the surrounding git checkout via packaging/fedora/build_rpm.sh
# (or ./build.sh fedora), which creates the source tarball and drives rpmbuild.

# Rust release binaries carry no split debuginfo; skip debuginfo subpackages.
%global debug_package %{nil}

Name:           draytek-vpn
Version:        0.1.0
Release:        1%{?dist}
Summary:        DrayTek SSL VPN client for Linux
License:        GPL-3.0-only
URL:            https://github.com/julianjc84/draytek-ssl-vpn-client-linux
Source0:        %{name}-%{version}.tar.gz

BuildRequires:  rust
BuildRequires:  cargo
BuildRequires:  gcc
BuildRequires:  make
BuildRequires:  pkgconf-pkg-config
BuildRequires:  gtk4-devel
BuildRequires:  gtk3-devel
BuildRequires:  libadwaita-devel
BuildRequires:  openssl-devel
BuildRequires:  NetworkManager-libnm-devel
BuildRequires:  glib2-devel

%description
Native Linux SSL VPN client for DrayTek routers, speaking the same protocol
as the official Windows Smart VPN Client (TLS 1.2, HTTP CONNECT, SSTP
framing, PPP with PAP/MS-CHAPv2, IPv4 tunnel over TUN).

This is the source package; install draytek-vpn-standalone and/or
draytek-vpn-networkmanager.

%package standalone
Summary:        DrayTek SSL VPN standalone GTK4 application
Requires:       polkit
%description standalone
Standalone GTK4/libadwaita application for managing DrayTek SSL VPN
connections. Network operations run in a separate helper elevated via
Polkit, so the GUI itself stays unprivileged.

%package networkmanager
Summary:        DrayTek SSL VPN NetworkManager plugin (service, editor, auth-dialog, tray)
Requires:       NetworkManager
%description networkmanager
Integrates DrayTek SSL VPN into NetworkManager so VPN connections appear
in GNOME Settings, KDE, Cinnamon, or any NM frontend. Includes a system
tray indicator that autostarts on session login.

%prep
%autosetup

%build
cargo build --release --locked

# Force clean rebuild of C components. The Makefiles don't track config
# changes (e.g. NM_PLUGIN_DIR), so cached .so files from a prior build
# could otherwise ship with the wrong embedded paths.
make -C networkmanager/editor clean
make -C networkmanager/editor NM_PLUGIN_DIR=%{_libdir}/NetworkManager
make -C networkmanager/auth-dialog clean
make -C networkmanager/auth-dialog

%install
# ── standalone ────────────────────────────────────────────────────
install -Dm755 target/release/draytek-vpn \
    %{buildroot}%{_bindir}/draytek-vpn
# Helper path is fixed: both the polkit policy and the app's helper lookup
# hardcode /usr/lib/draytek-vpn/draytek-vpn-helper (not %%{_libdir}).
install -Dm755 target/release/draytek-vpn-helper \
    %{buildroot}%{_prefix}/lib/draytek-vpn/draytek-vpn-helper
install -Dm644 standalone/data/com.draytek.vpn.policy \
    %{buildroot}%{_datadir}/polkit-1/actions/com.draytek.vpn.policy
install -Dm644 standalone/data/draytek-vpn.desktop \
    %{buildroot}%{_datadir}/applications/draytek-vpn.desktop

# ── networkmanager ────────────────────────────────────────────────
# Service binary path must match program= in nm-draytek-service.name
# (/usr/lib/NetworkManager, arch-independent on Fedora).
install -Dm755 target/release/draytek-vpn-nm \
    %{buildroot}%{_prefix}/lib/NetworkManager/nm-draytek-service

# Editor plugins go in the arch-dependent NM plugin dir (lib64), where
# libnm resolves the bare plugin= name from the .name file.
install -Dm755 networkmanager/editor/libnm-vpn-plugin-draytek.so \
    %{buildroot}%{_libdir}/NetworkManager/libnm-vpn-plugin-draytek.so
install -Dm755 networkmanager/editor/libnm-vpn-plugin-draytek-editor.so \
    %{buildroot}%{_libdir}/NetworkManager/libnm-vpn-plugin-draytek-editor.so
install -Dm755 networkmanager/editor/libnm-gtk4-vpn-plugin-draytek-editor.so \
    %{buildroot}%{_libdir}/NetworkManager/libnm-gtk4-vpn-plugin-draytek-editor.so

# Auth dialog — path must match [GNOME] auth-dialog= in
# networkmanager/data/nm-draytek-service.name (/usr/libexec).
install -Dm755 networkmanager/auth-dialog/nm-draytek-auth-dialog \
    %{buildroot}%{_libexecdir}/nm-draytek-auth-dialog

# NM VPN service registration
install -Dm644 networkmanager/data/nm-draytek-service.name \
    %{buildroot}%{_prefix}/lib/NetworkManager/VPN/nm-draytek-service.name

# System D-Bus policy
install -Dm644 networkmanager/data/nm-draytek-service.conf \
    %{buildroot}%{_datadir}/dbus-1/system.d/nm-draytek-service.conf

# Tray binary + XDG autostart entry
install -Dm755 target/release/draytek-vpn-tray \
    %{buildroot}%{_bindir}/draytek-vpn-tray
install -Dm644 networkmanagertray/data/draytek-vpn-tray.desktop \
    %{buildroot}%{_sysconfdir}/xdg/autostart/draytek-vpn-tray.desktop

%post networkmanager
# Clean up the old NM dispatcher script from prior versions, which used to
# launch/kill the tray on vpn-up/vpn-down.
rm -f /etc/NetworkManager/dispatcher.d/90-draytek-vpn-tray
# NetworkManager.service uses KillMode=process: restarting NM leaves an
# already-running VPN service process alive holding the D-Bus name, so NM
# would keep talking to the old binary. Kill it so the new one is spawned.
pkill -f '^%{_prefix}/lib/NetworkManager/nm-draytek-service' 2>/dev/null || :
# Restart NetworkManager to pick up the new plugin
if systemctl is-active --quiet NetworkManager; then
    systemctl restart NetworkManager || :
fi

%preun networkmanager
# Kill any running tray instances on full removal (not upgrade)
if [ $1 -eq 0 ]; then
    pkill -f draytek-vpn-tray 2>/dev/null || :
fi

%postun networkmanager
# Kill any lingering VPN service process (NM's KillMode=process leaves it
# running across restarts) and restart NetworkManager to unload the plugin.
pkill -f '^%{_prefix}/lib/NetworkManager/nm-draytek-service' 2>/dev/null || :
if systemctl is-active --quiet NetworkManager; then
    systemctl restart NetworkManager || :
fi

%files standalone
%license LICENSE
%doc README.md
%{_bindir}/draytek-vpn
%dir %{_prefix}/lib/draytek-vpn
%{_prefix}/lib/draytek-vpn/draytek-vpn-helper
%{_datadir}/polkit-1/actions/com.draytek.vpn.policy
%{_datadir}/applications/draytek-vpn.desktop

%files networkmanager
%license LICENSE
%doc README.md
%{_prefix}/lib/NetworkManager/nm-draytek-service
%{_libdir}/NetworkManager/libnm-vpn-plugin-draytek.so
%{_libdir}/NetworkManager/libnm-vpn-plugin-draytek-editor.so
%{_libdir}/NetworkManager/libnm-gtk4-vpn-plugin-draytek-editor.so
%{_libexecdir}/nm-draytek-auth-dialog
%{_prefix}/lib/NetworkManager/VPN/nm-draytek-service.name
%{_datadir}/dbus-1/system.d/nm-draytek-service.conf
%{_bindir}/draytek-vpn-tray
%config(noreplace) %{_sysconfdir}/xdg/autostart/draytek-vpn-tray.desktop

%changelog
* Mon Aug 31 2026 Julian <julian@jc84.com> - 0.1.0-1
- Initial Fedora packaging: standalone app and NetworkManager plugin + tray
