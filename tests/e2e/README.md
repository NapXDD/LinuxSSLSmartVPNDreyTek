# End-to-End Tests (Fedora)

Two scripts, two levels of realism:

| Script | Where it runs | What it proves |
|--------|---------------|----------------|
| `e2e-fedora.sh` | A real Fedora (KDE) machine with a reachable DrayTek router | Full path: build → install → NM registration → **connect → ping the internet through the tunnel** → teardown |
| `podman-smoke.sh` | Any machine with podman/docker | Build + install + NM plugin registration inside a Fedora 44 container (no live VPN — CI has no DrayTek router) |

## Full e2e on Fedora KDE

Put your router details in a config file (gitignored, so it can't be
committed):

```bash
cp tests/e2e/e2e.env.example tests/e2e/e2e.env
chmod 600 tests/e2e/e2e.env
$EDITOR tests/e2e/e2e.env        # fill in gateway, username, password
```

Then run on the target machine, from the repo root, as a normal desktop
user (sudo is used internally for installation):

```bash
tests/e2e/e2e-fedora.sh
```

Environment variables override the file, so a one-off run without a
config file also works:

```bash
DRAYTEK_GATEWAY=vpn.example.com \
DRAYTEK_USERNAME=myuser \
DRAYTEK_PASSWORD=mypassword \
    tests/e2e/e2e-fedora.sh
```

Phases:

1. **Preflight** — Fedora, NetworkManager running, `/dev/net/tun` exists
2. **Build** — `./build.sh fedora install` (skip with `--skip-build` to
   test an already-installed plugin)
3. **Registration** — every installed file is present, and NM accepts a
   connection with `vpn-service-type org.freedesktop.NetworkManager.draytek`
4. **Connect** — `nmcli connection up` on a test profile built from the
   env vars; verifies an IPv4 address is assigned and a tunnel interface
   carries it
5. **Ping** — `ping -I <tun> <target>` forces ICMP out the tunnel
   interface (the plugin defaults to `never-default=yes`, so a plain
   ping would leave via the WAN and prove nothing). Default target is
   `8.8.8.8`; if your router does not forward tunnel traffic to the
   internet, set `PING_TARGET` to a LAN host behind the router
6. **Teardown** — disconnect and delete the test profile (keep it with
   `--keep-connection`)

Without the three `DRAYTEK_*` credential variables the script still runs
phases 1–3 and reports connect/ping as SKIP — useful as an install check.

On any failure the script dumps the NetworkManager journal since test
start.

### Configuration (e2e.env or environment)

| Variable | Default | Meaning |
|----------|---------|---------|
| `DRAYTEK_GATEWAY` | *(none)* | Router host/IP — required for connect/ping |
| `DRAYTEK_USERNAME` | *(none)* | VPN username — required for connect/ping |
| `DRAYTEK_PASSWORD` | *(none)* | VPN password — required for connect/ping |
| `DRAYTEK_PORT` | `443` | SSL VPN port |
| `DRAYTEK_VERIFY_CERT` | `yes` | TLS certificate verification (`no` for self-signed router certs) |
| `DRAYTEK_CA_CERT` | *(none)* | PEM file pinned via the plugin's `ca-cert` option — keeps `verify-cert=yes` working with a self-signed router cert (those are leaf certs the system trust store can't hold). Relative paths resolve against `tests/e2e/` |
| `DRAYTEK_DEFAULT_ROUTE` | `no` | `yes` routes ALL traffic through the VPN (Smart VPN "use default gateway on remote network"); the test then also asserts the default route rides the tunnel and plain pings work |
| `PING_TARGET` | `8.8.8.8` | Host to ping through the tunnel |
| `PING_COUNT` | `4` | Ping count |
| `CONNECT_TIMEOUT` | `60` | Seconds to wait for `nmcli connection up` |

## Container smoke test

```bash
tests/e2e/podman-smoke.sh            # podman
CONTAINER_ENGINE=docker tests/e2e/podman-smoke.sh   # docker
```

Builds the RPMs from the working tree inside
`registry.fedoraproject.org/fedora:44`, installs them, starts D-Bus and
NetworkManager directly (the Fedora container image has no systemd), and
verifies NM accepts the DrayTek VPN service type. It reads the same
`tests/e2e/e2e.env` file — when `DRAYTEK_GATEWAY` and `DRAYTEK_PASSWORD`
are filled in (there or in the environment), it additionally attempts a
live connect + ping from inside the container; this requires the gateway
to be reachable from the container network.

`--keep` leaves the container running for inspection.

## KDE notes

The connect/ping path is desktop-agnostic (pure NetworkManager). What is
KDE-specific:

- The connection editor GTK `.so` files are used by `nm-connection-editor`
  and GNOME Settings; KDE's plasma-nm renders the connection through NM
  directly, so `nmcli`-created profiles appear and connect fine in the
  Plasma network applet.
- The tray indicator uses StatusNotifierItem, which Plasma supports out
  of the box — after `connection up`, a green DrayTek icon should appear
  in the system tray. The e2e script does not assert on the tray (it has
  no reliable headless check); verify it visually.
