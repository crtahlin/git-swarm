#!/usr/bin/env bash
#
# swarm-git-mirror — publish a Git repository to Swarm as a static tree that stock
# `git` can clone over the dumb-HTTP transport.
#
#   ./scripts/swarm-git-mirror.sh <repo-path-or-url> [name]
#
# The result is two clone URLs:
#   - a feed URL, stable across republishes (the feed is a signed single-owner chunk,
#     so only the holder of the identity key can move it)
#   - an immutable snapshot URL, pinned to exactly this state of the repository
#
# Configuration comes from .env (see .env.example).

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
[ -f "$HERE/.env" ] && . "$HERE/.env"

BEE_API="${BEE_API:-http://localhost:1633}"
SWARM_GATEWAY="${SWARM_GATEWAY:-https://download.gateway.ethswarm.org}"
SWARM_FEED_IDENTITY="${SWARM_FEED_IDENTITY:-}"

SOURCE="${1:-}"
if [ -z "$SOURCE" ]; then
  echo "usage: $0 <repo-path-or-url> [name]" >&2
  exit 64
fi

NAME="${2:-$(basename "${SOURCE%.git}")}"
WORK="$HERE/work/$NAME.git"

if [ -z "${SWARM_BATCH_ID:-}" ]; then
  echo "error: SWARM_BATCH_ID is not set. Buy a batch and put it in .env:" >&2
  echo "  swarm-cli stamp buy --depth 19 --amount 8423654400" >&2
  exit 78
fi

# Swarm storage is rented. Refuse to publish onto a batch that is about to expire,
# rather than producing a URL that quietly dies.
ttl=$(curl -sf -m 10 "$BEE_API/stamps/$SWARM_BATCH_ID" | python3 -c 'import sys,json; print(json.load(sys.stdin).get("batchTTL",-1))' 2>/dev/null || echo "-1")
if [ "$ttl" = "-1" ]; then
  echo "error: batch $SWARM_BATCH_ID is not usable yet (or does not exist)." >&2
  echo "       A freshly bought batch needs a couple of minutes to be confirmed." >&2
  exit 75
fi
printf 'batch %s — TTL %s hours\n' "${SWARM_BATCH_ID:0:12}…" "$((ttl / 3600))"

# ---------------------------------------------------------------------------
# 1. Stage a bare mirror of the repository
# ---------------------------------------------------------------------------
mkdir -p "$HERE/work"
if [ -d "$WORK" ]; then
  echo "==> updating existing mirror $WORK"
  git --git-dir="$WORK" remote update --prune
else
  echo "==> cloning $SOURCE into $WORK"
  git clone --quiet --mirror "$SOURCE" "$WORK"
fi

# ---------------------------------------------------------------------------
# 2. Repack, and generate the files the dumb-HTTP protocol needs
#
# Pack layout is not cosmetic: a client fetching thousands of loose objects over
# Swarm would be unusably slow. `update-server-info` writes info/refs and
# objects/info/packs, which is how a dumb-HTTP client discovers what is there.
# ---------------------------------------------------------------------------
echo "==> repacking and writing server info"
git --git-dir="$WORK" repack -a -d -q
git --git-dir="$WORK" update-server-info
rm -rf "$WORK/hooks"   # sample hooks are dead weight in the manifest

if [ ! -s "$WORK/info/refs" ] || [ ! -s "$WORK/objects/info/packs" ]; then
  echo "error: info/refs or objects/info/packs missing — dumb HTTP will not work" >&2
  exit 70
fi

size=$(du -sh "$WORK" | cut -f1)
echo "    mirror size: $size"

# ---------------------------------------------------------------------------
# 3. Upload to Swarm
# ---------------------------------------------------------------------------
echo "==> uploading to Swarm"
upload_out=$(swarm-cli upload "$WORK" --stamp "$SWARM_BATCH_ID" --yes 2>&1)
echo "$upload_out" | sed 's/^/    /'
SNAPSHOT=$(echo "$upload_out" | grep -Eio '[0-9a-f]{64}' | head -1)

FEED_MANIFEST=""
if [ -n "$SWARM_FEED_IDENTITY" ]; then
  echo "==> updating feed (topic: $NAME)"
  feed_out=$(swarm-cli feed upload "$WORK" \
    --identity "$SWARM_FEED_IDENTITY" \
    --topic-string "$NAME" \
    --stamp "$SWARM_BATCH_ID" --yes 2>&1)
  echo "$feed_out" | sed 's/^/    /'
  FEED_MANIFEST=$(echo "$feed_out" | grep -i -A1 'feed manifest' | grep -Eio '[0-9a-f]{64}' | head -1)
fi

# ---------------------------------------------------------------------------
# 4. Report
# ---------------------------------------------------------------------------
echo
echo "================================================================"
echo "Repository:        $NAME"
echo "Snapshot (fixed):  $SNAPSHOT"
[ -n "$FEED_MANIFEST" ] && echo "Feed (stable):     $FEED_MANIFEST"
echo
echo "Clone it with stock git, no Bee node required:"
[ -n "$FEED_MANIFEST" ] && echo "  git clone $SWARM_GATEWAY/bzz/$FEED_MANIFEST/ $NAME"
echo "  git clone $SWARM_GATEWAY/bzz/$SNAPSHOT/ $NAME"
echo "================================================================"
