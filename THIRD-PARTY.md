# Third-party software

SimpleShrink itself has **no external Swift package dependencies**. It ships binaries
built from one third-party project.

## e2fsprogs

| | |
|---|---|
| Version | **1.47.4** |
| Upstream | https://e2fsprogs.sourceforge.net/ |
| Source tarball | https://mirrors.edge.kernel.org/pub/linux/kernel/people/tytso/e2fsprogs/v1.47.4/e2fsprogs-1.47.4.tar.xz |
| SHA-256 | `fd5bf388cbdbe006a3d3b318d983b2948382440acc85a87f1e7d108653e8db0b` |
| Patches applied | None. Any patch would live in `vendor/e2fsprogs/patches/` and be applied by `Scripts/build-e2fsprogs.sh`. |

The pin is machine-readable in [`vendor/e2fsprogs/PINNED`](vendor/e2fsprogs/PINNED),
which is what the build script reads.

### Binaries shipped

`libexec/e2fsprogs/e2fsck`, `resize2fs`, `dumpe2fs`, `debugfs` — universal
(`arm64` + `x86_64`), statically linked against e2fsprogs' own libraries.

`mke2fs` is built to create test fixtures and is **not** shipped.

### Licence map

| Component | Licence |
|---|---|
| `e2fsck/`, `resize/`, `debugfs/`, `misc/` (dumpe2fs, mke2fs) | GPL-2.0-only |
| `lib/ext2fs`, `lib/e2p`, `lib/blkid` | LGPL-2.0 |
| `lib/uuid` | BSD-3-Clause |
| `lib/et`, `lib/ss` | MIT-style |

The resize algorithm lives in `resize/`, which is GPL-2.0-only. This is why SimpleShrink
as a whole is GPL-2.0-only: there is no LGPL-only path to this functionality, and a
uniformly licensed project keeps the obligation simple to discharge.

### Exact build

```sh
./configure --host=arm64-apple-darwin CC="clang -arch arm64" \
    --disable-nls --disable-fsck --disable-uuidd --disable-e2initrd-helper \
    --disable-elf-shlibs --disable-bsd-shlibs
make
```

and the `x86_64-apple-darwin` equivalent, then `lipo -create`. This is what
[`Scripts/build-e2fsprogs.sh`](Scripts/build-e2fsprogs.sh) runs; the script is the
authoritative version of this recipe.

### Corresponding source

The GPL obligation for the binaries in a release is satisfied by the pinned tarball URL
and checksum above, together with the (currently empty) patch set and the build script in
this repository — everything needed to reproduce the exact binaries shipped. Release
archives additionally carry the source tarball alongside the package.

## GPLv2 text

[`COPYING`](COPYING) — the verbatim GNU General Public License, version 2, June 1991.
