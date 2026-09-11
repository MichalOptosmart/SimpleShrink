# SimpleShrink — specification

Repository: `optosmart/simpleshrink`
Licence: **GPL-2.0-only**
Deliverable: a standalone macOS command-line tool, usable on its own and embeddable in
any host application through the interface described in
[`INTEGRATION.md`](INTEGRATION.md).

This document is the complete brief: what the tool does, why it is built the way it is,
and what "finished" means. It should be enough to build the project without further
input.

---

## 1. What it does

SimpleShrink reduces a Raspberry Pi style disk image to the smallest size its contents
allow, and arranges for the filesystem to expand back to the full card on first boot —
the job PiShrink does on Linux, done natively on macOS.

Given `pi.img` containing an MBR partition table, a FAT boot partition and an ext4 root
partition:

1. Shrink the ext4 filesystem to its minimum plus a safety margin.
2. Rewrite the MBR entry for that partition to the new size.
3. Truncate the image file to the end of the last partition.
4. Arm first-boot expansion by editing `cmdline.txt` on the FAT boot partition.

A 12 GB image of a card that is mostly empty typically becomes 2–4 GB, writes to a
smaller card, and grows back to fill whatever card it is written to.

### 1.1 Why this is not simply "port PiShrink"

PiShrink is a bash script built on `losetup`, `parted`, `e2fsck` and `resize2fs`. On
macOS:

* There is no `losetup` — `hdiutil` fills that role, and it works. Attaching a raw image
  with `-imagekey diskimage-class=CRawDiskImage -nomount` makes macOS parse the MBR and
  expose Linux partitions as `/dev/diskNsM`, writable by the invoking user without root.
  Verified on macOS 26.4: device nodes appear as `brw-r----- <user> staff` and a write to
  `/dev/rdiskNs2` succeeds as an ordinary user.
* There is no ext4 support in the kernel — but this does not matter, because `e2fsck` and
  `resize2fs` are userspace tools that operate on a block device or a plain file. They
  must be built and shipped by us.
* There is no `parted`. Rewriting the MBR partition entry is 16 bytes of little-endian
  struct and is done in our own code.

### 1.2 Design stance

SimpleShrink is a **product, not a helper script**. Two consequences run through the
whole design:

* It is safe to point at an image without reading the source first. Everything ambiguous
  is refused rather than guessed at; the destructive steps happen last and roll back.
* It is drivable by other software. The command line, the exit codes, the JSON event
  stream and the manifest are a contract, documented in
  [`INTEGRATION.md`](INTEGRATION.md) and covered by tests. A host application integrates
  it by running a process — no shared code, no shared licence, no assumptions about who
  is calling.

### 1.3 Non-goals

* GPT images. Detected and refused with a clear message. (Possible later; requires
  recomputing both header CRC32s and the entry array.)
* Filesystems other than ext2/ext3/ext4. btrfs, f2fs and XFS are detected and refused.
* Growing an image.
* Modifying a physical card in place. SimpleShrink operates on image files only.
* Windows or Linux builds. The tool exists because macOS lacks the Linux tooling.

---

## 2. Licence decisions

The repository is **GPL-2.0-only** in its entirety, matching e2fsprogs' tools.

This is deliberate even though a narrower reading would permit a permissively licensed
wrapper — our Swift code `fork`/`exec`s the e2fsprogs binaries rather than linking them.
A uniformly GPL project makes the "freely distributable" claim unambiguous, satisfies the
distribution obligation by simply publishing the repository, and spares every downstream
integrator the argument. Integrators who cannot take on GPL obligations run the
executable instead of linking the library; that boundary is the point of
[`INTEGRATION.md`](INTEGRATION.md) §7.

### 2.1 Consequence: no Apache-2.0 dependencies

Apache-2.0 is **incompatible with GPL-2.0-only** (its patent-termination clause is an
additional restriction under GPLv2 §6; it is compatible with GPLv3 only). This rules out
`swift-argument-parser` and most of the Swift server ecosystem.

**The project therefore has no external Swift package dependencies.** Argument parsing is
hand-written — the CLI surface is small enough that this costs about 200 lines
(`Sources/SimpleShrinkKit/CommandLine.swift`).

