# Vendored e2fsprogs

SimpleShrink does not reimplement ext2/3/4 resizing. It builds and ships the upstream
e2fsprogs tools and drives them.

* Version, source URL and SHA-256 are pinned in [`PINNED`](PINNED).
* `Scripts/build-e2fsprogs.sh` downloads that exact tarball, verifies the checksum,
  applies every patch in [`patches/`](patches/) in filename order, builds once per
  architecture and `lipo`s the results into a universal binary.
* Only `e2fsck`, `resize2fs`, `dumpe2fs` and `debugfs` are installed into
  `libexec/e2fsprogs/`. `mke2fs` is built for the test fixtures and not shipped.

There are currently no patches. If one is ever added it lives here, in the repository,
because the GPL obligation covers the corresponding source of the binaries we ship —
patches included.

The source tarball itself is not committed: it is large, and pinning the URL with a
checksum is equivalent for reproducibility. Release archives carry the source
alongside the binaries, see `THIRD-PARTY.md`.
