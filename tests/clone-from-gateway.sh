#!/usr/bin/env bash
#
# The Phase 0 go/no-go test.
#
#   ./tests/clone-from-gateway.sh <swarm-reference> [expected-head-sha] [gateway-url]
#
# Clones from a Swarm gateway with nothing but stock git, verifies the object store,
# and — if given an expected HEAD — checks that what came back is the repository we
# published. A pass here means a repository published to Swarm is retrievable by anyone
# with a plain `git` and one URL.

set -euo pipefail

REF="${1:-}"
EXPECTED_HEAD="${2:-}"
GATEWAY="${3:-https://download.gateway.ethswarm.org}"

if [ -z "$REF" ]; then
  echo "usage: $0 <swarm-reference> [expected-head-sha] [gateway-url]" >&2
  exit 64
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

URL="$GATEWAY/bzz/$REF/"
echo "==> cloning $URL"
start=$(date +%s)
if ! git clone --quiet "$URL" "$TMP/clone" 2>"$TMP/err"; then
  echo "FAIL: clone did not complete" >&2
  sed 's/^/    /' "$TMP/err" >&2
  exit 1
fi
elapsed=$(( $(date +%s) - start ))
echo "    cloned in ${elapsed}s"

echo "==> git fsck"
if ! git -C "$TMP/clone" fsck --no-progress >"$TMP/fsck" 2>&1; then
  echo "FAIL: fsck reported problems" >&2
  sed 's/^/    /' "$TMP/fsck" >&2
  exit 1
fi
echo "    object store is intact"

head=$(git -C "$TMP/clone" rev-parse HEAD)
echo "==> HEAD is $head"
git -C "$TMP/clone" log --oneline -3 | sed 's/^/    /'

if [ -n "$EXPECTED_HEAD" ] && [ "$head" != "$EXPECTED_HEAD" ]; then
  echo "FAIL: expected HEAD $EXPECTED_HEAD" >&2
  exit 1
fi

echo
echo "PASS — cloned from Swarm over a public gateway with stock git (${elapsed}s)"
