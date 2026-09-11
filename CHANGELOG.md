# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project follows
[semantic versioning](https://semver.org/).

## [1.0.0] — unreleased

First release.

### Added

* `shrink` — shrink the ext4 root filesystem of an MBR image, rewrite the partition
  table and truncate the file, with rollback of the partition table if anything between
  the first write and the truncation fails.
* First-boot expansion, armed by editing `cmdline.txt` on the FAT boot partition:
  the Raspberry Pi OS `init_resize.sh` strategy, and an experimental generic
  `systemd.run=` strategy for images without raspi-config.
* `inspect` — read-only report of what an image is and what a shrink would gain,
  human-readable or `--json`.
* `--dry-run`, `--output <path>`, `--free-space <MiB>`, `--expansion`, `--extract-mode`.
* Host integration interface, version 1: `describe` and `run`, one JSON request on
  stdin, NDJSON events on stdout, documented exit codes. See
  [docs/INTEGRATION.md](docs/INTEGRATION.md).
* `SimpleShrinkKit`, the same pipeline as a Swift library.
* Refusals with specific messages for GPT, extended partitions, a root partition that is
  not last, overlapping entries, non-ext filesystems, external journals, unknown
  filesystem features, an image another run is already working on, and running as root.
* Recovery from an `hdiutil` attachment left behind by a killed run.
* `Scripts/build-e2fsprogs.sh`, `make-fixture.sh`, `integration-test.sh`, and
  `package.sh`, which builds a universal, self-signed tarball with an `install.sh` and a
  published SHA-256. Releases are not notarised — see [docs/SPEC.md §11](docs/SPEC.md).
* A GitHub Actions workflow that runs unit tests, an end-to-end shrink of a generated
  fixture, and packaging on tags.

### Verified

* End-to-end on macOS 26.4 against a generated 2 GiB fixture: shrink, `e2fsck -f -n` of
  the result, armed `cmdline.txt` with its backup, a second run reporting `skipped`, and
  a protocol-mode run. `Scripts/integration-test.sh` is that check.

### Known limitations

* The generic systemd expansion strategy is experimental and returns a warning; verify a
  first boot before relying on it.
* GPT images, non-ext filesystems, and images whose Linux partition is not last are out
  of scope for 1.x.
