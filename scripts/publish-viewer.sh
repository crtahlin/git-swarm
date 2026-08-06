#!/usr/bin/env bash
#
# Build the viewer and publish it to its own Swarm feed.
#
#   ./scripts/publish-viewer.sh
#
# The point is the feed. A plain upload mints a new reference on every build, so
# every rebuild invalidates whatever link you gave people — and an ENS record
# pointing at it would need a transaction each time. Behind a feed the address is
# fixed for the life of the topic: publish as often as you like, the URL never
# changes, and an ENS contenthash set to the feed manifest is set once.
#
# The repository gets this for free — git push advances its feed. The viewer is a
# plain directory, so it needs the same treatment applied deliberately.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
[ -f "$HERE/.env" ] && . "$HERE/.env"

BATCH="${SWARM_BATCH_ID:-}"
IDENTITY="${SWARM_FEED_IDENTITY:-swarm-git-poc}"
TOPIC="${SWARM_VIEWER_TOPIC:-swarm-git-viewer}"
GATEWAY="${SWARM_GATEWAY:-https://bzz.limo}"

[ -n "$BATCH" ] || { echo "SWARM_BATCH_ID is not set (see .env.example)" >&2; exit 78; }

echo "==> building"
(cd "$HERE/viewer" && npm run --silent build 2>/dev/null || node build.mjs)

echo "==> publishing to feed '$TOPIC' as identity '$IDENTITY'"
out=$(swarm-cli feed upload "$HERE/viewer/dist" \
  --identity "$IDENTITY" \
  --topic-string "$TOPIC" \
  --index-document index.html \
  --stamp "$BATCH" --yes 2>&1)
echo "$out" | sed 's/^/    /'

FEED=$(echo "$out" | LC_ALL=C grep -i -A1 'feed manifest' | LC_ALL=C grep -Eio '[0-9a-f]{64}' | head -1)
[ -n "$FEED" ] || { echo "could not determine the feed manifest reference" >&2; exit 70; }

cat <<EOF

════════════════════════════════════════════════════════════════
Viewer feed manifest: $FEED

This address is stable. Rebuild and re-run this script as often as
you like — it keeps pointing at the newest build.

  $GATEWAY/bzz/$FEED/#bzz/<repo-feed-manifest>

For a name, set an ENS contenthash to bzz://$FEED once.
════════════════════════════════════════════════════════════════
EOF
