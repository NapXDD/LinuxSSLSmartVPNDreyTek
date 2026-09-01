#!/usr/bin/env bash
set -uo pipefail

# End-to-end test for the DrayTek SSL VPN NetworkManager plugin on Fedora.
# Targets the Fedora KDE spin (Plasma), but the network path is
# desktop-agnostic — it works on any Fedora with NetworkManager.
#
# SELinux is expected to be Enforcing (the Fedora default): the preflight
# records the mode, and phase 4 fails on any AVC denial involving the
# plugin — even in permissive mode, where the connection may succeed but
# the same denial would break enforcing hosts.
#
# Phases:
#   1. Preflight    — OS, tools, /dev/net/tun, SELinux mode
#   2. Build        — build + install RPMs (./build.sh fedora install)
#   3. Registration — installed files, NM VPN service type visible, no
#                     stale plugin process from a previous install
#   4. Connect      — create test connection, nmcli connection up,
#                     SELinux AVC denial scan
#   5. Ping         — ping the internet through the tunnel
#   6. Teardown     — connection down + delete
#
# Phases 4-5 need a reachable DrayTek router. Credentials come from
# tests/e2e/e2e.env (copy e2e.env.example and fill it in; gitignored) or
# from the environment — env vars override the file. Without credentials
# the script runs phases 1-3 and reports the rest as SKIP
# (registration-only mode), exiting 0 if those pass.
#
#   DRAYTEK_GATEWAY      VPN server host/IP     (required for connect/ping)
#   DRAYTEK_USERNAME     VPN username           (required for connect/ping)
#   DRAYTEK_PASSWORD     VPN password           (required for connect/ping)
#   DRAYTEK_PORT         default 443
#   DRAYTEK_VERIFY_CERT  default yes
#   DRAYTEK_CA_CERT      PEM file pinned via the plugin's ca-cert option
#                        (keeps verify-cert=yes working with a self-signed
#                        router cert; the system trust store can't hold
#                        those — p11-kit only extracts CA certificates)
#   PING_TARGET          default 8.8.8.8  (must be routable via the VPN —
#                        internet ping requires the router to forward
#                        tunnel traffic upstream; use an internal host
#                        behind the router otherwise)
#   PING_COUNT           default 4
#   CONNECT_TIMEOUT      default 60 (seconds for nmcli connection up)
#
# Usage:
#   cp tests/e2e/e2e.env.example tests/e2e/e2e.env   # then fill it in
#   tests/e2e/e2e-fedora.sh
#
# or without a config file:
#   DRAYTEK_GATEWAY=vpn.example.com DRAYTEK_USERNAME=u DRAYTEK_PASSWORD=p \
#       tests/e2e/e2e-fedora.sh
#
# Flags:
#   --skip-build        Test the already-installed plugin (skip phase 2)
#   --keep-connection   Leave the test connection configured after the run

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

# ── Config file ───────────────────────────────────────────────────
# Credentials and settings can live in tests/e2e/e2e.env (gitignored;
# copy e2e.env.example). Variables already set in the environment take
# precedence over the file. Override the path with E2E_ENV_FILE.
E2E_ENV_VARS=(DRAYTEK_GATEWAY DRAYTEK_USERNAME DRAYTEK_PASSWORD
              DRAYTEK_PORT DRAYTEK_VERIFY_CERT DRAYTEK_CA_CERT
              DRAYTEK_DEFAULT_ROUTE PING_TARGET PING_COUNT CONNECT_TIMEOUT)
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

CON_NAME="draytek-e2e-test"
SERVICE_TYPE="org.freedesktop.NetworkManager.draytek"

DRAYTEK_PORT="${DRAYTEK_PORT:-443}"
DRAYTEK_VERIFY_CERT="${DRAYTEK_VERIFY_CERT:-yes}"
DRAYTEK_DEFAULT_ROUTE="${DRAYTEK_DEFAULT_ROUTE:-no}"
# Smart VPN "use default gateway on remote network": never-default=no
# routes ALL traffic through the tunnel.
NEVER_DEFAULT="yes"; [ "$DRAYTEK_DEFAULT_ROUTE" = "yes" ] && NEVER_DEFAULT="no"
PING_TARGET="${PING_TARGET:-8.8.8.8}"
PING_COUNT="${PING_COUNT:-4}"
CONNECT_TIMEOUT="${CONNECT_TIMEOUT:-60}"

