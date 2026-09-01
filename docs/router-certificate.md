# Verifying the Router's TLS Certificate

By default DrayTek routers serve a **self-signed certificate**, and the
examples in this repo use `verify-cert=no` to get connected quickly. That
setting disables TLS verification entirely, which means the client will
happily complete the handshake with *anything* answering on the router's
address — including a machine-in-the-middle. For any long-lived setup you
should pin the router's certificate and turn verification on.

## Why the system trust store does not work

The obvious approach — adding the router's certificate to the system
trust store (`update-ca-trust` / `update-ca-certificates`) — silently
does nothing for a typical DrayTek certificate. Router certificates are
self-signed **leaf** certificates without the `CA:TRUE` basic constraint,
and p11-kit only extracts *CA* certificates into the OpenSSL bundle.
The anchor is accepted into the store, but never appears in the bundle
OpenSSL reads, and the handshake keeps failing with
`certificate verify failed`.

The client therefore supports pinning the certificate directly via a
`ca-cert` option: the PEM is loaded into that connection's trust store
in addition to the system one, and OpenSSL accepts an exact self-signed
match. (A proper CA-signed chain also works — point `ca-cert` at the CA.)

## 1. Fetch the router's certificate

```bash
echo | openssl s_client -connect ROUTER_ADDRESS:PORT 2>/dev/null \
    | openssl x509 > draytek-router.pem
```

Verify what you fetched — subject, validity, and that the SAN matches the
address you connect to:

```bash
openssl x509 -in draytek-router.pem -noout -subject -dates -ext subjectAltName -fingerprint -sha256
```

Fetching the certificate over the same network path you later want to
trust is only as strong as that first connection. If you can, compare the
SHA-256 fingerprint against the certificate shown in the router's admin
UI (or fetch it from a network you already trust).

## 2. Store it somewhere stable

The file is read at every connect by the NetworkManager plugin (as root)
or the standalone app (as your user), so it needs a stable, readable
location. World-readable is fine — it is a public certificate, not a key:

```bash
# Fedora
sudo install -m 644 draytek-router.pem /etc/pki/tls/certs/draytek-router.pem

# Debian/Ubuntu
sudo install -m 644 draytek-router.pem /etc/ssl/certs/draytek-router.pem
```

Avoid paths under your home directory for NetworkManager connections:
the plugin reads the file in NetworkManager's SELinux domain, and
system-labeled locations like `/etc/pki` are the safe choice.

## 3. Point the client at it

**NetworkManager (nmcli):**

```bash
nmcli connection add type vpn ifname "*" con-name "DrayTek VPN" vpn-type draytek \
    vpn.data "gateway=ROUTER_ADDRESS,port=PORT,username=USER,verify-cert=yes,ca-cert=/etc/pki/tls/certs/draytek-router.pem"
nmcli connection modify "DrayTek VPN" vpn.secrets "password=PASSWORD"
```

**NetworkManager (GUI):** in the connection editor, switch **Accept
Self-Signed Certs** off and put the path in the **CA Certificate** field.

**Standalone app:** in the profile editor, switch **Accept Self-Signed
Certificates** off and fill **CA Certificate** with the path (stored as
`ca_cert` in `~/.config/draytek-vpn/config.toml`).

## Certificate rotation

The pinned file must match what the router serves. Router certificates
expire (check `notAfter` in step 1) and are regenerated on firmware
resets. When that happens, connections fail again with
`TLS handshake failed: certificate verify failed` — re-run step 1 and
replace the stored PEM.