### 2.2 Vendored e2fsprogs licence map

| Component | Licence |
|---|---|
| `e2fsck/`, `resize/`, `debugfs/`, `misc/` (dumpe2fs, mke2fs) | GPL-2.0-only |
| `lib/ext2fs`, `lib/e2p`, `lib/blkid` | LGPL-2.0 |
| `lib/uuid` | BSD-3-Clause |
| `lib/et`, `lib/ss` | MIT-style |

The shrink algorithm lives in `resize/`, which is GPL — there is no LGPL-only path to
this functionality.

### 2.3 Compliance checklist

- [x] `COPYING` at repository root (GPLv2 text).
- [x] `THIRD-PARTY.md` listing e2fsprogs, its exact version, its licence map, upstream
      URL and the exact configure line.
- [x] Pinned tarball URL plus SHA-256 (`vendor/e2fsprogs/PINNED`), and every patch we
      apply (`vendor/e2fsprogs/patches/`), published in the repository.
- [ ] Release artefacts accompanied by, or offering, the corresponding source for the
      exact binaries shipped.
- [x] Per-file GPL headers on our own sources.

---

## 3. Requirements

| | |
|---|---|
| Platform | macOS 15 or newer |
| Architectures | Universal binary, `arm64` + `x86_64` |
| Privileges | **None.** The tool refuses to run as root (see §7.4) |
| Language | Swift 6, Swift Package Manager |
| Dependencies | None beyond the vendored e2fsprogs and system frameworks |

---

## 4. Pipeline

Stage tokens in the right column are emitted as `stage` in progress events.

| # | Step | Stage |
|---|---|---|
| 1 | Validate input file, take the run lock, snapshot MBR and file size | `open` |
| 2 | Attach image via `hdiutil`, resolve slices | `attach` |
| 3 | Identify boot and root partitions, verify assumptions | `probe` |
| 4 | `e2fsck -f -y` on the root slice | `check` |
| 5 | `resize2fs -P` to obtain the minimum, compute target | `probe` |
| 6 | `resize2fs <target>` | `resize` |
| 7 | `e2fsck -f -y` again; `dumpe2fs -h` for the authoritative new size | `verify` |
| 8 | Arm first-boot expansion on the FAT boot partition | `arm` |
| 9 | Detach | `detach` |
| 10 | Rewrite the MBR entry | `partition` |
| 11 | Truncate the file | `truncate` |

Ordering matters: the MBR is rewritten and the file truncated only **after** a clean
detach, so a failure at any earlier point leaves a fully valid image. Steps 10 and 11 are
the only destructive ones and are separated by an `fsync`.

### 4.1 Attaching

```
hdiutil attach -imagekey diskimage-class=CRawDiskImage -nomount -plist <image>
```

* `-nomount` is mandatory. Without it macOS mounts the FAT partition and may write to it.
* Parse the plist output with `PropertyListDecoder` — read `system-entities`, taking
  `dev-entry` and `content-hint` per entity. Do not parse the human-readable table.
* Detach with `hdiutil detach <dev>`; on failure retry three times at 1 s intervals, then
  `hdiutil detach -force`.
* The attach is owned by a scope guard so that every error path, and the signal handler,
  detaches. A leaked attachment is the worst failure mode this tool has, which is why
  live attachments are also tracked in `AttachmentRegistry`.

### 4.2 Locking

Mutual exclusion between runs is a **lock file in the user's cache directory**, named
after the SHA-256 of the resolved image path — not an `flock` on the image itself.

This is not a stylistic choice. `hdiutil attach` takes exclusive access to the image
file and fails with "Resource temporarily unavailable" if any other process holds an
`flock` on it, our own included; locking the image would make the tool unable to attach
the file it had just locked. The lock file gives the same guarantee, keeps hdiutil out
of the way, and leaves nothing behind next to the user's image.

The lock is held for the whole run, which is also what makes stale-attachment recovery
safe: an attachment found while we hold the lock cannot belong to a live run.

### 4.3 Stale attachment recovery