SKIP_BUILD=0
KEEP_CONNECTION=0
for arg in "$@"; do
    case "$arg" in
        --skip-build)      SKIP_BUILD=1 ;;
        --keep-connection) KEEP_CONNECTION=1 ;;
        *) echo "Unknown flag: $arg" >&2; exit 2 ;;
    esac
done

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; BOLD='\033[1m'; NC='\033[0m'
PASS=0; FAIL=0; SKIP=0
pass() { echo -e "${GREEN}  PASS${NC} $*"; PASS=$((PASS+1)); }
fail() { echo -e "${RED}  FAIL${NC} $*"; FAIL=$((FAIL+1)); }
skip() { echo -e "${YELLOW}  SKIP${NC} $*"; SKIP=$((SKIP+1)); }
phase(){ echo -e "\n${BOLD}── Phase $* ──${NC}"; }

START_TS="$(date '+%Y-%m-%d %H:%M:%S')"
HAVE_CREDS=1
[ -z "${DRAYTEK_GATEWAY:-}" ] || [ -z "${DRAYTEK_USERNAME:-}" ] || [ -z "${DRAYTEK_PASSWORD:-}" ] && HAVE_CREDS=0

dump_nm_journal() {
    echo -e "${YELLOW}── NetworkManager journal since test start ──${NC}"
    sudo journalctl -u NetworkManager --since "$START_TS" --no-pager 2>/dev/null | tail -n 80 || true
}

# AVC denials involving the plugin since test start. The plugin runs in
# NetworkManager_t (spawned by NM), so SELinux vetoes — e.g. tun_socket
# relabelfrom on TUN attach — show up under that context even though the
# process is root. ausearch is authoritative; journalctl's audit transport
# is the fallback when the audit tools aren't installed.
scan_avc_denials() {
    if command -v ausearch &>/dev/null; then
        sudo ausearch -m avc -ts "$(date -d "$START_TS" '+%m/%d/%Y')" \
            "$(date -d "$START_TS" '+%H:%M:%S')" 2>/dev/null
    else
        sudo journalctl _TRANSPORT=audit --since "$START_TS" --no-pager 2>/dev/null
    fi | grep -E 'avc: *denied' | grep -Ei 'NetworkManager|tun_socket|draytek'
}

CONNECTED=0
cleanup() {
    if [ "$CONNECTED" = 1 ]; then
        nmcli connection down "$CON_NAME" &>/dev/null || true
    fi
    if [ "$KEEP_CONNECTION" = 0 ]; then
        nmcli connection delete "$CON_NAME" &>/dev/null || true
    fi
}
trap cleanup EXIT

# ── Phase 1: Preflight ────────────────────────────────────────────
phase "1: Preflight"

if grep -qi fedora /etc/os-release 2>/dev/null; then
    pass "Running on $(. /etc/os-release && echo "$PRETTY_NAME")"
else
    fail "Not a Fedora system (continuing anyway)"
fi

if command -v nmcli &>/dev/null && nmcli general status &>/dev/null; then
    pass "NetworkManager is running (nmcli reachable)"
else
    fail "NetworkManager not available — cannot continue"
    exit 1
fi

if [ -e /dev/net/tun ]; then
    pass "/dev/net/tun present"
else
    fail "/dev/net/tun missing — kernel TUN support required"
fi

if [ "${XDG_CURRENT_DESKTOP:-}" ]; then
    pass "Desktop session: ${XDG_CURRENT_DESKTOP} (KDE expected for tray checks)"
else
    skip "No desktop session detected — tray checks will be skipped"
fi

SELINUX_MODE="$(getenforce 2>/dev/null || echo Unavailable)"
case "$SELINUX_MODE" in
    Enforcing)  pass "SELinux enforcing (the mode the plugin must survive on Fedora)" ;;
    Permissive) skip "SELinux permissive — denials are logged but not enforced; run enforcing for full coverage" ;;
    *)          skip "SELinux $SELINUX_MODE — AVC checks will not exercise the policy" ;;
esac

# ── Phase 2: Build + install ──────────────────────────────────────
phase "2: Build + install RPMs"

if [ "$SKIP_BUILD" = 1 ]; then
    skip "Build skipped (--skip-build); testing installed plugin"
else
    if (cd "$PROJECT_DIR" && ./build.sh fedora install); then
        pass "RPMs built and installed"
    else
        fail "RPM build/install failed"
        exit 1
    fi
fi

# ── Phase 3: Registration ─────────────────────────────────────────
phase "3: Installed files + NM registration"

