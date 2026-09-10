#!/bin/bash
# SimpleShrink — Copyright (C) 2026 OptoSmart. GPL-2.0-only, see COPYING.
#
# Builds the vendored e2fsprogs tools as universal binaries and installs them into
# libexec/e2fsprogs/, where the tool looks for them at runtime.
#
#   Scripts/build-e2fsprogs.sh [--prefix <dir>]
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PREFIX="$ROOT/libexec/e2fsprogs"
WORK="$ROOT/vendor/e2fsprogs/build"

while [ $# -gt 0 ]; do
    case "$1" in
        --prefix) PREFIX="$2"; shift 2 ;;
        *) echo "usage: $0 [--prefix <dir>]" >&2; exit 1 ;;
    esac
done

# shellcheck source=/dev/null
source "$ROOT/vendor/e2fsprogs/PINNED"

TARBALL="$WORK/e2fsprogs-$E2FSPROGS_VERSION.tar.xz"
SRC="$WORK/e2fsprogs-$E2FSPROGS_VERSION"

mkdir -p "$WORK" "$PREFIX"

if [ ! -f "$TARBALL" ]; then
    echo "==> Downloading e2fsprogs $E2FSPROGS_VERSION"
    curl -fsSL -o "$TARBALL" "$E2FSPROGS_URL"
fi

echo "==> Verifying checksum"
echo "$E2FSPROGS_SHA256  $TARBALL" | shasum -a 256 -c -

if [ ! -d "$SRC" ]; then
    echo "==> Unpacking"
    tar -xf "$TARBALL" -C "$WORK"

    shopt -s nullglob
    for patch in "$ROOT"/vendor/e2fsprogs/patches/*.patch; do
        echo "==> Applying $(basename "$patch")"
        patch -p1 -d "$SRC" < "$patch"
    done
    shopt -u nullglob
fi

# Two separate builds, then lipo. e2fsprogs' configure does not cross-compile both at
# once, and -arch flags in CFLAGS confuse its feature tests.
build_arch() {
    local arch="$1"
    local out="$WORK/build-$arch"
    echo "==> Building for $arch"
    mkdir -p "$out"
    (
        cd "$out"
        "$SRC/configure" \
            --host="$arch-apple-darwin" \
            CC="clang -arch $arch" \
            --disable-nls \
            --disable-fsck \
            --disable-uuidd \
            --disable-e2initrd-helper \
            --disable-elf-shlibs \
            --disable-bsd-shlibs
        make -j"$(sysctl -n hw.ncpu)"
    )
}

build_arch arm64
build_arch x86_64

# What ships. mke2fs is built too — Scripts/make-fixture.sh needs it — but it stays in
# the build tree: every binary in the release is one more thing to sign, notarise and
# account for in THIRD-PARTY.md.
SHIPPED=(e2fsck/e2fsck resize/resize2fs misc/dumpe2fs debugfs/debugfs)
FIXTURE_ONLY=(misc/mke2fs)

echo "==> Creating universal binaries in $PREFIX"
for tool in "${SHIPPED[@]}"; do
    name="$(basename "$tool")"
    lipo -create \
        "$WORK/build-arm64/$tool" \
        "$WORK/build-x86_64/$tool" \
        -output "$PREFIX/$name"
    chmod +x "$PREFIX/$name"
    echo "    $name $(lipo -archs "$PREFIX/$name")"
done

for tool in "${FIXTURE_ONLY[@]}"; do
    name="$(basename "$tool")"
    cp "$WORK/build-arm64/$tool" "$WORK/$name"
    echo "    $name (fixtures only, not shipped)"
done

cat <<NOTE

Done. Point the tool at these binaries with:

    export SIMPLESHRINK_E2FSPROGS_DIR="$PREFIX"

A packaged build finds them at ../libexec/e2fsprogs relative to the executable and
needs no environment variable.
NOTE
