#!/usr/bin/env bash
# Restore an archived Radicle repository with no Radicle toolchain present.
#
# #39. The archive is only durable if getting the data back does not depend on
# the ecosystem that produced it. Today that ecosystem is one vendor — browser,
# forge, index and Radicle binding all from the same org — so "you can always
# read it with stock git" has to be a test, not a claim.
#
# The fixture is built with rad, because that is how a real archive comes to
# exist. The restore then runs with rad removed from PATH entirely, and the test
# asserts it really is gone before trusting the result.
#
# Verification is pure git: every ref present and identical, fsck clean, and
# sigrefs still a commit over its refs and signature blobs. No radicle-httpd, no
# canopy, no browser, no rad.
#
# Needs a Bee node with peers, a usable batch and a key — see tests/stack/run.sh.
# Does not source .env: it names a real node and a funded batch, and this pushes.

set -euo pipefail

HERE="$(cd "$(dirname "$0")/../.." && pwd)"

fail() { echo "FAIL: $*" >&2; exit 1; }
skip() { echo "SKIP: $*" >&2; exit 77; }

command -v rad >/dev/null 2>&1            || skip "rad not on PATH (needed to build the fixture)"
command -v git-remote-bzz >/dev/null 2>&1 || skip "git-remote-bzz not on PATH"

API="${SWARM_API:-}"
[ -n "$API" ]                   || skip "SWARM_API not set"
[ -n "${SWARM_BATCH_ID:-}" ]    || skip "SWARM_BATCH_ID not set"
[ -n "${SWARM_PRIVATE_KEY:-}" ] || skip "SWARM_PRIVATE_KEY not set"
[ -n "${SWARM_OWNER:-}" ]       || skip "SWARM_OWNER not set"

connected="$(curl -fsS "$API/topology" 2>/dev/null \
  | python3 -c 'import json,sys; print(json.load(sys.stdin).get("connected",0))' 2>/dev/null || echo 0)"
[ "${connected:-0}" -gt 0 ] || skip "Bee node at $API has 0 connected peers"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

NAME="vendorfree-$(date +%s)-$$"
URL="bzz::${SWARM_OWNER}/${NAME}"

echo "==> building an archive the normal way (rad present)"
RID="$("$HERE/tests/stack/seed-fixture.sh" "$TMP/rad" 2>/dev/null)" || skip "could not build a fixture"
SRC="$TMP/rad/storage/$RID"
git -C "$SRC" for-each-ref --format='%(objectname) %(objecttype) %(refname)' | sort > "$TMP/before.refs"
git -C "$SRC" push -q "$URL" '+refs/*:refs/*' 2>&1 | sed 's/^/    /' || fail "push failed"
echo "    rad:$RID — $(wc -l < "$TMP/before.refs" | tr -d ' ') refs"

# A PATH with the tools a stranger would have, and nothing from Radicle. The
# helper needs node; node is not a Radicle dependency.
BIN="$TMP/bin"
mkdir -p "$BIN"
for tool in git node python3 curl env sh bash sed grep sort diff cmp wc tr cat mktemp rm mkdir sleep date; do
  src="$(command -v "$tool" 2>/dev/null || true)"
  [ -n "$src" ] && ln -sf "$src" "$BIN/$tool"
done
# The helper itself is the thing under test, so it comes along.
for tool in git-remote-bzz git-remote-swarm; do
  src="$(command -v "$tool" 2>/dev/null || true)"
  [ -n "$src" ] && ln -sf "$src" "$BIN/$tool"
done

# Prove the sandbox is real before relying on it. A test that believes it removed
# the toolchain and did not would pass while asserting nothing.
for banned in rad radicle-node radicle-httpd git-remote-rad; do
  if PATH="$BIN" command -v "$banned" >/dev/null 2>&1; then
    fail "$banned is still reachable; the sandbox proves nothing"
  fi
done
echo "==> rad, radicle-node, radicle-httpd, git-remote-rad all absent  ok"

echo "==> restoring with stock git and the helper alone"
BACK="$TMP/back.git"
PATH="$BIN" git init -q --bare "$BACK"

deadline=$(( $(date +%s) + 120 ))
while :; do
  # No batch, no key, no Radicle. Just the reference.
  PATH="$BIN" env -u SWARM_BATCH_ID -u SWARM_PRIVATE_KEY \
      git -C "$BACK" fetch -q "$URL" '+refs/*:refs/*' 2>/dev/null || true
  PATH="$BIN" git -C "$BACK" show-ref --quiet && break
  [ "$(date +%s)" -lt "$deadline" ] || fail "could not restore within 120s"
  sleep 5
done

PATH="$BIN" git -C "$BACK" for-each-ref --format='%(objectname) %(objecttype) %(refname)' \
  | sort > "$TMP/after.refs"
diff -u "$TMP/before.refs" "$TMP/after.refs" > "$TMP/refs.diff" || {
  cat "$TMP/refs.diff" >&2
  fail "ref sets differ"
}
echo "==> all $(wc -l < "$TMP/before.refs" | tr -d ' ') refs restored identically              ok"

PATH="$BIN" git -C "$BACK" fsck --no-progress --no-dangling >/dev/null 2>&1 \
  || fail "git fsck failed on the restored copy"
echo "==> git fsck clean                                   ok"

# The self-certification is still inspectable with nothing but git. Someone with
# no Radicle install can still see that the signed ref list is there and intact,
# which is what makes the archive worth keeping rather than just readable.
nid="$(sed -n 's|.*refs/namespaces/\([^/]*\)/.*|\1|p' "$TMP/after.refs" | sed -n '1p')"
[ -n "$nid" ] || fail "no namespace in the restored copy"
sig="refs/namespaces/$nid/refs/rad/sigrefs"
[ "$(PATH="$BIN" git -C "$BACK" cat-file -t "$(PATH="$BIN" git -C "$BACK" rev-parse "$sig")")" = commit ] \
  || fail "restored sigrefs is not a commit"
tree="$(PATH="$BIN" git -C "$BACK" ls-tree --name-only "$sig" | sort | tr '\n' ' ')"
[ "$tree" = "refs signature " ] || fail "restored sigrefs tree is '$tree'"
PATH="$BIN" git -C "$BACK" cat-file blob "$sig:refs" > "$TMP/sigrefs.txt" \
  || fail "could not read the signed ref list"
[ -s "$TMP/sigrefs.txt" ] || fail "the signed ref list is empty"
echo "==> signed ref list readable with git alone          ok"

echo
echo "PASS"
