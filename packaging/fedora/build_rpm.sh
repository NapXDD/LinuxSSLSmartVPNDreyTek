#!/usr/bin/env bash
set -euo pipefail

# Build Fedora RPM packages for the DrayTek VPN client.
#
# Like the Arch PKGBUILD, this builds from the surrounding git checkout —
# no source tarball is fetched. The working tree (including uncommitted
# changes) is archived into an rpmbuild source tarball under target/rpm/,
# then rpmbuild produces:
#   draytek-vpn-standalone-<ver>.rpm      GUI app + polkit helper
#   draytek-vpn-networkmanager-<ver>.rpm  NM plugin + tray
#
# Usage: packaging/fedora/build_rpm.sh   (or ./build.sh fedora)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
SPEC="$SCRIPT_DIR/draytek-vpn.spec"

if ! command -v rpmbuild &>/dev/null; then
    echo "Error: rpmbuild not found. Install it with: sudo dnf install rpm-build" >&2
    exit 1
fi

VERSION="$(awk '/^Version:/{print $2; exit}' "$SPEC")"
TOPDIR="$PROJECT_DIR/target/rpm"

mkdir -p "$TOPDIR"/{SOURCES,SPECS,BUILD,RPMS,SRPMS}

# ── Source tarball from the working tree ──────────────────────────
echo "Creating source tarball (draytek-vpn-$VERSION.tar.gz)..."
tar -C "$PROJECT_DIR" \
    --exclude='./target' \
    --exclude='./.git' \
    --exclude='./packaging/arch/pkg' \
    --exclude='./packaging/arch/src' \
    --exclude='./packaging/arch/*.pkg.tar.zst' \
    --transform "s|^\.|draytek-vpn-$VERSION|" \
    -czf "$TOPDIR/SOURCES/draytek-vpn-$VERSION.tar.gz" .

# ── Build ─────────────────────────────────────────────────────────
cp "$SPEC" "$TOPDIR/SPECS/"
rpmbuild --define "_topdir $TOPDIR" -ba "$TOPDIR/SPECS/draytek-vpn.spec"

echo ""
echo "Packages built:"
find "$TOPDIR/RPMS" -name '*.rpm' -exec ls -lh {} +
echo ""
echo "Install with:"
echo "  sudo dnf install $TOPDIR/RPMS/$(uname -m)/draytek-vpn-*-$VERSION*.rpm"
