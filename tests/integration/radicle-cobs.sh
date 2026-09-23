#!/usr/bin/env bash
# Archive a repository that has issues and patches, and get them back.
#
# This is the bet in docs/architecture.md §2 being cashed: "if issues and
# patches are stored as Git objects, then solving L0+L1 gives you L3 for free —
# do not build an issue tracker."
#
# Free is a claim, not a fact, until the collaborative objects actually survive
# a round trip. Every other archive test here uses a fixture with zero issues
# and zero patches, so the refs under refs/cobs/* were covered by the refspec
# glob and never carried anything.
#
# Radicle stores collaboration as ordinary git refs:
#   refs/cobs/xyz.radicle.issue/<oid>    issues
#   refs/cobs/xyz.radicle.patch/<oid>    patches
#   refs/heads/patches/<oid>             the patch's branch
#   refs/cobs/xyz.radicle.id/<oid>       the identity document
#
# So the test is not "does the helper handle issues" — it has no idea what an
# issue is. It is "does rad still see them after the repository has been through
# Swarm and back".
#
# Needs a Bee node with peers, a usable batch and a key — see tests/stack/run.sh.
# Does not source .env: it names a real node and a funded batch, and this pushes.

set -euo pipefail

HERE="$(cd "$(dirname "$0")/../.." && pwd)"

fail() { echo "FAIL: $*" >&2; exit 1; }
skip() { echo "SKIP: $*" >&2; exit 77; }

command -v rad >/dev/null 2>&1            || skip "rad not on PATH"
command -v git-remote-bzz >/dev/null 2>&1 || skip "git-remote-bzz not on PATH"

API="${SWARM_API:-}"
[ -n "$API" ]                   || skip "SWARM_API not set"
[ -n "${SWARM_BATCH_ID:-}" ]    || skip "SWARM_BATCH_ID not set"
[ -n "${SWARM_PRIVATE_KEY:-}" ] || skip "SWARM_PRIVATE_KEY not set"
[ -n "${SWARM_OWNER:-}" ]       || skip "SWARM_OWNER not set"

connected="$(curl -fsS "$API/topology" 2>/dev/null \
  | python3 -c 'import json,sys; print(json.load(sys.stdin).get("connected",0))' 2>/dev/null || echo 0)"
[ "${connected:-0}" -gt 0 ] || skip "Bee node at $API has 0 connected peers"

READER="${SWARM_WORKER_API:-$SWARM_API}"

BASE=/rad/cobs
rm -rf "$BASE"
mkdir -p "$BASE" 2>/dev/null || skip "cannot create $BASE (run this in the harness container)"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP" "$BASE"' EXIT

ORIGIN="$BASE/origin"
RESTORED="$BASE/restored"
NAME="cobs-$(date +%s)-$$"
URL="bzz::${SWARM_OWNER}/${NAME}"

export RAD_PASSPHRASE=''
unset SSH_AUTH_SOCK || true

ISSUE_TITLE="Needs a changelog"
PATCH_TITLE="feature work"

echo "==> building a repository with collaboration in it"
RID="$("$HERE/tests/stack/seed-fixture.sh" "$ORIGIN" alice public 2>/dev/null)" \
  || skip "could not build a fixture"
WORK="$ORIGIN.work"

# rad infers the repository from the working directory, so these run from
# inside the checkout rather than pointing at storage.
( cd "$WORK" && RAD_HOME="$ORIGIN" rad issue open --title "$ISSUE_TITLE" \
    --description "Before release." --no-announce >/dev/null 2>&1 ) \
  || fail "could not open an issue"

git -C "$WORK" checkout -q -b feature
printf 'a change worth reviewing\n' >> "$WORK/README.md"
git -C "$WORK" add -A
git -C "$WORK" -c user.email=alice@example.invalid -c user.name=alice commit -qm "$PATCH_TITLE"
# A patch is opened by pushing to the magic refs/patches ref, not by a command.
RAD_HOME="$ORIGIN" git -C "$WORK" push -q rad HEAD:refs/patches 2>/dev/null \
  || fail "could not open a patch"

