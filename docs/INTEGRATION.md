# SimpleShrink integration interface

SimpleShrink is a standalone command-line tool. It is also built to be driven by other
software — a GUI, an imaging workflow, a build server, a Makefile — and this document is
the normative description of that interface. Nothing here is specific to any particular
host application: anything that can start a process and read its standard output can
integrate SimpleShrink.

There are three ways in, in increasing order of coupling:

| Way in | Use it when |
|---|---|
| **Plain CLI** — `simpleshrink shrink image.img`, read the exit code | A script, a Makefile, CI |
| **Protocol mode** — `describe` and `run`, NDJSON on stdout | An application that wants progress, structured results and localisation |
| **Swift library** — `import SimpleShrinkKit` | A macOS app willing to inherit GPL-2.0-only |

Everything below is stable within protocol version 1. See [Versioning](#8-versioning).

---

## 1. Installing and finding the tool

A release is a tarball that unpacks to:

```
<install root>/
├── bin/simpleshrink              The executable
├── libexec/e2fsprogs/            e2fsck, resize2fs, dumpe2fs, debugfs
├── manifest.json                 Machine-readable description (see §2)
├── share/                        COPYING, THIRD-PARTY.md, README.md, INTEGRATION.md
└── install.sh                    Copies the tree into place, optionally symlinks it
```

The default install root is `~/Library/Application Support/SimpleShrink`, and
`install.sh --link` symlinks `bin/simpleshrink` into `/usr/local/bin`.

`bin/simpleshrink` finds its e2fsprogs binaries at `../libexec/e2fsprogs` relative to
itself. **`PATH` is never searched** — a `PATH`-resolved `resize2fs` running against a
user's image is a hijack this tool must not be vulnerable to. A host that relocates the
binaries must keep that relative layout, or set `SIMPLESHRINK_E2FSPROGS_DIR`.

A host should invoke the executable by absolute path, with a controlled environment.

**The binaries are self-signed, not notarised.** A host that ships or copies them itself
must make sure they do not carry `com.apple.quarantine` — Gatekeeper refuses to execute
quarantined code that has no Developer ID, and the failure surfaces as the process
dying rather than as an error this tool can report. Copying with `cp` preserves the
flag if the source has it; `xattr -dr com.apple.quarantine <install root>` clears it,
and that is what the bundled `install.sh` does.

## 2. Discovery — `describe`

```
$ simpleshrink describe --protocol 1
```

Prints one JSON object on stdout and exits 0, or exits 5 if this build does not
implement the requested protocol version:

```json
{
  "identifier": "cz.optosmart.simpleshrink",
  "name": "SimpleShrink",
  "version": "1.0.0",
  "protocol": 1,
  "license": "GPL-2.0-only",
  "homepage": "https://github.com/optosmart/simpleshrink",
  "platform": "macOS 15+, universal (arm64, x86_64)",
  "requiresPrivileges": false,
  "capabilities": [
    {
      "id": "shrink",
      "verb": "transform",
      "appliesTo": ["image"],
      "titles": { "en": "Shrink disk image", "cs": "Zmenšit obraz disku" },
      "options": ["freeSpaceMiB", "expansion", "armExpansion", "outputPath",
                  "extractMode", "dryRun"]
    }
  ]
}
```

`titles` carries display names per BCP-47 language tag; fall back to `en`. The installed
`manifest.json` is the same object plus an `executable` key giving the path of the
binary relative to the install root, so a host can find the tool before running it.

`requiresPrivileges` is `false` and will stay false: **the tool refuses to run as root**
(exit 3). Nothing it does needs privileges — `hdiutil attach -nomount` exposes the
partitions to the invoking user — and running privileged would let a bug reach the host
system.

## 3. Invocation — `run`

```
$ simpleshrink run --protocol 1 --capability shrink < request.json
```

The tool reads **one JSON object from stdin until EOF**. The host must close stdin.

### 3.1 Request

```json
{
  "protocol": 1,
  "capability": "shrink",
  "requestId": "job-7",
  "input": { "path": "/Users/me/images/pi.img" },
  "options": {
    "freeSpaceMiB": 64,
    "expansion": "auto",
    "outputPath": null,
    "extractMode": false,
    "dryRun": false
  }
}
```

| Field | Type | Default | Meaning |
|---|---|---|---|
| `protocol` | int | — | Must equal the version this build implements, or exit 5 |
| `capability` | string | `"shrink"` | Must match `--capability` |
| `requestId` | string | absent | Opaque; the host's own correlation id |
| `input.path` | string | — | Absolute path to an image file |
| `options.freeSpaceMiB` | int | 64 | Slack left in the shrunk filesystem |
| `options.expansion` | string | `"auto"` | `auto`, `raspi`, `generic`, `none` |
| `options.armExpansion` | bool | — | Accepted instead of `expansion`: `true` → `auto`, `false` → `none` |
| `options.outputPath` | string | null | Shrink a copy at this path; leave the input untouched |
| `options.extractMode` | bool | false | Resize via scratch space instead of the attached slice |
| `options.dryRun` | bool | false | Report the plan; change nothing |

Unknown keys are ignored, so a newer host can talk to an older build as long as the
protocol version matches.

### 3.2 Events

stdout carries **NDJSON**: one JSON object per line, nothing else. stderr carries
human-readable logging and is safe to discard or to show in a console pane.

```json
{"type":"progress","stage":"resize","fraction":0.42,"message":"Resizing the filesystem"}
{"type":"log","level":"warning","message":"e2fsck corrected errors on the root filesystem."}
{"type":"result","result":{ … }}
{"type":"error","code":"UNSUPPORTED_IMAGE","message":"This is a GPT image (the MBR is protective only)."}
```

Guarantees a host may rely on:

* **Exactly one terminal event** — `result` or `error` — and it is the **last** line.
* `fraction` is 0…1 and **never decreases**, including across internal retries.
* `stage` is one of `open`, `attach`, `probe`, `check`, `resize`, `verify`, `arm`,
  `detach`, `partition`, `truncate`, `done`. Use it to label a UI rather than parsing
  `message`, which is prose and may change.
* Every line is a complete JSON object; lines are never interleaved or split.

`result`:

```json
{
  "status": "ok",
  "imagePath": "/Users/me/images/pi.img",
  "bytesBefore": 13286604800,
  "bytesAfter": 2680160256,
  "filesystemBlocksBefore": 3177216,
  "filesystemBlocksAfter": 628827,
  "blockSize": 4096,
  "expansionArmed": "raspi",
  "warnings": []
}
```

`status` is `ok` (the image was shrunk), `skipped` (nothing worth gaining; the image was
not touched) or `planned` (a dry run). `warnings` is a possibly-empty list of strings
worth showing the user — a shrink that succeeded but could not arm expansion reports
`ok` with a warning, because a shrunk image is still useful.

`error` codes: `FAILED`, `UNSUPPORTED_IMAGE`, `PRECONDITION_FAILED`, `CANCELLED`,
`PROTOCOL_MISMATCH`.

### 3.3 Exit codes

| Code | Meaning | Terminal event |
|---|---|---|
| 0 | Success, including `skipped` and `planned` | `result` |
| 1 | Generic failure | `error` `FAILED` |
| 2 | The input is not something this tool can process | `error` `UNSUPPORTED_IMAGE` |
| 3 | Precondition failed: missing tools, locked file, running as root | `error` `PRECONDITION_FAILED` |
| 4 | Cancelled by signal | `error` `CANCELLED` |
| 5 | Protocol version or capability mismatch | `error` `PROTOCOL_MISMATCH` |

The exit code alone is enough for a host that does not parse the event stream.

## 4. Cancellation

Send **SIGINT or SIGTERM**. The run stops at the next stage boundary, detaches the
image, emits `{"type":"error","code":"CANCELLED"}` and exits 4.

If the pipeline has not unwound within 20 seconds the process detaches whatever is still
attached and exits 4 anyway — being killed with a device attached is the one outcome
worth avoiding.

A host that resorts to **SIGKILL** leaves an `hdiutil` attachment behind. That is
recoverable and does not damage the image: the next run detects the stale attachment,
detaches it, and proceeds — or refuses with exit 3 if it cannot. The image itself is
never in an inconsistent state at that point, because the partition table is rewritten
and the file truncated only after a clean detach.

## 5. Concurrency

SimpleShrink holds a lock for the whole run, keyed by the resolved image path. A second
run against the same image fails immediately with exit 3 rather than waiting; different
images may be processed in parallel.

The lock is a file in the user's cache directory
(`~/Library/Caches/cz.optosmart.simpleshrink/locks/`), **not** an `flock` on the image —
`hdiutil` refuses to attach an image any other process has locked, so locking the image
would defeat the tool. A host that wants its own mutual exclusion should key it the same
way, by resolved path, and must not hold an `flock` on the image while SimpleShrink
runs.

## 6. Examining an image first — `inspect`

`inspect` never modifies anything. Use it to decide whether to offer a shrink at all,
and what it would gain:

```
$ simpleshrink inspect image.img --json
```

```json
{
  "supported": true,
  "scheme": "mbr",
  "sectorSize": 512,
  "imageBytes": 13286604800,
  "partitions": [
    {"index": 1, "type": "0x0c", "fs": "fat32", "startLBA": 8192, "sectors": 524288, "bytes": 268435456},
    {"index": 2, "type": "0x83", "fs": "linux", "startLBA": 532480, "sectors": 25417728, "bytes": 13013876736}
  ],
  "root": {"index": 2, "blockSize": 4096, "blockCount": 3177216, "freeBlocks": 2564883,
           "minimumBlocks": 612443, "clean": true, "features": ["has_journal", "extent", "64bit"]},
  "estimatedBytesAfter": 2680160256,
  "expansionStrategy": "raspi",
  "requiresCheck": false,
  "reason": null
}
```

`supported: false` comes with a `reason` and exit code 2. `requiresCheck: true` means
the filesystem is dirty and its minimum size cannot be estimated without a repair;
`minimumBlocks` and `estimatedBytesAfter` are then null. `inspect` will not repair a
filesystem behind the user's back.

## 7. Embedding the library

`SimpleShrinkKit` exposes the same pipeline as Swift API:

```swift
import SimpleShrinkKit

let tools = try E2fsprogs.locate()          // finds ../libexec/e2fsprogs
let sink = MyEventSink()                    // conform to EventSink
let report = try ShrinkPipeline(tools: tools, sink: sink)
    .run(ShrinkRequest(input: .init(path: url.path),
                       options: ShrinkOptions(freeSpaceMiB: 64)))
```

Linking the library makes your application a derivative work of GPL-2.0-only code.
Running the executable as a separate process does not. If your product cannot be
GPL-licensed, use protocol mode — that is what it is for.

## 8. Versioning

* The **protocol version** changes only when a change would break an existing host.
  Adding an optional request key, an event field, a `stage` token or a warning is not
  breaking, and does not bump it.
* A build implements exactly one protocol version and refuses any other with exit 5,
  so a mismatch is loud rather than subtle.
* The **product version** (`describe` → `version`) follows semantic versioning and moves
  independently.

A host should call `describe --protocol 1` once at startup and treat exit 5 as "this
installation is not usable", not as a failure of the user's image.