Because a host may `SIGKILL` an unresponsive process, SimpleShrink is idempotent at
startup: run `hdiutil info -plist`, and if the target image path is already attached,
detach it before proceeding. If the detach fails, abort with exit code 3 rather than
operating on a possibly-buffered device. Holding the run lock (§4.2) means an
attachment found at this point cannot belong to another live run.

### 4.4 Choosing the device node

e2fsprogs is run against the **buffered block device** `/dev/diskNsM`, not the raw
character device. Raw device I/O on macOS must be sector-aligned; while ext4's 4 KiB
blocks and 1 KiB superblock at offset 1024 happen to be aligned, not every access
e2fsprogs makes is guaranteed to be. The buffered node removes the question, and
performance against an hdiutil-backed device is adequate.

If milestone S1 shows the buffered node misbehaving, the fallback is `--extract-mode`:
copy the partition into a temporary file, resize the file, copy it back. Correct but
costs the partition size in scratch space and two extra passes. It is implemented
regardless — it is also the easiest way to reproduce a bug outside the hdiutil path.

---

## 5. Partition table handling

### 5.1 MBR layout

Four 16-byte entries at offsets `0x1BE`, `0x1CE`, `0x1DE`, `0x1EE`; signature
`0x55 0xAA` at `0x1FE`.

| Offset | Size | Field |
|---|---|---|
| +0x00 | 1 | Boot flag |
| +0x01 | 3 | CHS start |
| +0x04 | 1 | Partition type |
| +0x05 | 3 | CHS end |
| +0x08 | 4 | LBA start, little-endian u32 |
| +0x0C | 4 | Sector count, little-endian u32 |

Sector size is 512 for these images; version 1 refuses anything else.

### 5.2 Partition identification

* **Boot partition**: the first entry with type `0x01`, `0x04`, `0x06`, `0x0B`, `0x0C` or
  `0x0E`.
* **Root partition**: the last entry by LBA start with type `0x83`.
* Refuse if: the signature is absent; the root partition is not the last partition on the
  medium by LBA; entries overlap; an extended partition (`0x05`, `0x0F`, `0x85`) is
  present; the table is a protective MBR for GPT (single entry of type `0xEE`); or the
  table claims more sectors than the file holds.

### 5.3 Rewriting

Only the **sector count** field of the root entry changes. The LBA start is untouched,
and so is every other byte of the sector — bootstrap code and disk signature included.
A test asserts that exactly those four bytes differ.

CHS fields are left exactly as found. Modern images already carry the `0xFE 0xFF 0xFF`
overflow marker, and both the Raspberry Pi bootloader and Linux ignore CHS. Rewriting CHS
is a source of bugs with no benefit.

New sector count:

```
newSectors = ceil(fsBlockCount * fsBlockSize / sectorSize)
```

`fsBlockCount` and `fsBlockSize` come from `dumpe2fs -h` **after** the resize, never from
the value we requested — resize2fs may round.

Write the 4 bytes, `fsync`, then truncate to `(rootLBAStart + newSectors) * sectorSize`.

If any step between the MBR snapshot and successful truncation fails, restore the
original 512-byte MBR and leave the file length untouched.

---

## 6. Filesystem handling

### 6.1 Tool invocations

```
e2fsck   -f -y -C 0 <dev>
resize2fs -P    <dev>
resize2fs       <dev> <blocks>
dumpe2fs -h     <dev>
debugfs  -R "stat <path>" <dev>
```

`resize2fs` block counts are in filesystem blocks when given without a suffix. `-C 0`
makes `e2fsck` print completion percentages, which is the only progress any of these
tools reports; `resize2fs` reports none, so its stage advances only at its boundaries.

### 6.2 `e2fsck` exit codes

| Code | Handling |
|---|---|
| 0 | No errors |
| 1 | Errors corrected — continue, log a warning |
| 2 | Errors corrected, reboot recommended — continue, log a warning (meaningless for an image) |
| 4 | Errors left uncorrected — **abort**, exit 2 |
| 8 | Operational error — abort, exit 1 |
| 16 | Usage error — abort, exit 1, this is our bug |
| 32 | Cancelled — exit 4 |
| 128 | Shared library error — abort, exit 3 |

Codes are a bitmask; test with `&`.

