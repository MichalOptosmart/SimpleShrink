#!/bin/bash
# SimpleShrink — Copyright (C) 2026 OptoSmart. GPL-2.0-only, see COPYING.
#
# Builds a test image on macOS, with no Linux involved: our own mke2fs writes the ext4
# filesystem, and `mke2fs -d` populates it from a directory without mounting anything.
#
#   Scripts/make-fixture.sh <output.img> [--size 2048] [--content <dir>] [--raspi]
#
#   --size <MiB>     total image size (default 2048)
#   --content <dir>  directory copied into the root filesystem
#   --raspi          add /usr/lib/raspi-config/init_resize.sh so the raspi strategy is detected
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MKE2FS="${MKE2FS:-$ROOT/vendor/e2fsprogs/build/mke2fs}"

OUTPUT=""
SIZE_MIB=2048
CONTENT=""
RASPI=0

while [ $# -gt 0 ]; do
    case "$1" in
        --size) SIZE_MIB="$2"; shift 2 ;;
        --content) CONTENT="$2"; shift 2 ;;
        --raspi) RASPI=1; shift ;;
        -*) echo "unknown option: $1" >&2; exit 1 ;;
        *) OUTPUT="$1"; shift ;;
    esac
done

[ -n "$OUTPUT" ] || { echo "usage: $0 <output.img> [--size MiB] [--content dir] [--raspi]" >&2; exit 1; }
[ -x "$MKE2FS" ] || { echo "mke2fs not found at $MKE2FS — run Scripts/build-e2fsprogs.sh first" >&2; exit 1; }

BOOT_START=8192          # 4 MiB in, the usual Raspberry Pi layout
BOOT_SECTORS=524288      # 256 MiB
ROOT_START=$((BOOT_START + BOOT_SECTORS))
TOTAL_SECTORS=$((SIZE_MIB * 2048))
ROOT_SECTORS=$((TOTAL_SECTORS - ROOT_START))

STAGING="$(mktemp -d)"
trap 'rm -rf "$STAGING"' EXIT

# A plausible root filesystem: enough for the detectors to have something to find.
CONTENT_DIR="$STAGING/content"
mkdir -p "$CONTENT_DIR/etc" "$CONTENT_DIR/usr/lib" "$CONTENT_DIR/var/log" "$CONTENT_DIR/boot"
echo "simpleshrink fixture" > "$CONTENT_DIR/etc/hostname"
if [ "$RASPI" = 1 ]; then
    mkdir -p "$CONTENT_DIR/usr/lib/raspi-config"
    printf '#!/bin/sh\nexit 0\n' > "$CONTENT_DIR/usr/lib/raspi-config/init_resize.sh"
    chmod +x "$CONTENT_DIR/usr/lib/raspi-config/init_resize.sh"
fi
if [ -n "$CONTENT" ]; then
    cp -R "$CONTENT"/. "$CONTENT_DIR"/
fi

echo "==> Creating a sparse $SIZE_MIB MiB image at $OUTPUT"
rm -f "$OUTPUT"
mkfile -n "${SIZE_MIB}m" "$OUTPUT" 2>/dev/null || truncate -s "${SIZE_MIB}m" "$OUTPUT"

echo "==> Writing the partition table"
python3 - "$OUTPUT" "$BOOT_START" "$BOOT_SECTORS" "$ROOT_START" "$ROOT_SECTORS" <<'PYTHON'
import struct, sys

path, boot_start, boot_sectors, root_start, root_sectors = sys.argv[1:6]
sector = bytearray(512)

def entry(offset, ptype, start, count):
    sector[offset] = 0x00                      # not bootable
    sector[offset + 1:offset + 4] = b'\xfe\xff\xff'   # CHS overflow marker
    sector[offset + 4] = ptype
    sector[offset + 5:offset + 8] = b'\xfe\xff\xff'
    sector[offset + 8:offset + 12] = struct.pack('<I', int(start))
    sector[offset + 12:offset + 16] = struct.pack('<I', int(count))

entry(0x1BE, 0x0C, boot_start, boot_sectors)   # FAT32 LBA
entry(0x1CE, 0x83, root_start, root_sectors)   # Linux
sector[0x1FE:0x200] = b'\x55\xaa'

with open(path, 'r+b') as image:
    image.write(sector)
PYTHON

echo "==> Attaching"
DEVICE="$(hdiutil attach -imagekey diskimage-class=CRawDiskImage -nomount "$OUTPUT" | head -1 | awk '{print $1}')"
trap 'hdiutil detach "$DEVICE" >/dev/null 2>&1 || true; rm -rf "$STAGING"' EXIT
echo "    $DEVICE"

echo "==> Formatting the boot partition"
newfs_msdos -F 32 -v BOOT "${DEVICE}s1" >/dev/null

MOUNTPOINT="$STAGING/boot"
mkdir -p "$MOUNTPOINT"
diskutil mount -mountPoint "$MOUNTPOINT" "${DEVICE}s1" >/dev/null
printf 'console=tty1 root=PARTUUID=deadbeef-02 rootfstype=ext4 fsck.repair=yes rootwait\n' \
    > "$MOUNTPOINT/cmdline.txt"
diskutil unmount "$MOUNTPOINT" >/dev/null

echo "==> Formatting the root partition"
"$MKE2FS" -t ext4 -L rootfs -d "$CONTENT_DIR" -q "${DEVICE}s2"

hdiutil detach "$DEVICE" >/dev/null
trap 'rm -rf "$STAGING"' EXIT

echo "==> $OUTPUT is ready"