check_file() {
    if [ -e "$1" ]; then pass "$1"; else fail "missing: $1"; fi
}
check_file /usr/lib/NetworkManager/nm-draytek-service
check_file /usr/lib/NetworkManager/VPN/nm-draytek-service.name
check_file "$(rpm --eval '%{_libdir}')/NetworkManager/libnm-vpn-plugin-draytek.so"
check_file /usr/libexec/nm-draytek-auth-dialog
check_file /usr/share/dbus-1/system.d/nm-draytek-service.conf
check_file /usr/bin/draytek-vpn-tray
check_file /etc/xdg/autostart/draytek-vpn-tray.desktop

# NetworkManager.service uses KillMode=process, so a VPN service process
# from before the (re)install can survive NM restarts, hold the D-Bus name,
# and keep serving connections with the old binary. The install scripts now
# kill it; verify none is left running a deleted executable.
STALE_PID="$(pgrep -f '^/usr/lib/NetworkManager/nm-draytek-service' | head -n1 || true)"
if [ -n "$STALE_PID" ] && sudo readlink "/proc/$STALE_PID/exe" 2>/dev/null | grep -q deleted; then
    fail "Stale nm-draytek-service (pid $STALE_PID) still running a deleted binary"
else
    pass "No stale nm-draytek-service process"
fi

# Creating a connection with our service type only succeeds if NM parsed
# the .name file — this IS the registration check. nmcli resolves the
# short name "draytek" against installed .name files (the option is
# vpn-type; older docs said vpn-service-type, which Fedora 44 rejects).
nmcli connection delete "$CON_NAME" &>/dev/null || true
if nmcli connection add type vpn ifname "*" con-name "$CON_NAME" \
        vpn-type draytek \
        vpn.data "gateway=${DRAYTEK_GATEWAY:-vpn.invalid},port=${DRAYTEK_PORT},username=${DRAYTEK_USERNAME:-e2e-dummy},verify-cert=${DRAYTEK_VERIFY_CERT},never-default=${NEVER_DEFAULT}" \
        &>/dev/null; then
    pass "NM resolves vpn-type draytek ($SERVICE_TYPE)"
else
    fail "NM rejected vpn-type draytek — plugin not registered"
    dump_nm_journal
    exit 1
fi

# ── Phase 4: Connect ──────────────────────────────────────────────
phase "4: Connect"

TUN_IF=""
if [ "$HAVE_CREDS" = 0 ]; then
    skip "No DRAYTEK_GATEWAY/USERNAME/PASSWORD in env — connect skipped"
else
    # Routers with a self-signed certificate fail verify-cert=yes against
    # the system trust store — and cannot be added to it: they are leaf
    # certs (no CA:TRUE), which p11-kit refuses to extract into the
    # bundle. The plugin's ca-cert option pins the PEM directly instead.
    if [ -n "${DRAYTEK_CA_CERT:-}" ]; then
        if [ ! -f "$DRAYTEK_CA_CERT" ]; then
            fail "DRAYTEK_CA_CERT not found: $DRAYTEK_CA_CERT"
        elif nmcli connection modify "$CON_NAME" \
                +vpn.data "ca-cert=$(readlink -f "$DRAYTEK_CA_CERT")"; then
            pass "Router certificate pinned (vpn.data ca-cert)"
        else
            fail "Could not set ca-cert on the test connection"
        fi
    fi

    nmcli connection modify "$CON_NAME" vpn.secrets "password=${DRAYTEK_PASSWORD}"
    if nmcli --wait "$CONNECT_TIMEOUT" connection up "$CON_NAME"; then
        CONNECTED=1
        pass "nmcli connection up succeeded"
    else
        fail "nmcli connection up failed"
        dump_nm_journal
    fi

    if [ "$CONNECTED" = 1 ]; then
        VPN_IP="$(nmcli -g IP4.ADDRESS connection show "$CON_NAME" | head -n1 | cut -d/ -f1)"
        if [ -n "$VPN_IP" ]; then
            pass "VPN IPv4 address assigned: $VPN_IP"
        else
            fail "No IPv4 address on the VPN connection"
        fi

        # Peer-style (ptp) addresses print as "inet <ip> peer <peer>/32" —
        # no /prefix on field 4 — so match a bare IP as well as ip/prefix.
        TUN_IF="$(ip -o -4 addr show | awk -v ip="$VPN_IP" '$4 ~ "^"ip"(/|$)" {print $2; exit}')"
        if [ -n "$TUN_IF" ]; then
            pass "Tunnel interface up: $TUN_IF"
            echo "       routes: $(ip route show dev "$TUN_IF" | tr '\n' ' ')"
        else
            fail "No interface carries $VPN_IP"
        fi
    fi

    # SELinux: any AVC denial involving the plugin during connect is a bug,
    # even when permissive mode let the connection succeed anyway.
    AVC_DENIALS="$(scan_avc_denials || true)"
    if [ -n "$AVC_DENIALS" ]; then
        fail "SELinux AVC denials during connect:"
        echo "$AVC_DENIALS" | sed 's/^/       /'
        [ "$SELINUX_MODE" = Enforcing ] || \
            echo "       (permissive mode: not enforced in this run, but breaks enforcing hosts)"
    elif [ "$SELINUX_MODE" = Enforcing ] || [ "$SELINUX_MODE" = Permissive ]; then
        pass "No SELinux AVC denials during connect"
    else
        skip "SELinux not active — AVC scan not meaningful"
    fi
