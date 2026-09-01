#!/usr/bin/env bash
set -euo pipefail

# Containerized smoke test: build, install, and NM-registration of the
# Fedora RPMs inside a Fedora 44 container. Validates everything short of
# a live VPN session — a real DrayTek gateway is not reachable from CI,
# so `nmcli connection up` is only attempted when credentials are
# exported (DRAYTEK_GATEWAY/DRAYTEK_USERNAME/DRAYTEK_PASSWORD).
#
# For the full connect + internet-ping test on real hardware, use
# tests/e2e/e2e-fedora.sh instead.
#
# The Fedora base image has no systemd, so D-Bus and NetworkManager are
# started directly — this keeps the test runnable under both podman and
# docker (CONTAINER_ENGINE=docker) without a systemd-enabled image.
#
# Usage:
#   tests/e2e/podman-smoke.sh [--keep]
#
#   --keep   Leave the container running afterwards for inspection

# Git Bash (MSYS) rewrites POSIX-looking arguments passed to native
# Windows executables — podman.exe would receive /root/src as
# C:/Program Files/Git/root/src. Disable the conversion; both variables
# are ignored everywhere else.
export MSYS_NO_PATHCONV=1
export MSYS2_ARG_CONV_EXCL='*'

ENGINE="${CONTAINER_ENGINE:-podman}"
IMAGE="${FEDORA_IMAGE:-registry.fedoraproject.org/fedora:44}"
NAME="draytek-e2e-smoke"
KEEP=0
[ "${1:-}" = "--keep" ] && KEEP=1

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

# Credentials/settings from tests/e2e/e2e.env (gitignored; copy
# e2e.env.example). Env vars override the file. See e2e-fedora.sh.
E2E_ENV_VARS=(DRAYTEK_GATEWAY DRAYTEK_USERNAME DRAYTEK_PASSWORD
              DRAYTEK_PORT DRAYTEK_VERIFY_CERT DRAYTEK_CA_CERT
              DRAYTEK_DEFAULT_ROUTE PING_TARGET)
ENV_FILE="${E2E_ENV_FILE:-$SCRIPT_DIR/e2e.env}"
if [ -f "$ENV_FILE" ]; then
    _saved=""
    for _v in "${E2E_ENV_VARS[@]}"; do
        [ -n "${!_v:-}" ] && _saved+="$(printf '%s=%q\n' "$_v" "${!_v}")"$'\n'
    done
    # shellcheck source=/dev/null
    . "$ENV_FILE"
    eval "$_saved"
    echo "Loaded config from $ENV_FILE"
fi

# A relative DRAYTEK_CA_CERT resolves against the env-file directory (the
# README says to run from the repo root, but the cert lives next to e2e.env).
if [ -n "${DRAYTEK_CA_CERT:-}" ] && [ ! -f "$DRAYTEK_CA_CERT" ] \
        && [ -f "$SCRIPT_DIR/$DRAYTEK_CA_CERT" ]; then
    DRAYTEK_CA_CERT="$SCRIPT_DIR/$DRAYTEK_CA_CERT"
fi

BOLD='\033[1m'; GREEN='\033[0;32m'; NC='\033[0m'
step() { echo -e "\n${BOLD}── $* ──${NC}"; }
run()  { "$ENGINE" exec "$NAME" bash -c "$*"; }

cleanup() {
    if [ "$KEEP" = 0 ]; then
        "$ENGINE" rm -f "$NAME" &>/dev/null || true
    else
        echo "Container '$NAME' kept running ($ENGINE exec -it $NAME bash)"
    fi
}
trap cleanup EXIT

step "Start Fedora container ($IMAGE)"
"$ENGINE" rm -f "$NAME" &>/dev/null || true
"$ENGINE" run -d --name "$NAME" --privileged "$IMAGE" sleep infinity

step "Copy source tree into the container"
run "mkdir -p /root/src"
# tar streaming instead of `$ENGINE cp dir/.`: podman cp on a Windows
# host copies the directory itself rather than its contents, nesting
# the tree one level deep. Excluding target/ and .git/ up front also
# avoids shipping build artifacts into the container.
tar -C "$PROJECT_DIR" --exclude=target --exclude=.git -cf - . \
    | "$ENGINE" exec -i "$NAME" tar -C /root/src -xf -

step "Install build dependencies + NetworkManager"
run "dnf install -y --setopt=install_weak_deps=False \
    rust cargo gcc make pkgconf-pkg-config \
    gtk4-devel gtk3-devel libadwaita-devel openssl-devel \
    NetworkManager-libnm-devel glib2-devel \
    rpm-build gawk tar gzip \
    NetworkManager dbus-daemon iputils iproute procps-ng"

step "Build RPMs (packaging/fedora/build_rpm.sh)"
# Low parallelism: container hosts (CI, podman machine) are often
# memory-constrained and rustc + thin-LTO is memory-hungry.
run "cd /root/src && CARGO_BUILD_JOBS=\${CARGO_BUILD_JOBS:-2} bash packaging/fedora/build_rpm.sh"

step "Install RPMs"
run 'dnf install -y /root/src/target/rpm/RPMS/$(uname -m)/draytek-vpn-*.rpm'

step "Start D-Bus + NetworkManager"
# Keep NM's hands off the container's own interface, and skip the
# systemd-notify handshake (no systemd in the container).
run "printf '[keyfile]\nunmanaged-devices=interface-name:eth0\n' > /etc/NetworkManager/conf.d/e2e-unmanaged.conf"
# --no-daemon with a log file: the container has no journald/syslog, so
# a daemonized NM would log into the void — and VPN failures surface in
# nmcli as just "Unknown reason".
run "mkdir -p /run/dbus && (dbus-daemon --system --fork || true) && (setsid /usr/sbin/NetworkManager --no-daemon &>/var/log/nm.log &) && sleep 2"
run "nmcli general status"

