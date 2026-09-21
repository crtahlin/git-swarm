#!/usr/bin/env bash
# Archive a real Radicle storage repo to Swarm and read it back whole.
#
# This is the test #31 actually turns on: can swarm-git/1 carry a bare Radicle
# storage repo — every namespace, every refs/rad/* — so that a restored copy is
# still verifiable? The format does not filter refs, but "does not filter" and
# "round-trips" are different claims and only one of them has been tested.
#
# Needs a Bee node with peers, a usable batch and a signing key. Use
# tests/stack/run.sh, which brings up a throwaway cluster and sets these.

set -euo pipefail

HERE="$(cd "$(dirname "$0")/../.." && pwd)"

# Deliberately does NOT source .env, unlike the other tests here. .env points at
# the developer's own node and their real, funded batch. Sourcing it would
# override the throwaway cluster credentials passed in by the harness — plain
# assignments in a sourced file win over the environment — and this test pushes.
# An accidental mainnet publish is permanent. Credentials come from the caller.

fail() { echo "FAIL: $*" >&2; exit 1; }
skip() { echo "SKIP: $*" >&2; exit 77; }

command -v rad >/dev/null 2>&1          || skip "rad not on PATH"
command -v git-remote-bzz >/dev/null 2>&1 || skip "git-remote-bzz not on PATH (npm link)"

API="${SWARM_API:-${BEE_API:-}}"
[ -n "$API" ]                     || skip "SWARM_API not set"
[ -n "${SWARM_BATCH_ID:-}" ]      || skip "SWARM_BATCH_ID not set"
[ -n "${SWARM_PRIVATE_KEY:-}" ]   || skip "SWARM_PRIVATE_KEY not set"
[ -n "${SWARM_OWNER:-}" ]         || skip "SWARM_OWNER not set"

connected="$(curl -fsS "$API/topology" 2>/dev/null \
  | python3 -c 'import json,sys; print(json.load(sys.stdin).get("connected",0))' 2>/dev/null || echo 0)"
[ "${connected:-0}" -gt 0 ] || skip "Bee node at $API has 0 connected peers"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

RAD_DIR="$TMP/rad"
NAME="radicle-archive-$(date +%s)-$$"
URL="bzz::${SWARM_OWNER}/${NAME}"

echo "==> building a Radicle storage repo"
RID="$("$HERE/tests/stack/seed-fixture.sh" "$RAD_DIR" 2>/dev/null)" \
  || skip "could not build a fixture"
REPO="$RAD_DIR/storage/$RID"
[ -d "$REPO" ] || fail "no storage repo at $REPO"

before="$TMP/before.refs"
git -C "$REPO" for-each-ref --format='%(objectname) %(objecttype) %(refname)' | sort > "$before"
echo "    $RID — $(wc -l < "$before" | tr -d ' ') refs"

# Push every ref, not refs/heads/*. A Radicle repo keeps its branches and its
# self-certification under refs/namespaces/<nid>/, so an archive of refs/heads
# alone restores something that cannot be verified.
echo "==> pushing the whole ref namespace to $URL"
git -C "$REPO" push "$URL" 'refs/*:refs/*' 2>&1 | sed 's/^/    /' \
  || fail "push failed"

# The feed read can lag the write on the same node — documented in
# docs/phase-1-results.md, not a defect. Retry rather than pretend otherwise.
echo "==> fetching it back into an empty repository"
BACK="$TMP/back.git"
git init -q --bare "$BACK"

deadline=$(( $(date +%s) + 90 ))
while :; do
  if git -C "$BACK" fetch -q "$URL" 'refs/*:refs/*' 2>/dev/null; then
    break
  fi
  [ "$(date +%s)" -lt "$deadline" ] || fail "could not fetch back within 90s"
  sleep 5
done

after="$TMP/after.refs"
git -C "$BACK" for-each-ref --format='%(objectname) %(objecttype) %(refname)' | sort > "$after"

# 1. Every ref survived, with the same object and the same type.
if ! diff -u "$before" "$after" > "$TMP/refs.diff"; then
  echo "--- refs lost or changed in the round trip ---" >&2
  cat "$TMP/refs.diff" >&2
  fail "ref sets differ"
fi
echo "==> all $(wc -l < "$before" | tr -d ' ') refs round-tripped identically   ok"

# 2. The archive is a real repository, not a pile of packs that happens to index.
git -C "$BACK" fsck --no-progress --no-dangling >/dev/null 2>&1 \
  || fail "git fsck failed on the restored copy"
echo "==> git fsck clean on the restored copy            ok"

# 3. The refs that make a Radicle repo verifiable are present and intact.
nid="$(sed -n 's|.*refs/namespaces/\([^/]*\)/.*|\1|p' "$after" | head -1)"
[ -n "$nid" ] || fail "no namespace in the restored copy"
for ref in rad/sigrefs rad/id rad/root; do
  grep -q " refs/namespaces/$nid/refs/$ref$" "$after" \
    || fail "restored copy is missing refs/namespaces/$nid/refs/$ref"
done
echo "==> namespace sigrefs, id and root intact          ok"

# 4. sigrefs still resolves to a commit over a refs+signature tree. A restore
#    that loses this is a repo you can browse and cannot verify.
sig="refs/namespaces/$nid/refs/rad/sigrefs"
[ "$(git -C "$BACK" cat-file -t "$(git -C "$BACK" rev-parse "$sig")")" = commit ] \
  || fail "restored sigrefs is not a commit"
tree="$(git -C "$BACK" ls-tree --name-only "$sig" | sort | tr '\n' ' ')"
[ "$tree" = "refs signature " ] || fail "restored sigrefs tree is '$tree'"
echo "==> sigrefs verifiable in the restored copy        ok"

echo
echo "PASS"
