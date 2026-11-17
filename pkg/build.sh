#!/bin/bash
# Builds build/onramp-<version>.pkg, a distribution package an MDM can install.
# It's unsigned: signing and notarization need a Developer ID and come later.
#   pkg/build.sh
set -euo pipefail
cd "$(dirname "$0")/.."

# Universal, so the same package works on Apple silicon and Intel Macs.
swift build -c release --arch arm64 --arch x86_64
binary=$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/onramp
version=$("$binary" --version)

stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT
root=$stage/root
install -d -m 755 "$root/Library/onramp" "$root/Library/LaunchDaemons"
install -m 755 "$binary" "$root/Library/onramp/onramp"
install -m 644 pkg/io.github.popaprozac.onramp.daemon.plist "$root/Library/LaunchDaemons/"

# Where macOS tags built files with com.apple.provenance, which can't be removed, pkgbuild prints
# "write: Permission denied" and adds empty ._ entries. They're harmless: Installer drops them and
# installs no ._ files.
# "recommended" ownership installs everything as root:wheel, whoever built it.
pkgbuild --quiet --root "$root" --scripts pkg/scripts --ownership recommended \
    --identifier io.github.popaprozac.onramp --version "$version" --install-location / \
    "$stage/onramp-component.pkg"
mkdir -p build
productbuild --quiet --package "$stage/onramp-component.pkg" "build/onramp-$version.pkg"
echo "built build/onramp-$version.pkg"