### 6.3 Target size and margin

`resize2fs -P` prints `Estimated minimum size of the filesystem: <N>` in filesystem
blocks. It is an estimate and is known to be optimistic.

```
margin  = max(freeSpaceMiB * 1MiB, minimumBytes * 0.05)
target  = minimumBlocks + ceil(margin / blockSize)
```

Default `freeSpaceMiB` is **64**. Never shrink to the bare minimum: an ext4 filesystem at
100 % occupancy is slow, cannot be fsck'd comfortably, and leaves the target system with
nothing to write to before its own resize runs.

If `resize2fs` fails with "New size smaller than minimum", multiply the margin by 1.5 and
retry, up to three attempts, then abort with exit 1.

If the computed target is not at least 32 MiB smaller than the current size, report
success with a `skipped` status and change nothing — a filesystem that is already tight
should not be rewritten.

### 6.4 Refusals

Probe the root slice before touching it. Refuse, with exit 2 and a specific message,
when:

* `dumpe2fs -h` finds no ext2/3/4 superblock;
* the filesystem carries a feature the pinned e2fsprogs release does not know
  (`Ext2Superblock.knownFeatures` is the allowlist; anything outside it means the image
  was made by newer tools than we ship);
* the filesystem has an external journal;
* `e2fsck` reports errors it could not correct.

---

## 7. First-boot expansion

Editing the ext4 root filesystem is unnecessary. The boot partition is FAT, which macOS
mounts natively, and that is enough for both supported strategies.

Mount it explicitly after attaching with `-nomount`:

```
diskutil mount -mountPoint <tmpdir> /dev/diskNs1
diskutil unmount <tmpdir>
```

Always back up `cmdline.txt` to `cmdline.txt.simpleshrink.bak` before the first
modification, and skip arming entirely if the command line is already armed (the image
has been through this before).

### 7.1 Strategy A — Raspberry Pi OS (preferred)

Detect with:

```
debugfs -R "stat /usr/lib/raspi-config/init_resize.sh" /dev/diskNsM
```

If the file exists, edit `cmdline.txt`: remove any existing `init=` token and append
`init=/usr/lib/raspi-config/init_resize.sh`.

That script ships with the `raspi-config` package, remains present after first boot, and
does exactly the required work — extends partition 2 to fill the card, runs `resize2fs`,
reboots, and removes itself from `cmdline.txt`. This is the same mechanism PiShrink uses
on Raspberry Pi OS.

`cmdline.txt` must remain a **single line**. Preserve the existing line ending; do not add
one if the original had none.

### 7.2 Strategy B — generic systemd fallback

For images without `raspi-config` (M5, Armbian, Ubuntu), write `simpleshrink-expand.sh`
to the boot partition and add to `cmdline.txt`:

```
systemd.run=<bootpath>/simpleshrink-expand.sh systemd.run_success_action=reboot systemd.unit=kernel-command-line.target
```

`<bootpath>` is `/boot/firmware` when the root filesystem contains that directory
(Bookworm and newer), otherwise `/boot`. Detect with `debugfs -R "stat /boot/firmware"`.

The script is `Resources/simpleshrink-expand.sh`. It is embedded in the binary as a
string constant, and a test asserts the two copies are byte-identical.

Growing a mounted partition and an online `resize2fs` are both supported by current
kernels — this is what `cloud-init`'s `growpart` does. `systemd.run` requires systemd
v240 or newer.

Strategy B must be validated on real hardware before release; it is marked experimental
in v1.0 — a run that uses it returns a warning in the result — and `--expansion=generic`
selects it explicitly.

### 7.3 If neither applies

Complete the shrink and return `status: "ok"` with a warning that expansion could not be
armed, naming what the user must do manually. Do not fail — a shrunk image is still
useful.

### 7.4 Privilege refusal

If `geteuid() == 0`, exit immediately with code 3 and an explanatory message. Nothing
here needs root, and running as root would let a bug damage the host system.

---

## 8. Command-line interface

```
simpleshrink shrink <image> [options]
simpleshrink inspect <image> [--json] [--free-space <MiB>]
simpleshrink describe --protocol 1
simpleshrink run --protocol 1 --capability shrink
simpleshrink version
```

