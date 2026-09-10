# Contributing

Bug reports, fixtures that break the tool, and patches are all welcome.

## Licence

The project is **GPL-2.0-only** and contributions are accepted on that basis. Every
source file carries the short header the existing files use.

**No Apache-2.0 dependencies.** Apache-2.0 adds restrictions GPLv2 does not permit, which
is why the argument parser is hand-written rather than `swift-argument-parser`. The
project has no external Swift package dependencies and is meant to keep it that way.

## Getting set up

```console
$ swift build
$ swift test                      # unit tests; no e2fsprogs needed
$ Scripts/build-e2fsprogs.sh      # once, for anything end-to-end
$ export SIMPLESHRINK_E2FSPROGS_DIR="$PWD/libexec/e2fsprogs"
$ Scripts/integration-test.sh
```

`Scripts/make-fixture.sh` builds test images on macOS with no Linux involved — our own
`mke2fs` writes the filesystem.

## What a change needs

* **A test.** Parsing, refusals, sizing arithmetic and protocol shapes are all unit
  testable without an image; anything that touches a real image belongs in
  `Scripts/integration-test.sh`.
* **A reason.** Comments explain why, not what. The existing code is written that way,
  and the specification records the reasoning behind each design decision — if your
  change contradicts [docs/SPEC.md](docs/SPEC.md), update the spec in the same commit.
* **The safety ordering intact.** Destructive steps happen last, after a clean detach,
  and roll back. A change that moves a write earlier needs to argue for itself.
* **No `PATH` lookups** for the e2fsprogs binaries, and no code path that requires root.

## Interface changes

[docs/INTEGRATION.md](docs/INTEGRATION.md) is a contract other software depends on.
Adding an optional request key, an event field, a stage token or a warning is
backwards-compatible. Anything that would break an existing host bumps the protocol
version — and that is a decision to raise in an issue first.

## Commit and PR style

One logical change per commit, present tense, first line under 72 characters. Say what
changed and why in the body. CI runs unit tests and an end-to-end shrink of a generated
fixture on `macos-15`; both must pass.
