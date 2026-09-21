#!/usr/bin/env bash
# Read a pushed repository back from a node that did not write it.
#
# This is the assertion the five-node cluster exists for, and the only one that
# can tell "published" from "stored locally". The distinction is not academic:
# this project has shipped that bug three times. Phase 1 found a peerless node
# accepting a deferred upload in 30ms and then hanging forever on the feed write,
# and #30 was a push that reported success while the feed never moved. In both
# cases every call returned success and nothing reached the network.
#
# A test that pushes and reads back through the same node cannot catch any of
# that: the node answers from its own store either way.
#
# So: push through the queen, then resolve the feed and download the packs
# through a worker, with no batch and no key. If the data never propagated, the
# worker has nothing to serve and this fails.

set -euo pipefail

HERE="$(cd "$(dirname "$0")/../.." && pwd)"

# Does not source .env — it names a real node and a funded batch, and this pushes.

fail() { echo "FAIL: $*" >&2; exit 1; }
skip() { echo "SKIP: $*" >&2; exit 77; }

command -v git-remote-bzz >/dev/null 2>&1 || skip "git-remote-bzz not on PATH"

API="${SWARM_API:-}"
WORKER="${SWARM_WORKER_API:-}"
[ -n "$API" ]                   || skip "SWARM_API not set"
[ -n "$WORKER" ]                || skip "SWARM_WORKER_API not set (needs a multi-node cluster)"
[ -n "${SWARM_BATCH_ID:-}" ]    || skip "SWARM_BATCH_ID not set"
[ -n "${SWARM_PRIVATE_KEY:-}" ] || skip "SWARM_PRIVATE_KEY not set"
[ -n "${SWARM_OWNER:-}" ]       || skip "SWARM_OWNER not set"

[ "$API" != "$WORKER" ] || fail "writer and reader are the same node; this test would prove nothing"

# Both must be up, and they must really be different nodes. Comparing overlay
# addresses catches a misconfiguration that would otherwise make this pass
# vacuously — the worst outcome available for a test whose whole job is to
# distrust a single node's word.
writer_overlay="$(curl -fsS "$API/addresses" 2>/dev/null \
  | python3 -c 'import json,sys; print(json.load(sys.stdin)["overlay"])' 2>/dev/null || echo '')"
reader_overlay="$(curl -fsS "$WORKER/addresses" 2>/dev/null \
  | python3 -c 'import json,sys; print(json.load(sys.stdin)["overlay"])' 2>/dev/null || echo '')"
[ -n "$writer_overlay" ] || skip "no Bee node at $API"
[ -n "$reader_overlay" ] || skip "no Bee node at $WORKER"
[ "$writer_overlay" != "$reader_overlay" ] \
  || fail "writer and reader report the same overlay address; not two nodes"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

NAME="durability-$(date +%s)-$$"
URL="bzz::${SWARM_OWNER}/${NAME}"

echo "==> writer  ${writer_overlay:0:12}…  at $API"
echo "==> reader  ${reader_overlay:0:12}…  at $WORKER"

SRC="$TMP/src"
git init -q -b main "$SRC"
# Enough content to span more than a token amount of chunks, so propagation is
# actually exercised rather than fitting in a single chunk.
python3 -c "
import random
random.seed(1789)
with open('$SRC/data.txt', 'w') as f:
    for i in range(20000):
        f.write('%06d %s\n' % (i, ''.join(random.choice('abcdef0123456789') for _ in range(48))))
"
printf 'durability probe\n' > "$SRC/README.md"
git -C "$SRC" add -A
git -C "$SRC" -c user.email=t@example.invalid -c user.name=probe commit -qm "probe"
HEAD_SHA="$(git -C "$SRC" rev-parse HEAD)"

echo "==> pushing through the writer"
git -C "$SRC" push -q "$URL" main 2>&1 | sed 's/^/    /' || fail "push failed"

echo "==> reading back through the reader, with no batch and no key"
BACK="$TMP/back.git"
git init -q --bare "$BACK"

# Both SWARM_API and SWARM_GATEWAY: feed resolution goes through the api node
# (it needs /feeds, which a public gateway does not serve) and pack downloads
# through the gateway. Pointing only one of them at the worker would leave the
# writer still serving half the read.
deadline=$(( $(date +%s) + 180 ))
last=''
while :; do
  if last="$(env -u SWARM_BATCH_ID -u SWARM_PRIVATE_KEY \
       SWARM_API="$WORKER" SWARM_GATEWAY="$WORKER" \
       git -C "$BACK" fetch "$URL" 'refs/*:refs/*' 2>&1)"; then
    break
  fi
  if [ "$(date +%s)" -ge "$deadline" ]; then
    echo "$last" >&2
    fail "the writing node reported success, but $WORKER could not serve the repository after 180s"
  fi
  sleep 5
done

got="$(git -C "$BACK" rev-parse refs/heads/main 2>/dev/null || echo '')"
[ "$got" = "$HEAD_SHA" ] || fail "read back $got, expected $HEAD_SHA"
echo "==> a node that never saw the push served it back   ok"

git -C "$BACK" fsck --no-progress --no-dangling >/dev/null 2>&1 \
  || fail "git fsck failed on the copy fetched from the reader"
echo "==> fsck clean                                      ok"

echo
echo "PASS"
