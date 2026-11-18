#!/bin/bash
# Builds build/onramp-<version>.pkg, a distribution package an MDM can install.
#   pkg/build.sh
# To sign and notarize, set:
#   ONRAMP_APP_IDENTITY        a "Developer ID Application: …" identity, which signs the binary
#   ONRAMP_INSTALLER_IDENTITY  a "Developer ID Installer: …" identity, which signs the package
#   ONRAMP_NOTARY_PROFILE      a notarytool keychain profile (`xcrun notarytool store-credentials`)
# With none of them set, the package is unsigned, as in CI.
set -euo pipefail
cd "$(dirname "$0")/.."

app=${ONRAMP_APP_IDENTITY:-}
installer=${ONRAMP_INSTALLER_IDENTITY:-}
notary=${ONRAMP_NOTARY_PROFILE:-}
# Apple's notary service checks the executable inside the package too, so notarizing needs both identities.
if [ -n "$notary" ] && { [ -z "$app" ] || [ -z "$installer" ]; }; then
    echo "ONRAMP_NOTARY_PROFILE needs ONRAMP_APP_IDENTITY and ONRAMP_INSTALLER_IDENTITY" >&2
    exit 1
fi

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

if [ -n "$app" ]; then
    # The hardened runtime and a secure timestamp are both required for notarization.
    codesign --force --options runtime --timestamp --identifier io.github.popaprozac.onramp \
        --sign "$app" "$root/Library/onramp/onramp"
    codesign --verify --strict "$root/Library/onramp/onramp"
fi

# Where macOS tags built files with com.apple.provenance, which can't be removed, pkgbuild prints
# "write: Permission denied" and adds empty ._ entries. They're harmless: Installer drops them and
# installs no ._ files.
# "recommended" ownership installs everything as root:wheel, whoever built it.
pkgbuild --quiet --root "$root" --scripts pkg/scripts --ownership recommended \
    --identifier io.github.popaprozac.onramp --version "$version" --install-location / \
    "$stage/onramp-component.pkg"

sign=()
[ -z "$installer" ] || sign=(--sign "$installer" --timestamp)
out=build/onramp-$version.pkg
mkdir -p build
# Bash 3.2 treats an empty array as unset under `set -u`, hence the ${…+…}.
productbuild --quiet ${sign[@]+"${sign[@]}"} --package "$stage/onramp-component.pkg" "$out"

if [ -n "$notary" ]; then
    result=$(xcrun notarytool submit "$out" --keychain-profile "$notary" --wait --output-format json)
    status=$(plutil -extract status raw -o - - <<<"$result")
    if [ "$status" != "Accepted" ]; then
        echo "notarization: $status" >&2
        xcrun notarytool log "$(plutil -extract id raw -o - - <<<"$result")" --keychain-profile "$notary" >&2 || true
        exit 1
    fi
    xcrun stapler staple "$out"
fi

[ -z "$installer" ] || pkgutil --check-signature "$out" | sed -n '1,4p'
echo "built $out"
