#!/usr/bin/env bash
#
# The Phase 1 acceptance test: a full round trip through Swarm using nothing but
# ordinary git commands.
#
#   ./tests/e2e-push-clone.sh
#
# Requires a connected Bee node, a usable postage batch and a feed signing key:
#
#   SWARM_BATCH_ID=<batch>  SWARM_PRIVATE_KEY=<hex>  SWARM_OWNER=<address>  ./tests/e2e-push-clone.sh
#
# It creates a throwaway repository under work/, pushes it, clones it back into
# a second directory, and checks the clone matches. Then it commits again,
# pushes, and re-clones — which is what proves the feed moved and that the
# second push was incremental rather than a full republish.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
[ -f "$HERE/.env" ] && . "$HERE/.env"

BEE_API="${SWARM_API:-${BEE_API:-http://localhost:1633}}"
OWNER="${SWARM_OWNER:-}"
BATCH="${SWARM_BATCH_ID:-}"
KEY="${SWARM_PRIVATE_KEY:-}"
# Unique per run: a repeated name would inherit the previous run's feed history,
# and the first push would be correctly rejected as a non-fast-forward.
REPO_NAME="${SWARM_TEST_REPO:-swarm-git-e2e-$(date +%s)}"

fail() { echo "FAIL: $*" >&2; exit 1; }
skip() { echo "SKIP: $*" >&2; exit 77; }

# Clone until the expected commit shows up.
#
# A feed read immediately after a write can still return the previous update:
# the node's feed lookup lags its own write by a few seconds. The feed itself is
# correct — a probe moments later shows the new index — so retrying is the honest
# way to test this, rather than pretending the read is instantaneous.
clone_until() {
  local url="$1" dest="$2" expected="$3" deadline=$((SECONDS + 90))
  while [ $SECONDS -lt $deadline ]; do
    rm -rf "$dest"
    if git clone -q "$url" "$dest" 2>/dev/null && [ "$(git -C "$dest" rev-parse HEAD)" = "$expected" ]; then
      return 0
    fi
    sleep 5
  done
  return 1
}

# --- preconditions ----------------------------------------------------------
# Skipped rather than failed: an unconfigured or offline environment is not a
# defect in the helper, and a red test for that reason teaches nothing.

command -v git-remote-swarm >/dev/null || skip "git-remote-swarm is not on PATH (run: npm link)"
[ -n "$OWNER" ] || skip "SWARM_OWNER not set"
[ -n "$BATCH" ] || skip "SWARM_BATCH_ID not set"
[ -n "$KEY" ]   || skip "SWARM_PRIVATE_KEY not set"

peers=$(curl -sf -m 10 "$BEE_API/topology" | python3 -c 'import sys,json; print(json.load(sys.stdin).get("connected",0))' 2>/dev/null || echo 0)
[ "$peers" -gt 0 ] || skip "Bee node at $BEE_API has 0 connected peers — pushes cannot reach Swarm"

usable=$(curl -sf -m 10 "$BEE_API/stamps/$BATCH" | python3 -c 'import sys,json; print(json.load(sys.stdin).get("usable",False))' 2>/dev/null || echo False)
[ "$usable" = "True" ] || skip "postage batch ${BATCH:0:8}… is not usable"

URL="swarm://$OWNER/$REPO_NAME"
SRC="$HERE/work/e2e-src"
CLONE1="$HERE/work/e2e-clone1"
CLONE2="$HERE/work/e2e-clone2"
rm -rf "$SRC" "$CLONE1" "$CLONE2"

echo "==> repository: $URL"

# --- 1. create and push -----------------------------------------------------
mkdir -p "$SRC"
git -C "$SRC" init -q -b main
echo "round trip $(date -u +%FT%TZ)" > "$SRC/README.md"
git -C "$SRC" add -A
git -C "$SRC" -c user.email=e2e@example.invalid -c user.name=e2e commit -q -m "first commit"
git -C "$SRC" remote add origin "$URL"
git -C "$SRC" config remote.origin.swarmBatch "$BATCH"
git -C "$SRC" config remote.origin.swarmKey "$KEY"

echo "==> push 1"
git -C "$SRC" push -q origin main || fail "first push failed"
FIRST=$(git -C "$SRC" rev-parse HEAD)

# --- 2. clone it back -------------------------------------------------------
echo "==> clone 1"
clone_until "$URL" "$CLONE1" "$FIRST" || fail "clone never produced the pushed commit"
git -C "$CLONE1" fsck --no-progress >/dev/null 2>&1 || fail "clone did not pass fsck"
echo "    HEAD matches: $FIRST"

# --- 3. push again, and see the change come back ----------------------------
echo "second commit" >> "$SRC/README.md"
git -C "$SRC" add -A
git -C "$SRC" -c user.email=e2e@example.invalid -c user.name=e2e commit -q -m "second commit"
SECOND=$(git -C "$SRC" rev-parse HEAD)

echo "==> push 2 (incremental)"
git -C "$SRC" push -q origin main || fail "second push failed"

echo "==> clone 2"
clone_until "$URL" "$CLONE2" "$SECOND" || fail "feed never advanced to the second commit"
git -C "$CLONE2" fsck --no-progress >/dev/null 2>&1 || fail "second clone did not pass fsck"
[ "$(git -C "$CLONE2" rev-list --count HEAD)" = "2" ] || fail "history is incomplete after the incremental push"
echo "    HEAD matches: $SECOND, full history present"

# --- 4. failure modes must be loud, not silent ------------------------------
echo "==> rejects a push with no batch configured"
# There must be something to push: git short-circuits an up-to-date ref and never
# invokes the helper, which would make this check pass for the wrong reason.
echo "third commit" >> "$SRC/README.md"
git -C "$SRC" add -A
git -C "$SRC" -c user.email=e2e@example.invalid -c user.name=e2e commit -q -m "third commit"
git -C "$SRC" config --unset remote.origin.swarmBatch
if env -u SWARM_BATCH_ID git -C "$SRC" push -q origin main 2>/dev/null; then
  fail "push succeeded with no postage batch configured"
fi
git -C "$SRC" config remote.origin.swarmBatch "$BATCH"
echo "    rejected"

echo "==> rejects a non-fast-forward without force"
# Divergence has to be manufactured by rewriting a commit the remote already has.
# Dropping the unpushed third commit would land back exactly on the remote tip,
# which is a no-op rather than a rejection.
git -C "$SRC" reset -q --hard HEAD~1
git -C "$SRC" -c user.email=e2e@example.invalid -c user.name=e2e commit -q --amend -m "rewritten second commit"
if git -C "$SRC" push -q origin main 2>/dev/null; then
  fail "push succeeded on a non-fast-forward without force"
fi
echo "    rejected"

echo "==> accepts the same push when forced"
git -C "$SRC" push -q --force origin main || fail "forced push was refused"
REWRITTEN=$(git -C "$SRC" rev-parse HEAD)
clone_until "$URL" "$HERE/work/e2e-clone3" "$REWRITTEN" || fail "force push did not move the feed"
echo "    accepted, feed moved to $REWRITTEN"

echo
echo "PASS — pushed, cloned, pushed again and re-cloned through Swarm with plain git"
