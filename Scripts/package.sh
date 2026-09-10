#!/bin/bash
# SimpleShrink — Copyright (C) 2026 OptoSmart. GPL-2.0-only, see COPYING.
#
# Builds a universal release and wraps it in a signed, notarised, stapled .pkg.
#
#   Scripts/package.sh [--sign] [--notarize]
#
# Signing needs, in the environment:
#   SIGN_APP_IDENTITY        "Developer ID Application: …"
#   SIGN_INSTALLER_IDENTITY  "Developer ID Installer: …"
#   NOTARY_PROFILE           a notarytool keychain profile name
#
# Why a .pkg rather than a .dmg or a bare binary: a notarisation ticket can only be
# stapled to a bundle, a disk image or a package — a loose executable needs a network
# round trip on every launch — and files installed by a .pkg do not carry
# com.apple.quarantine, which a .dmg drag-install would put on every copied file.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST="$ROOT/dist"
STAGE="$DIST/root"
VERSION="$(sed -n 's/.*let version = "\(.*\)"/\1/p' "$ROOT/Sources/SimpleShrinkKit/Version.swift")"
IDENTIFIER="cz.optosmart.simpleshrink"
INSTALL_LOCATION="Library/Application Support/SimpleShrink"

DO_SIGN=0
DO_NOTARIZE=0
while [ $# -gt 0 ]; do
    case "$1" in
        --sign) DO_SIGN=1; shift ;;
        --notarize) DO_SIGN=1; DO_NOTARIZE=1; shift ;;
        *) echo "usage: $0 [--sign] [--notarize]" >&2; exit 1 ;;
    esac
done

echo "==> SimpleShrink $VERSION"

if [ -n "${GITHUB_REF_NAME:-}" ] && [ "${GITHUB_REF_NAME#v}" != "$GITHUB_REF_NAME" ]; then
    if [ "${GITHUB_REF_NAME#v}" != "$VERSION" ]; then
        echo "error: tag ${GITHUB_REF_NAME} does not match Version.swift ($VERSION)" >&2
        exit 1
    fi
fi

rm -rf "$DIST"
mkdir -p "$STAGE/$INSTALL_LOCATION/bin" "$STAGE/$INSTALL_LOCATION/libexec/e2fsprogs" \
         "$STAGE/$INSTALL_LOCATION/share"

echo "==> Building e2fsprogs"
"$ROOT/Scripts/build-e2fsprogs.sh" --prefix "$STAGE/$INSTALL_LOCATION/libexec/e2fsprogs"

echo "==> Building simpleshrink (universal)"
swift build -c release --arch arm64 --arch x86_64 --package-path "$ROOT"
cp "$(swift build -c release --arch arm64 --arch x86_64 --package-path "$ROOT" --show-bin-path)/simpleshrink" \
   "$STAGE/$INSTALL_LOCATION/bin/simpleshrink"

echo "==> Generating the integration manifest"
sed "s/@VERSION@/$VERSION/g" "$ROOT/integration/manifest.json.in" \
    > "$STAGE/$INSTALL_LOCATION/manifest.json"
cp "$ROOT/COPYING" "$ROOT/THIRD-PARTY.md" "$ROOT/README.md" "$STAGE/$INSTALL_LOCATION/share/"

if [ "$DO_SIGN" = 1 ]; then
    : "${SIGN_APP_IDENTITY:?set SIGN_APP_IDENTITY}"
    echo "==> Signing binaries"
    # Every Mach-O in the payload, hardened runtime, secure timestamp.
    find "$STAGE" -type f -perm +111 -print0 | while IFS= read -r -d '' binary; do
        if file "$binary" | grep -q Mach-O; then
            codesign --force --timestamp --options runtime \
                --sign "$SIGN_APP_IDENTITY" "$binary"
        fi
    done
fi

echo "==> Building the package"
mkdir -p "$DIST/pkg"
pkgbuild \
    --root "$STAGE" \
    --identifier "$IDENTIFIER" \
    --version "$VERSION" \
    --install-location "/" \
    "$DIST/pkg/component.pkg"

cat > "$DIST/distribution.xml" <<XML
<?xml version="1.0" encoding="utf-8"?>
<installer-gui-script minSpecVersion="2">
    <title>SimpleShrink</title>
    <options customize="never" require-scripts="false" hostArchitectures="arm64,x86_64"/>
    <domains enable_currentUserHome="true" enable_anywhere="false" enable_localSystem="false"/>
    <volume-check>
        <allowed-os-versions><os-version min="15.0"/></allowed-os-versions>
    </volume-check>
    <choices-outline><line choice="default"/></choices-outline>
    <choice id="default" visible="false"><pkg-ref id="$IDENTIFIER"/></choice>
    <pkg-ref id="$IDENTIFIER" version="$VERSION">component.pkg</pkg-ref>
</installer-gui-script>
XML

PKG="$DIST/SimpleShrink-$VERSION.pkg"
if [ "$DO_SIGN" = 1 ]; then
    : "${SIGN_INSTALLER_IDENTITY:?set SIGN_INSTALLER_IDENTITY}"
    productbuild --distribution "$DIST/distribution.xml" --package-path "$DIST/pkg" \
        --sign "$SIGN_INSTALLER_IDENTITY" "$PKG"
else
    productbuild --distribution "$DIST/distribution.xml" --package-path "$DIST/pkg" "$PKG"
fi

if [ "$DO_NOTARIZE" = 1 ]; then
    : "${NOTARY_PROFILE:?set NOTARY_PROFILE}"
    echo "==> Notarising"
    xcrun notarytool submit "$PKG" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$PKG"
    xcrun stapler validate "$PKG"
fi

echo "==> $PKG"