### 8.1 `shrink` options

| Option | Default | Meaning |
|---|---|---|
| `--free-space <MiB>` | 64 | Slack left in the shrunk filesystem |
| `--output <path>` | — | Write a shrunk copy, leave the input untouched |
| `--expansion <auto\|raspi\|generic\|none>` | `auto` | First-boot expansion strategy |
| `--extract-mode` | off | Copy the partition to scratch space instead of operating on the attached slice |
| `--dry-run` | off | Probe and report the plan; change nothing |
| `--json` | off | NDJSON events on stdout instead of human output |
| `--verbose` | off | e2fsprogs output on stderr |

`--output` copies first, then shrinks the copy, so an interrupted run never damages the
source. On APFS the copy is a clone: instant, and it costs nothing until the copy
diverges. A host should prefer it whenever free space allows.

### 8.2 `inspect`, `describe`, `run`, exit codes

Normatively specified in [`INTEGRATION.md`](INTEGRATION.md) §2, §3 and §6. In summary:
`inspect` reports what an image is and what a shrink would gain, without modifying it;
`describe` prints the manifest; `run` reads one JSON request on stdin and emits NDJSON
events, exactly one of which is terminal and last. Exit codes are `0` success,
`1` generic failure, `2` unsupported input, `3` precondition failed, `4` cancelled,
`5` protocol mismatch.

### 8.3 Progress model

Progress is not linearly measurable — `resize2fs` reports little. Stages own weighted
slices of the bar and interpolate inside them; the reported fraction never decreases.

| Stage | Range |
|---|---|
| `open`, `attach`, `probe` | 0.00 – 0.05 |
| `check` | 0.05 – 0.25 |
| `resize` | 0.25 – 0.80 |
| `verify` | 0.80 – 0.90 |
| `arm`, `detach` | 0.90 – 0.95 |
| `partition`, `truncate` | 0.95 – 1.00 |

Within `check` and `resize`, the percentage e2fsprogs prints is parsed and interpolated.

---

## 9. Repository layout

```
simpleshrink/
├── COPYING                          GPLv2 text
├── README.md                        What it is, install, usage, licence
├── THIRD-PARTY.md                   e2fsprogs version, licence map, build line
├── CHANGELOG.md
├── CONTRIBUTING.md
├── Package.swift
├── docs/
│   ├── SPEC.md                      This document
│   └── INTEGRATION.md               The host interface, normative
├── Sources/
│   ├── simpleshrink/
│   │   ├── main.swift               Entry point, root refusal, dispatch
│   │   ├── SignalHandling.swift     SIGINT/SIGTERM, detach deadline
│   │   └── Commands/                shrink, inspect, describe, run
│   └── SimpleShrinkKit/
│       ├── Version.swift            Product and protocol version
│       ├── ExitCode.swift           Exit codes, error codes, ShrinkError
│       ├── CommandLine.swift        Hand-rolled parser (see §2.1)
│       ├── DiskImage.swift          MBR snapshot/restore, truncation
│       ├── ImageLock.swift          One run per image, without locking the image
│       ├── MBR.swift                Partition table parsing and rewriting
│       ├── Shell.swift              Process runner, cancellation flag
│       ├── HDIUtil.swift            attach/detach/info, plist decoding
│       ├── E2fsprogs.swift          Tool discovery, invocation, output parsing
│       ├── Sizing.swift             Target size and margins
│       ├── Expansion.swift          cmdline.txt editing, both strategies
│       ├── Extract.swift            --extract-mode partition copy
│       ├── ShrinkPipeline.swift     Orchestration, stages, rollback
│       ├── Inspector.swift          Read-only examination
│       ├── Protocol.swift           Request/event/manifest types
│       ├── EventSink.swift          NDJSON, console and recording sinks
│       └── Progress.swift           Stage weighting
├── Resources/
│   └── simpleshrink-expand.sh       Strategy B script
├── Tests/SimpleShrinkKitTests/
├── vendor/e2fsprogs/                Pinned version, checksum, patches
├── Scripts/
│   ├── build-e2fsprogs.sh
│   ├── make-fixture.sh
│   ├── integration-test.sh
│   └── package.sh
├── integration/manifest.json.in
└── .github/workflows/ci.yml
```

