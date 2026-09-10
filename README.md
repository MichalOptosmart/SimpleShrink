# SimpleShrink

**Shrink a Raspberry Pi disk image on macOS, and let it grow back on first boot.**

A 12 GB `.img` of a card that is mostly empty becomes 2–4 GB, writes to a smaller card in
a fraction of the time, and expands to fill whatever card it lands on. This is what
[PiShrink](https://github.com/Drewsif/PiShrink) does on Linux — SimpleShrink does it
natively on macOS, with no VM, no Docker, and no root.

```console
$ simpleshrink shrink pi.img
[100%] Done
Shrunk /Users/me/pi.img
  12.37 GiB → 2.50 GiB (saved 9.87 GiB)
  First-boot expansion: raspi
```

## Why it exists

macOS has no `losetup`, no ext4 support in the kernel and no `parted`, so the usual Linux
recipe does not apply. SimpleShrink replaces each piece:

* `hdiutil attach -imagekey diskimage-class=CRawDiskImage -nomount` exposes the Linux
  partition as `/dev/diskNsM` — writable by you, without `sudo`.
* `e2fsck` and `resize2fs` are userspace tools that do not need a kernel driver. They are
  built from pinned upstream sources and shipped alongside the binary.
* Rewriting the MBR partition entry is 16 bytes of struct, done in our own code.

## Safety

Shrinking an image means truncating a file, so the design is arranged around not losing
one:

* **Nothing destructive happens until everything else has succeeded.** The partition
  table is rewritten and the file truncated only after a clean detach; a failure anywhere
  earlier leaves a fully valid image.
* **The partition table is restored** if anything goes wrong between the first write and
  the truncation.
* **Anything ambiguous is refused**, with a specific message: GPT, extended partitions, a
  root partition that is not last, overlapping entries, filesystems that are not
  ext2/3/4, filesystem features newer than the tools we ship.
* **`--output` shrinks a copy** and never touches the source. On APFS the copy is a
  clone — instant, and free until it diverges.
* **`--dry-run` reports the plan** and changes nothing.
* **It refuses to run as root.** Nothing it does needs privileges.
* **Two runs cannot collide**: a run holds a lock keyed by the image path for its
  whole duration.

## Requirements

macOS 15 or newer, Apple silicon or Intel. No dependencies to install: the release
package carries everything.

## Install

Download the notarised `.pkg` from
[Releases](https://github.com/optosmart/simpleshrink/releases) and open it. It installs
into `~/Library/Application Support/SimpleShrink`, and can optionally symlink
`simpleshrink` into `/usr/local/bin`.

### From source

```console
$ git clone https://github.com/optosmart/simpleshrink.git
$ cd simpleshrink
$ Scripts/build-e2fsprogs.sh          # downloads, verifies and builds e2fsprogs (universal)
$ swift build -c release
$ export SIMPLESHRINK_E2FSPROGS_DIR="$PWD/libexec/e2fsprogs"
$ .build/release/simpleshrink inspect pi.img
```

## Usage

```
simpleshrink shrink <image> [options]
simpleshrink inspect <image> [--json] [--free-space <MiB>]
simpleshrink describe --protocol 1
simpleshrink run --protocol 1 --capability shrink
simpleshrink version
```

| Option | Default | Meaning |
|---|---|---|
| `--free-space <MiB>` | 64 | Slack left in the shrunk filesystem |
| `--output <path>` | — | Shrink a copy; leave the input untouched |
| `--expansion <auto\|raspi\|generic\|none>` | `auto` | First-boot expansion strategy |
| `--extract-mode` | off | Resize via scratch space instead of the attached slice |
| `--dry-run` | off | Report the plan; change nothing |
| `--json` | off | NDJSON events on stdout instead of human output |
| `--verbose` | off | Include e2fsprogs output on stderr |

Look before you leap:

```console
$ simpleshrink inspect pi.img
Scheme:      mbr, 512-byte sectors
Image size:  12.37 GiB
Partitions:
  1. fat32 (0x0c) at LBA 8192, 256.00 MiB
  2. linux (0x83) at LBA 532480, 12.12 GiB
Root:        partition 2, 3177216 × 4096 B blocks, clean
Minimum:     2.34 GiB
Estimate:    about 2.50 GiB after shrinking
Expansion:   raspi
```

### First-boot expansion

A shrunk image is useless on a bigger card unless it grows back, so SimpleShrink arms the
expansion before it finishes. It edits `cmdline.txt` on the FAT boot partition — the ext4
root filesystem is never modified — and backs the file up to
`cmdline.txt.simpleshrink.bak` first.

* **Raspberry Pi OS** (default when detected): hands the kernel raspi-config's own
  `init_resize.sh`, the same mechanism PiShrink uses. Well proven.
* **Generic systemd** (Armbian, Ubuntu, images without raspi-config): a one-shot
  `systemd.run=` script that grows the partition, resizes the filesystem, removes itself
  and reboots. **Experimental in 1.0** — verify the first boot before relying on it.
* `--expansion none` shrinks only.

If neither can be armed, the shrink still succeeds and the result carries a warning
saying so.

## Integrating it into your own software

SimpleShrink is built to be driven by other programs as well as by people. Run it and
read its exit code, or use protocol mode for structured progress and results:

```console
$ echo '{"protocol":1,"capability":"shrink","input":{"path":"/tmp/pi.img"}}' \
    | simpleshrink run --protocol 1 --capability shrink
{"type":"progress","stage":"check","fraction":0.05}
{"type":"progress","stage":"resize","fraction":0.42}
{"type":"result","result":{"status":"ok","bytesBefore":13286604800,"bytesAfter":2680160256, …}}
```

One JSON request on stdin, NDJSON events on stdout, exactly one terminal event, and exit
codes that mean the same thing every time. `simpleshrink describe --protocol 1` tells a
host what this build can do before it runs anything.

**[docs/INTEGRATION.md](docs/INTEGRATION.md) is the normative description of that
interface** — request and event schemas, exit codes, cancellation, concurrency and the
compatibility policy. [docs/SPEC.md](docs/SPEC.md) is the full specification of the tool
itself, including why each decision was made.

## Limitations

* MBR images only. GPT is detected and refused.
* ext2, ext3 and ext4 only. btrfs, f2fs and XFS are detected and refused.
* The Linux partition must be the last one on the medium.
* Image files only — SimpleShrink does not touch physical cards.
* macOS only; on Linux, use PiShrink.

## Development

```console
$ swift test                      # unit tests, no e2fsprogs needed
$ Scripts/build-e2fsprogs.sh      # once, before anything end-to-end
$ Scripts/make-fixture.sh /tmp/fixture.img --size 2048 --raspi
$ Scripts/integration-test.sh     # shrink a real image and verify the result
```

See [CONTRIBUTING.md](CONTRIBUTING.md).

## Licence

**GPL-2.0-only**, in its entirety — see [COPYING](COPYING).

SimpleShrink ships binaries built from [e2fsprogs](https://e2fsprogs.sourceforge.net/),
whose `resize2fs` does the actual filesystem work and is GPL-2.0-only. Rather than argue
about where the boundary lies, the whole project takes the same licence.
[THIRD-PARTY.md](THIRD-PARTY.md) records the exact version, the licence map, the build
line and where to get the corresponding source.

Copyright © 2026 OptoSmart.