fi

# ── Phase 5: Ping through the tunnel ──────────────────────────────
phase "5: Ping through the tunnel"

if [ "$CONNECTED" != 1 ] || [ -z "$TUN_IF" ]; then
    skip "Not connected — ping skipped"
else
    if [ "$DRAYTEK_DEFAULT_ROUTE" = "yes" ]; then
        # Default-gateway mode: the tunnel must own the default route,
        # and a plain (unbound) ping must go through it.
        ROUTE_DEV="$(ip route get "$PING_TARGET" 2>/dev/null | awk '{for(i=1;i<NF;i++) if($i=="dev") print $(i+1)}' | head -n1)"
        if [ "$ROUTE_DEV" = "$TUN_IF" ]; then
            pass "Default route to $PING_TARGET goes via the tunnel ($TUN_IF)"
        else
            fail "Default route to $PING_TARGET uses '$ROUTE_DEV', not the tunnel $TUN_IF"
        fi
        if ping -c "$PING_COUNT" -W 5 "$PING_TARGET"; then
            pass "Plain ping to $PING_TARGET works (all traffic via VPN)"
        else
            fail "Plain ping to $PING_TARGET failed in default-gateway mode"
            dump_nm_journal
        fi
    fi

    # Force egress via the tunnel interface regardless of default route
    # (with never-default=yes a plain ping would leave via the WAN and
    # prove nothing; in default-gateway mode this is a second witness).
    if ping -c "$PING_COUNT" -W 5 -I "$TUN_IF" "$PING_TARGET"; then
        pass "Internet reachable through the tunnel ($PING_TARGET via $TUN_IF)"
    else
        fail "Ping to $PING_TARGET via $TUN_IF failed"
        echo "       Note: internet ping requires the DrayTek router to forward"
        echo "       tunnel traffic upstream. Retry with PING_TARGET=<LAN host"
        echo "       behind the router> to isolate tunnel vs. router policy."
        dump_nm_journal
    fi

    # Secondary liveness check: the point-to-point peer, if one exists.
    PEER="$(ip route show dev "$TUN_IF" | awk '/proto kernel/ {print $1; exit}' | cut -d/ -f1)"
    if [ -n "$PEER" ] && [ "$PEER" != "$VPN_IP" ]; then
        if ping -c 2 -W 5 -I "$TUN_IF" "$PEER" &>/dev/null; then
            pass "Tunnel peer $PEER answers ping"
        else
            skip "Tunnel peer $PEER does not answer ping (routers often drop this)"
        fi
    fi
fi

# ── Phase 6: Teardown ─────────────────────────────────────────────
phase "6: Teardown"

if [ "$CONNECTED" = 1 ]; then
    if nmcli connection down "$CON_NAME"; then
        pass "Disconnected cleanly"
        CONNECTED=0
    else
        fail "Disconnect failed"
    fi
fi
if [ "$KEEP_CONNECTION" = 1 ]; then
    skip "Keeping connection profile '$CON_NAME' (--keep-connection)"
else
    nmcli connection delete "$CON_NAME" &>/dev/null || true
    pass "Test connection profile removed"
fi

# ── Summary ───────────────────────────────────────────────────────
echo -e "\n${BOLD}── Summary ──${NC}"
echo -e "  ${GREEN}$PASS passed${NC}, ${RED}$FAIL failed${NC}, ${YELLOW}$SKIP skipped${NC}"
if [ "$HAVE_CREDS" = 0 ]; then
    echo "  (registration-only run — export DRAYTEK_GATEWAY/USERNAME/PASSWORD"
    echo "   for the full connect + ping test)"
fi
[ "$FAIL" = 0 ]
