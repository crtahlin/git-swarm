#!/usr/bin/env bash
# Archive a Radicle repository that holds more than one peer's namespace.
#
# The single-peer round trip proved the format carries a repository. This proves
# it carries a *replicated* one, which is what an index service actually sees:
# every peer it has fetched, each with its own self-certification.
#
# Both #33 and #34 were left open on this case. A fixture with one namespace
# cannot show what happens when peers are added, and it hides the asymmetry
# below.
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

# Two radicle-nodes start under this path, and their control sockets are limited
# to about 100 characters, so it cannot be a deep mktemp path.
BASE=/rad/mp-archive
rm -rf "$BASE"
mkdir -p "$BASE" 2>/dev/null || skip "cannot create $BASE (run this in the harness container)"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP" "$BASE"' EXIT

NAME="mp-archive-$(date +%s)-$$"
URL="bzz::${SWARM_OWNER}/${NAME}"

echo "==> building a two-peer storage repo (two nodes, real replication)"
RID="$("$HERE/tests/stack/seed-multipeer.sh" "$BASE" 2>"$TMP/seed.err")" || {
  tail -20 "$TMP/seed.err" >&2
  skip "could not build a multi-peer fixture"
}
SRC="$BASE/a/storage/$RID"
[ -d "$SRC" ] || fail "no storage repo at $SRC"

git -C "$SRC" for-each-ref --format='%(objectname) %(objecttype) %(refname)' | sort > "$TMP/before.refs"
peers_before="$(sed -n 's|.*refs/namespaces/\([^/]*\)/.*|\1|p' "$TMP/before.refs" | sort -u)"
n_peers="$(printf '%s\n' "$peers_before" | wc -l | tr -d ' ')"
[ "$n_peers" -ge 2 ] || fail "fixture has $n_peers namespace(s); this test needs at least 2"
echo "    rad:$RID — $(wc -l < "$TMP/before.refs" | tr -d ' ') refs across $n_peers peers"

echo "==> archiving every ref"
git -C "$SRC" push -q "$URL" 'refs/*:refs/*' 2>&1 | sed 's/^/    /' || fail "push failed"

echo "==> fetching it back"
BACK="$TMP/back.git"
git init -q --bare "$BACK"
deadline=$(( $(date +%s) + 120 ))
while :; do
  git -C "$BACK" fetch -q "$URL" 'refs/*:refs/*' 2>/dev/null && break
  [ "$(date +%s)" -lt "$deadline" ] || fail "could not fetch back within 120s"
  sleep 5
done

git -C "$BACK" for-each-ref --format='%(objectname) %(objecttype) %(refname)' | sort > "$TMP/after.refs"
diff -u "$TMP/before.refs" "$TMP/after.refs" > "$TMP/refs.diff" || {
  cat "$TMP/refs.diff" >&2
  fail "ref sets differ"
}
echo "==> all $(wc -l < "$TMP/before.refs" | tr -d ' ') refs round-tripped identically  ok"

git -C "$BACK" fsck --no-progress --no-dangling >/dev/null 2>&1 \
  || fail "git fsck failed on the restored copy"
echo "==> git fsck clean                                 ok"

# Every peer must keep its own self-certification. This is the assertion the
# single-peer fixture could not make: one namespace surviving proves nothing
# about the rest.
for nid in $peers_before; do
  for ref in rad/sigrefs rad/root; do
    grep -q " refs/namespaces/$nid/refs/$ref$" "$TMP/after.refs" \
      || fail "restored copy lost refs/namespaces/$nid/refs/$ref"
  done
  sig="refs/namespaces/$nid/refs/rad/sigrefs"
  [ "$(git -C "$BACK" cat-file -t "$(git -C "$BACK" rev-parse "$sig")")" = commit ] \
    || fail "$sig is not a commit in the restored copy"
  tree="$(git -C "$BACK" ls-tree --name-only "$sig" | sort | tr '\n' ' ')"
  [ "$tree" = "refs signature " ] || fail "$sig tree is '$tree'"
done
echo "==> every peer's sigrefs and root intact           ok"

# refs/rad/id is deliberately NOT required per namespace. Only delegates carry
# the identity COB, so a contributor's namespace has sigrefs, root and heads and
# no id. Asserting it everywhere would fail on a correct archive — worth stating
# because the obvious per-namespace assertion is the wrong one.
delegates=0
for nid in $peers_before; do
  if grep -q " refs/namespaces/$nid/refs/rad/id$" "$TMP/after.refs"; then
    delegates=$(( delegates + 1 ))
  fi
done
[ "$delegates" -ge 1 ] || fail "no namespace carries refs/rad/id; the identity COB is gone"
echo "==> $delegates of $n_peers peers carry rad/id (delegates only)      ok"

# Radicle itself must accept the result, not just git.
RESTORED="$BASE/restored"
mkdir -p "$RESTORED"
export RAD_PASSPHRASE=''
unset SSH_AUTH_SOCK || true
RAD_HOME="$RESTORED" rad auth --alias verifier >/dev/null 2>&1 || fail "could not make a verifier identity"
mkdir -p "$RESTORED/storage/$RID"
git init -q --bare "$RESTORED/storage/$RID"
git -C "$RESTORED/storage/$RID" fetch -q "$BACK" 'refs/*:refs/*' 2>/dev/null \
  || fail "could not load the restored copy into a fresh RAD_HOME"
RAD_HOME="$RESTORED" rad inspect --identity "rad:$RID" >/dev/null 2>&1 \
  || fail "rad could not read the identity of the restored multi-peer repository"
echo "==> rad reads the restored multi-peer repository    ok"

echo
echo "PASS"
