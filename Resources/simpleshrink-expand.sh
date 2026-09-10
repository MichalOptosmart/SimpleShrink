#!/bin/sh
# SimpleShrink first-boot expansion — generic systemd strategy.
# Copyright (C) 2026 OptoSmart. GPL-2.0-only, see COPYING.
#
# Run once by systemd.run= from the kernel command line, before the system is up.
# Grows the root partition to fill the medium, grows the filesystem into it, then
# removes itself from cmdline.txt and deletes itself.
set -eu
exec >>/var/log/simpleshrink-expand.log 2>&1
echo "simpleshrink-expand: $(date -u +%Y-%m-%dT%H:%M:%SZ)"

ROOT_SRC=$(findmnt -n -o SOURCE /)
ROOT_NAME=$(basename "$ROOT_SRC")
DISK="/dev/$(lsblk -no pkname "$ROOT_SRC")"
PARTNUM=$(cat "/sys/class/block/$ROOT_NAME/partition")

echo ',+,' | sfdisk -N "$PARTNUM" --force "$DISK"
partx -u "$DISK" || partprobe "$DISK" || true
resize2fs "$ROOT_SRC"

BOOTDIR=$(dirname "$0")
sed -i \
    -e 's| systemd\.run=[^ ]*||g' \
    -e 's| systemd\.run_success_action=[^ ]*||g' \
    -e 's| systemd\.unit=kernel-command-line\.target||g' \
    "$BOOTDIR/cmdline.txt"

rm -f "$0"
sync
echo "simpleshrink-expand: done"
