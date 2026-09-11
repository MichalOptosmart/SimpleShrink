#!/bin/bash
# SimpleShrink — Copyright (C) 2026 OptoSmart. GPL-2.0-only, see COPYING.
#
# Builds a universal release and packs it into a self-contained tarball.
#
#   Scripts/package.sh [--identity <name>]
#
# Signing: every Mach-O in the payload is signed, ad-hoc by default. Pass --identity
# (or set SIGN_IDENTITY) to use a self-signed certificate from the keychain instead.
#
# There is deliberately no notarisation and no .pkg. Notarisation needs a paid Developer
# ID, and all it buys is a double-clickable download — a GPL tool whose primary install
# path is "build it yourself" does not need to route through Apple to be trustworthy.
# The trade-off is Gatekeeper: a tarball downloaded by a browser is quarantined, so the
# release notes tell people to unpack it with `tar` in a terminal (which does not
# propagate the quarantine flag) or to clear the flag themselves. See docs/SPEC.md §11.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST="$ROOT/dist"
VERSION="$(sed -n 's/.*let version = "\(.*\)"/\1/p' "$ROOT/Sources/SimpleShrinkKit/Version.swift")"
IDENTITY="${SIGN_IDENTITY:--}"
NAME="SimpleShrink-$VERSION"
STAGE="$DIST/$NAME"

while [ $# -gt 0 ]; do
    case "$1" in
        --identity) IDENTITY="$2"; shift 2 ;;
        *) echo "usage: $0 [--identity <name>]" >&2; exit 1 ;;
    esac
done

echo "==> SimpleShrink $VERSION"

# A tag must never disagree with the version the binary reports.
if [ -n "${GITHUB_REF_NAME:-}" ] && [ "${GITHUB_REF_NAME#v}" != "$GITHUB_REF_NAME" ]; then
    if [ "${GITHUB_REF_NAME#v}" != "$VERSION" ]; then
        echo "error: tag ${GITHUB_REF_NAME} does not match Version.swift ($VERSION)" >&2
        exit 1
    fi
fi

rm -rf "$DIST"
mkdir -p "$STAGE/bin" "$STAGE/libexec/e2fsprogs" "$STAGE/share"

echo "==> Building e2fsprogs"
"$ROOT/Scripts/build-e2fsprogs.sh" --prefix "$STAGE/libexec/e2fsprogs"

echo "==> Building simpleshrink (universal)"
swift build -c release --arch arm64 --arch x86_64 --package-path "$ROOT"
BIN_PATH="$(swift build -c release --arch arm64 --arch x86_64 --package-path "$ROOT" --show-bin-path)"
cp "$BIN_PATH/simpleshrink" "$STAGE/bin/simpleshrink"

echo "==> Generating the integration manifest"
sed "s/@VERSION@/$VERSION/g" "$ROOT/integration/manifest.json.in" > "$STAGE/manifest.json"
cp "$ROOT/COPYING" "$ROOT/THIRD-PARTY.md" "$ROOT/README.md" "$STAGE/share/"
cp "$ROOT/docs/INTEGRATION.md" "$STAGE/share/"

# An installer script, because there is no .pkg to do it.
cat > "$STAGE/install.sh" <<'INSTALL'
#!/bin/bash
# Copies SimpleShrink into place and optionally symlinks it onto the PATH.
#
#   ./install.sh [--prefix <dir>] [--link]
#
# Default prefix: ~/Library/Application Support/SimpleShrink
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PREFIX="$HOME/Library/Application Support/SimpleShrink"
LINK=0

while [ $# -gt 0 ]; do
    case "$1" in
        --prefix) PREFIX="$2"; shift 2 ;;
        --link) LINK=1; shift ;;
        *) echo "usage: $0 [--prefix <dir>] [--link]" >&2; exit 1 ;;
    esac
done

mkdir -p "$PREFIX"
# bin/ and libexec/ must stay siblings: the tool finds e2fsprogs relative to itself.
cp -R "$HERE/bin" "$HERE/libexec" "$HERE/share" "$HERE/manifest.json" "$PREFIX/"

# A browser-downloaded archive is quarantined; unpacked files inherit it and Gatekeeper
# then refuses to run them. Clearing it here is the same decision as unpacking with tar.
xattr -dr com.apple.quarantine "$PREFIX" 2>/dev/null || true

if [ "$LINK" = 1 ]; then
    mkdir -p /usr/local/bin
    ln -sf "$PREFIX/bin/simpleshrink" /usr/local/bin/simpleshrink
    echo "Linked /usr/local/bin/simpleshrink"
fi

echo "Installed into $PREFIX"
"$PREFIX/bin/simpleshrink" version
INSTALL
chmod +x "$STAGE/install.sh"

echo "==> Signing (identity: $IDENTITY)"
# arm64 requires at least an ad-hoc signature, and signing everything keeps the payload
# consistent whether or not a self-signed certificate is available.
find "$STAGE" -type f -perm +111 -print0 | while IFS= read -r -d '' binary; do
    if file "$binary" | grep -q Mach-O; then
        codesign --force --sign "$IDENTITY" "$binary"
        codesign --verify --strict "$binary"
        echo "    signed $(basename "$binary")"
    fi
done

echo "==> Creating the archive"
TARBALL="$DIST/$NAME.tar.gz"
tar -czf "$TARBALL" -C "$DIST" "$NAME"
(cd "$DIST" && shasum -a 256 "$NAME.tar.gz" > "$NAME.tar.gz.sha256")

cat <<NOTE

==> $TARBALL
    $(cd "$DIST" && cat "$NAME.tar.gz.sha256")

Unpack with tar in a terminal — Archive Utility would propagate the download's
quarantine flag to every extracted file:

    tar -xzf $NAME.tar.gz
    ./$NAME/install.sh --link
NOTE
