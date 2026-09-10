#!/bin/bash
# SimpleShrink — Copyright (C) 2026 OptoSmart. GPL-2.0-only, see COPYING.
#
# End-to-end check against a real image, on macOS, with no Linux involved: build a
# fixture, shrink it, and prove the result is still a valid filesystem in a valid
# partition table — then prove a second run changes nothing.
#
#   Scripts/integration-test.sh
#
# Needs Scripts/build-e2fsprogs.sh to have run first.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export SIMPLESHRINK_E2FSPROGS_DIR="${SIMPLESHRINK_E2FSPROGS_DIR:-$ROOT/libexec/e2fsprogs}"
BIN="${SIMPLESHRINK_BIN:-$(swift build --package-path "$ROOT" --show-bin-path)/simpleshrink}"

[ -x "$BIN" ] || { echo "build simpleshrink first: swift build" >&2; exit 1; }
[ -x "$SIMPLESHRINK_E2FSPROGS_DIR/resize2fs" ] || {
    echo "run Scripts/build-e2fsprogs.sh first" >&2; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
IMAGE="$WORK/fixture.img"

echo "==> Building a 2 GiB fixture with raspi-config present"
"$ROOT/Scripts/make-fixture.sh" "$IMAGE" --size 2048 --raspi

before_bytes=$(stat -f%z "$IMAGE")

echo "==> inspect"
"$BIN" inspect "$IMAGE" --json | tee "$WORK/inspect.json"
python3 -c "
import json, sys
report = json.load(open('$WORK/inspect.json'))
assert report['supported'], report
assert report['scheme'] == 'mbr'
assert report['root']['index'] == 2
print('    inspect looks right')
"

echo "==> dry run changes nothing"
"$BIN" shrink "$IMAGE" --dry-run >/dev/null
[ "$(stat -f%z "$IMAGE")" = "$before_bytes" ] || { echo "dry run resized the image" >&2; exit 1; }

echo "==> shrink"
"$BIN" shrink "$IMAGE" --json | tee "$WORK/events.ndjson"
python3 -c "
import json
events = [json.loads(line) for line in open('$WORK/events.ndjson') if line.strip()]
terminal = [e for e in events if e['type'] in ('result', 'error')]
assert len(terminal) == 1, terminal
assert terminal[0] == events[-1], 'the terminal event must come last'
assert terminal[0]['type'] == 'result', terminal[0]
result = terminal[0]['result']
assert result['status'] == 'ok', result
assert result['bytesAfter'] < result['bytesBefore'], result
fractions = [e['fraction'] for e in events if e['type'] == 'progress']
assert fractions == sorted(fractions), 'progress went backwards'
print('    saved', result['bytesBefore'] - result['bytesAfter'], 'bytes')
"

after_bytes=$(stat -f%z "$IMAGE")
[ "$after_bytes" -lt "$before_bytes" ] || { echo "the file did not shrink" >&2; exit 1; }

echo "==> the shrunk image is still valid"
DEVICE="$(hdiutil attach -imagekey diskimage-class=CRawDiskImage -nomount "$IMAGE" | head -1 | awk '{print $1}')"
trap 'hdiutil detach "$DEVICE" >/dev/null 2>&1 || true; rm -rf "$WORK"' EXIT
"$SIMPLESHRINK_E2FSPROGS_DIR/e2fsck" -f -n "${DEVICE}s2"

MOUNT="$WORK/boot"
mkdir -p "$MOUNT"
diskutil mount -mountPoint "$MOUNT" "${DEVICE}s1" >/dev/null
grep -q 'init=/usr/lib/raspi-config/init_resize.sh' "$MOUNT/cmdline.txt" \
    || { echo "first-boot expansion was not armed" >&2; exit 1; }
[ -f "$MOUNT/cmdline.txt.simpleshrink.bak" ] || { echo "no cmdline.txt backup" >&2; exit 1; }
diskutil unmount "$MOUNT" >/dev/null
hdiutil detach "$DEVICE" >/dev/null
trap 'rm -rf "$WORK"' EXIT

echo "==> a second run is a no-op"
"$BIN" shrink "$IMAGE" --json > "$WORK/again.ndjson"
python3 -c "
import json
events = [json.loads(line) for line in open('$WORK/again.ndjson') if line.strip()]
result = events[-1]
assert result['type'] == 'result', result
assert result['result']['status'] == 'skipped', result
print('    second run reported', result['result']['status'])
"
[ "$(stat -f%z "$IMAGE")" = "$after_bytes" ] || { echo "the second run changed the file" >&2; exit 1; }

echo "==> protocol mode"
printf '{"protocol":1,"capability":"shrink","input":{"path":"%s"},"options":{"dryRun":true}}' "$IMAGE" \
    | "$BIN" run --protocol 1 --capability shrink > "$WORK/protocol.ndjson"
python3 -c "
import json
events = [json.loads(line) for line in open('$WORK/protocol.ndjson') if line.strip()]
assert events[-1]['type'] == 'result', events[-1]
assert events[-1]['result']['status'] == 'planned', events[-1]
print('    protocol mode ok')
"

echo "==> all good"