step "Verify plugin registration"
run "test -f /usr/lib/NetworkManager/VPN/nm-draytek-service.name && echo '.name file installed'"
run "test -x /usr/lib/NetworkManager/nm-draytek-service && echo 'service binary installed'"
run 'test -f $(rpm --eval "%{_libdir}")/NetworkManager/libnm-vpn-plugin-draytek.so && echo "editor plugin installed"'
run "test -e /dev/net/tun && echo '/dev/net/tun present'"

# Creating a connection with our service type only succeeds if NM parsed
# the .name file — this IS the registration check. nmcli resolves the
# short name "draytek" against installed .name files (the option is
# vpn-type; older docs said vpn-service-type, which Fedora 44 rejects).
# never-default=no = Smart VPN "use default gateway on remote network"
NEVER_DEFAULT="yes"; [ "${DRAYTEK_DEFAULT_ROUTE:-no}" = "yes" ] && NEVER_DEFAULT="no"
run "nmcli connection add type vpn ifname '*' con-name smoke \
    vpn-type draytek \
    vpn.data 'gateway=${DRAYTEK_GATEWAY:-vpn.invalid},port=${DRAYTEK_PORT:-443},username=${DRAYTEK_USERNAME:-smoke},verify-cert=${DRAYTEK_VERIFY_CERT:-yes},never-default=${NEVER_DEFAULT}'"
run "nmcli -f connection.id,vpn.service-type,vpn.data connection show smoke"

if [ -n "${DRAYTEK_GATEWAY:-}" ] && [ -n "${DRAYTEK_PASSWORD:-}" ]; then
    step "Connect + ping (credentials provided)"
    # Routers with a self-signed certificate fail verify-cert=yes against
    # the system trust store — and cannot be added to it: they are leaf
    # certs (no CA:TRUE), which p11-kit refuses to extract into the
    # bundle. The plugin's ca-cert option pins the PEM directly instead.
    if [ -n "${DRAYTEK_CA_CERT:-}" ]; then
        [ -f "$DRAYTEK_CA_CERT" ] || { echo "DRAYTEK_CA_CERT not found: $DRAYTEK_CA_CERT" >&2; exit 2; }
        "$ENGINE" exec -i "$NAME" bash -c \
            'cat > /root/draytek-ca.pem' \
            < "$DRAYTEK_CA_CERT"
        run "nmcli connection modify smoke +vpn.data ca-cert=/root/draytek-ca.pem"
        echo "Pinned DRAYTEK_CA_CERT ($DRAYTEK_CA_CERT) via vpn.data ca-cert"
    fi
    # NM refuses to activate a VPN without an NM-owned source connection,
    # and in a udev-less container all devices are strictly unmanaged.
    # Run udevd, then re-own eth0 with a static profile matching its
    # current podman-assigned address.
    run "dnf install -y -q systemd-udev && /usr/lib/systemd/systemd-udevd --daemon && udevadm trigger && udevadm settle || true"
    # Drop the unmanaged-devices conf from the registration phase — NM
    # must own eth0 to serve as the VPN's source connection.
    run "rm -f /etc/NetworkManager/conf.d/e2e-unmanaged.conf"
    run "pkill NetworkManager; sleep 1; (setsid /usr/sbin/NetworkManager --no-daemon &>>/var/log/nm.log &); sleep 3"
    run 'IP=$(ip -o -4 addr show eth0 | awk "{print \$4}"); GW=$(ip route | awk "/default/ {print \$3}"); \
         nmcli connection add type ethernet ifname eth0 con-name base ipv4.method manual ipv4.addresses "$IP" ipv4.gateway "$GW" ipv4.dns 8.8.8.8 && \
         nmcli connection up base'
    run "nmcli connection modify smoke vpn.secrets 'password=${DRAYTEK_PASSWORD}'"
    if ! run "nmcli --wait 60 connection up smoke"; then
        echo "── connect failed — NetworkManager log tail ──" >&2
        run "tail -n 120 /var/log/nm.log" >&2 || true
        exit 1
    fi
    run "ip -o -4 addr show; ip route"
    run "VPN_IP=\$(nmcli -g IP4.ADDRESS connection show smoke | head -n1 | cut -d/ -f1); \
         TUN_IF=\$(ip -o -4 addr show | awk -v ip=\"\$VPN_IP\" '\$4 ~ \"^\"ip\"(/|$)\" {print \$2; exit}'); \
         echo \"tunnel: \$TUN_IF (\$VPN_IP)\"; \
         echo \"route to ${PING_TARGET:-8.8.8.8}: \$(ip route get ${PING_TARGET:-8.8.8.8} | head -n1)\"; \
         ping -c 4 -W 5 -I \"\$TUN_IF\" ${PING_TARGET:-8.8.8.8}"
    if [ "$NEVER_DEFAULT" = "no" ]; then
        run "ping -c 4 -W 5 ${PING_TARGET:-8.8.8.8}"   # plain ping must ride the VPN default route
    fi
    run "nmcli connection down smoke"
else
    echo "(no DRAYTEK_GATEWAY/DRAYTEK_PASSWORD exported — skipping live connect)"
fi

echo -e "\n${GREEN}Smoke test passed.${NC}"