# Prove the fixture really has them, or the whole test is vacuous.
( cd "$WORK" && RAD_HOME="$ORIGIN" rad issue list 2>/dev/null ) | grep -q "$ISSUE_TITLE" \
  || fail "the fixture has no issue; this test would prove nothing"
( cd "$WORK" && RAD_HOME="$ORIGIN" rad patch list 2>/dev/null ) | grep -qi "$PATCH_TITLE" \
  || fail "the fixture has no patch; this test would prove nothing"

SRC="$ORIGIN/storage/$RID"
for kind in xyz.radicle.issue xyz.radicle.patch; do
  git -C "$SRC" for-each-ref --format='%(refname)' | grep -q "refs/cobs/$kind/" \
    || fail "expected refs/cobs/$kind/ in the storage repo"
done
echo "    issue and patch present, as refs under refs/cobs/"

echo "==> archiving it"
git -C "$SRC" for-each-ref --format='%(objectname) %(objecttype) %(refname)' | sort > "$TMP/before.refs"
git -C "$SRC" push -q "$URL" '+refs/*:refs/*' 2>&1 | sed 's/^/    /' || fail "push failed"

echo "==> restoring onto a fresh identity, through $READER"
mkdir -p "$RESTORED"
RAD_HOME="$RESTORED" rad auth --alias reader >/dev/null 2>&1 || fail "could not create an identity"
DEST="$RESTORED/storage/$RID"
mkdir -p "$DEST"
git init -q --bare "$DEST"

deadline=$(( $(date +%s) + 120 ))
while :; do
  env -u SWARM_BATCH_ID -u SWARM_PRIVATE_KEY \
      SWARM_API="$READER" SWARM_GATEWAY="$READER" \
      git -C "$DEST" fetch -q "$URL" '+refs/*:refs/*' 2>/dev/null || true
  git -C "$DEST" show-ref --quiet && break
  [ "$(date +%s)" -lt "$deadline" ] || fail "could not restore within 120s"
  sleep 5
done

git -C "$DEST" for-each-ref --format='%(objectname) %(objecttype) %(refname)' | sort > "$TMP/after.refs"
diff -u "$TMP/before.refs" "$TMP/after.refs" > "$TMP/refs.diff" || {
  cat "$TMP/refs.diff" >&2
  fail "ref sets differ"
}
echo "==> all $(wc -l < "$TMP/before.refs" | tr -d ' ') refs round-tripped identically  ok"

# The assertion that matters: the collaborative objects are readable by Radicle
# on a machine that has never seen this repository and holds no key of its own
# here. `rad cob` reads the objects from the refs; `rad issue list` reads a
# derived cache — see the note below for why that distinction is the finding.
for kind in xyz.radicle.issue xyz.radicle.patch; do
  n="$(RAD_HOME="$RESTORED" rad cob list --repo "rad:$RID" --type "$kind" 2>/dev/null | grep -c . || true)"
  [ "${n:-0}" -ge 1 ] || fail "no $kind survived the round trip"
done
echo "==> rad reads the issue and patch objects back     ok"

# What does NOT come back, and must not be quietly ignored.
#
# `rad issue list` and `rad patch list` are empty on the restored copy even
# though every ref is byte-identical and `rad cob list` finds the objects. They
# read $RAD_HOME/cobs/cache.db, a SQLite index that Radicle populates when COBs
# arrive through its own fetch path. A raw `git fetch` into storage bypasses
# that, and starting the node does not rebuild it — measured, not assumed.
#
# The same shape as the repository itself missing from `rad ls` and
# /api/v1/repos after a restore: the data is all there, the indexes are not.
#
# So this is asserted as a KNOWN GAP rather than a pass. If a future Radicle
# rebuilds the cache from storage, this flips and the test should be tightened
# to expect the listing instead.
if RAD_HOME="$RESTORED" rad issue list --repo "rad:$RID" 2>/dev/null | grep -q "$ISSUE_TITLE"; then
  fail "rad issue list now works after a raw restore — good news, tighten this test"
fi
echo "==> known gap: listings stay empty (cobs/cache.db)  noted"

git -C "$DEST" fsck --no-progress --no-dangling >/dev/null 2>&1 \
  || fail "git fsck failed on the restored copy"
echo "==> git fsck clean                                 ok"

echo
echo "PASS"