### 9.1 Tool discovery

`E2fsprogs.locate()` finds the binaries relative to the executable:
`../libexec/e2fsprogs`, then `libexec/e2fsprogs`. **`PATH` is never searched** — a
`PATH`-resolved `resize2fs` is an obvious hijack vector. `SIMPLESHRINK_E2FSPROGS_DIR`
overrides the search for development and CI. Fail with exit 3 and a specific message if a
tool is missing or not executable.

---

## 10. Building e2fsprogs

The pinned release lives in `vendor/e2fsprogs/PINNED` (version, URL, SHA-256).
`Scripts/build-e2fsprogs.sh`:

1. Downloads and verifies the tarball, applies every patch in
   `vendor/e2fsprogs/patches/`.
2. Builds twice, once per architecture:
   ```
   ./configure --host=arm64-apple-darwin CC="clang -arch arm64" \
       --disable-nls --disable-fsck --disable-uuidd --disable-e2initrd-helper \
       --disable-elf-shlibs --disable-bsd-shlibs
   ```
   and the `x86_64-apple-darwin` equivalent.
3. `lipo -create`s the two results.
4. Installs `e2fsck`, `resize2fs`, `dumpe2fs`, `debugfs` into `libexec/e2fsprogs/`.
5. `mke2fs` is built for the test fixtures but **not shipped**, keeping the release
   surface small.

Static linkage against e2fsprogs' own libraries is the default — do not enable
`--enable-elf-shlibs`, so each binary is self-contained and needs no `@rpath` fixups.

The exact configure line is recorded in `THIRD-PARTY.md`; it is part of the
"corresponding source" obligation.

---

## 11. Distribution

**Ship a self-signed universal tarball**, built by `Scripts/package.sh`:

```
SimpleShrink-1.0.0/
├── bin/simpleshrink
├── libexec/e2fsprogs/{e2fsck,resize2fs,dumpe2fs,debugfs}
├── share/{COPYING,THIRD-PARTY.md,README.md,INTEGRATION.md}
├── manifest.json
└── install.sh
```

`install.sh` copies the tree to `~/Library/Application Support/SimpleShrink` and can
symlink `bin/simpleshrink` into `/usr/local/bin`. `bin/` and `libexec/` must stay
siblings — that relative layout is how the tool finds e2fsprogs (§9.1).

Every Mach-O in the payload is signed: ad-hoc (`codesign -s -`) by default, or with a
self-signed certificate when one is passed. arm64 requires *a* signature, and signing
everything keeps the payload uniform.

### 11.1 No notarisation, and what that costs

There is deliberately no Developer ID signature, no notarisation and no `.pkg`.

Notarisation requires a paid Apple Developer membership, and what it buys is one thing:
an archive that opens by double-click after a browser download. For a GPL-2.0-only tool
whose primary install path is "clone it and run `swift build`", routing every release
through Apple to make it look trustworthy is disproportionate — the source, the pinned
e2fsprogs checksum and the published SHA-256 of the archive are the trust story.

The cost is Gatekeeper, and it is worth stating plainly rather than discovering:

* A browser marks the downloaded archive `com.apple.quarantine`. Archive Utility
  **propagates that flag to every extracted file**, and Gatekeeper then refuses to run
  the binaries.
* Unpacking with `tar` in a terminal does not propagate it, which is why the release
  notes give the `tar -xzf` line rather than saying "double-click".
* `install.sh` clears the flag from what it installs, for anyone who unpacked the
  archive the other way.

A `.pkg` would not avoid any of this without a Developer ID Installer certificate — an
unsigned one is blocked by Gatekeeper just the same, while adding `pkgbuild`,
`productbuild` and a distribution XML to maintain.

If a friction-free install becomes worth having later, a Homebrew tap is the cheaper
answer than notarisation: `brew` builds or unpacks without setting quarantine at all.

### 11.2 Release checklist

* `Scripts/package.sh` refuses to build a tagged release whose tag disagrees with
  `Version.swift`.
