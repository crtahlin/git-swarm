#!/usr/bin/env bash
# Keep archiving a repository after one of its peers rewrites history.
#
# This settles #33. An archive tracks a source it does not control, and a
# Radicle peer rewriting its own branch is an ordinary operation — `git push -f
# rad`, which Radicle replicates to everyone seeding the repository. The refs in
# the archive then have to move backwards.
#
# The answer turns out to need no new mode or option: a forced refspec is the
# git idiom for exactly this, and the helper already honours the `+`. What was
# missing was anything saying so, and anything stopping it from regressing.
#
# So this asserts both halves — that the plain refspec is refused, which is
# correct for a working repository, and that the forced one tracks the rewrite.
#
# Needs a Bee node with peers, a usable batch and a key — see tests/stack/run.sh.
# Does not source .env: it names a real node and a funded batch, and this pushes.

set -euo pipefail

HERE="$(cd "$(dirname "$0")/../.." && pwd)"

fail() { echo "FAIL: $*" >&2; exit 1; }
skip() { echo "SKIP: $*" >&2; exit 77; }

command -v rad >/dev/null 2>&1            || skip "rad not on PATH"
command -v radicle-node >/dev/null 2>&1   || skip "radicle-node not on PATH"
command -v git-remote-bzz >/dev/null 2>&1 || skip "git-remote-bzz not on PATH"

API="${SWARM_API:-}"
[ -n "$API" ]                   || skip "SWARM_API not set"
[ -n "${SWARM_BATCH_ID:-}" ]    || skip "SWARM_BATCH_ID not set"
[ -n "${SWARM_PRIVATE_KEY:-}" ] || skip "SWARM_PRIVATE_KEY not set"
[ -n "${SWARM_OWNER:-}" ]       || skip "SWARM_OWNER not set"

connected="$(curl -fsS "$API/topology" 2>/dev/null \
  | python3 -c 'import json,sys; print(json.load(sys.stdin).get("connected",0))' 2>/dev/null || echo 0)"
[ "${connected:-0}" -gt 0 ] || skip "Bee node at $API has 0 connected peers"

# Two nodes start here; their control sockets cap the path at ~100 characters.
BASE=/rad/rewrite
rm -rf "$BASE"
mkdir -p "$BASE" 2>/dev/null || skip "cannot create $BASE (run this in the harness container)"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP" "$BASE"' EXIT

NAME="rewrite-$(date +%s)-$$"
URL="bzz::${SWARM_OWNER}/${NAME}"

echo "==> building a two-peer repository"
RID="$("$HERE/tests/stack/seed-multipeer.sh" "$BASE" 2>"$TMP/init.err")" || {
  tail -20 "$TMP/init.err" >&2
  skip "could not build a multi-peer fixture"
}
SRC="$BASE/a/storage/$RID"

echo "==> archiving it"
git -C "$SRC" push -q "$URL" '+refs/*:refs/*' 2>&1 | sed 's/^/    /' || fail "first archive failed"

echo "==> peer B rewrites its history and force-pushes"
"$HERE/tests/stack/seed-multipeer.sh" "$BASE" rewrite >/dev/null 2>"$TMP/rw.err" || {
  tail -20 "$TMP/rw.err" >&2
  fail "could not rewrite"
}
# Prove the premise rather than trusting it: the fixture must actually have
# produced a ref that moved backwards, or this test proves nothing.
grep -q "moved backwards" "$TMP/rw.err" \
  || fail "the rewrite produced no non-fast-forward; this test would be vacuous"
echo "==> confirmed a ref moved backwards at the source  ok"

# 1. The plain refspec must refuse it. That is correct behaviour for a working
#    repository and it is why an archive needs to say force explicitly.
echo "==> archiving again with a plain refspec — must be refused"
if out="$(git -C "$SRC" push "$URL" 'refs/*:refs/*' 2>&1)"; then
  fail "plain refspec accepted a non-fast-forward; the guard is gone"
fi
case "$out" in
  *non-fast-forward*) : ;;
  *) echo "$out" >&2; fail "refused, but not as a non-fast-forward" ;;
esac
echo "==> refused as non-fast-forward                    ok"

# 2. The forced refspec must track it. This is what an archiver runs.
echo "==> archiving again with a forced refspec — must track it"
git -C "$SRC" push -q "$URL" '+refs/*:refs/*' 2>&1 | sed 's/^/    /' \
  || fail "forced refspec could not follow the rewrite"
echo "==> tracked the rewrite                            ok"

# 3. And the archive must now match the source, not a mixture of both states.
echo "==> reading it back"
BACK="$TMP/back.git"
git init -q --bare "$BACK"
deadline=$(( $(date +%s) + 120 ))
git -C "$SRC" for-each-ref --format='%(objectname) %(refname)' | sort > "$TMP/src.refs"
while :; do
  env -u SWARM_BATCH_ID -u SWARM_PRIVATE_KEY \
      git -C "$BACK" fetch -q --prune "$URL" '+refs/*:refs/*' 2>/dev/null || true
  git -C "$BACK" for-each-ref --format='%(objectname) %(refname)' | sort > "$TMP/back.refs"
  cmp -s "$TMP/src.refs" "$TMP/back.refs" && break
  [ "$(date +%s)" -lt "$deadline" ] || {
    diff -u "$TMP/src.refs" "$TMP/back.refs" >&2 || true
    fail "the archive does not match the source after the rewrite"
  }
  sleep 5
done
echo "==> archive matches the source exactly             ok"

git -C "$BACK" fsck --no-progress --no-dangling >/dev/null 2>&1 \
  || fail "git fsck failed on the restored copy"
echo "==> git fsck clean                                 ok"

echo
echo "PASS"