* The archive ships with a `.sha256` file; publish that checksum in the release notes.
* Publish the corresponding e2fsprogs source alongside the binaries, per §2.3.

## 12. Testing

Everything can be tested on macOS with no Linux involved, because our own `mke2fs`
creates the fixtures.

### 12.1 Fixture generation (`Scripts/make-fixture.sh`)

1. Create a sparse file of the target size.
2. Write an MBR (the script writes the 16-byte entries directly).
3. `hdiutil attach -nomount`.
4. `newfs_msdos` the FAT slice and write a `cmdline.txt`; `mke2fs -t ext4 -d <content-dir>`
   the Linux slice — `mke2fs -d` populates from a directory without mounting anything.
5. Detach.

### 12.2 Unit tests (`swift test`, no e2fsprogs needed)

Partition table parsing, every refusal, surgical rewriting, image locking, rollback,
truncation, `cmdline.txt` editing in all its variants, target-size arithmetic, progress
monotonicity, `hdiutil` plist decoding, e2fsprogs output parsing, protocol decoding and
event shapes, argument parsing.

### 12.3 End-to-end (`Scripts/integration-test.sh`)

Against a real fixture image: `inspect`, a dry run that changes nothing, a shrink, an
`e2fsck -f -n` of the result, the armed `cmdline.txt` and its backup, a second run that
reports `skipped` and changes nothing, and a protocol-mode run.

### 12.4 Still to cover

* Failure injection at each stage, asserting the MBR and file size are restored.
* `SIGTERM` mid-resize: clean detach, no `/dev/diskN` left attached.
* `SIGKILL` mid-resize, then a fresh run recovering the stale attachment (§4.2).
* Fixtures for: nearly empty, half full, tiny free space, `raspi-config` absent with
  `/boot/firmware`, and a deliberately corrupted filesystem.

### 12.5 CI

GitHub Actions on `macos-15`: unit tests, then the end-to-end script against a fixture —
`hdiutil attach` works on the hosted runners. The e2fsprogs build is cached by the
contents of `vendor/e2fsprogs/PINNED`. Packaging runs only on tags and needs no secrets,
because releases are self-signed (§11).

---

## 13. Milestones

| # | Deliverable | Retires |
|---|---|---|
| **S0** | Spike: build e2fsprogs universal; `e2fsck` + `resize2fs` against an hdiutil-attached slice on a hand-made ext4 fixture | The one genuinely unknown risk — that e2fsprogs misbehaves against a macOS block device |
| S1 | `MBR.swift`, `HDIUtil.swift`, `DiskImage.swift`, `inspect` | Table parsing, attach/detach lifecycle |
| S2 | `ShrinkPipeline` end to end with rollback, `shrink` | Core function |
| S3 | `Expansion.swift`, both strategies, fixture coverage | |
| S4 | Integration mode: `describe`, `run`, NDJSON, signal handling | Host integration |
| S5 | Packaging: universal build, self-signed tarball, `install.sh`, checksums | Distribution |
| S6 | Full test matrix, CI, GPL compliance checklist, README | Release |

**S0 gates the project.** If e2fsprogs cannot be made to work reliably against
`/dev/diskNsM`, `--extract-mode` (§4.3) becomes the primary strategy, which changes
performance characteristics but not the design.

---

## 14. Known risks

| Risk | Mitigation |
|---|---|
| e2fsprogs I/O alignment against macOS device nodes | S0 spike; `--extract-mode` fallback |
| `resize2fs -P` underestimates | Margin plus retry with a growing margin (§6.3) |
| `init_resize.sh` behaviour varies across Raspberry Pi OS releases | Test against Bullseye, Bookworm and Trixie images; strategy B as fallback |
| Bookworm moved the boot mount to `/boot/firmware` | Detected via `debugfs` (§7.2) |
| ext4 feature drift (`metadata_csum_seed`, `64bit`) | Refuse unknown features rather than guessing (§6.4) |
| Images where root is not the last partition | Detected and refused (§5.2) |
| Leaked `hdiutil` attachment after a crash | Scope guard, registry, signal handler, startup recovery (§4.3) |
| Apple changes `hdiutil` plist output | Parse defensively; pinned by a decoding test |
