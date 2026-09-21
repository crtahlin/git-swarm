#!/usr/bin/env bash
# Restore a Radicle repository from Swarm into a fresh install, and verify it.
#
# The other half of #36. An archive nobody can restore from is a cost with no
# benefit, so the claim under test is not "the bytes came back" but "Radicle
# accepts what came back": a different machine, a different identity, no prior
# knowledge of the repository, and the recovered identity document still matches.
#
# Also asserts the constraint from #36: restore must work from an UNFUNDED node.
# The fetch runs with no postage batch and no signing key at all — not merely
# with credentials that happen to go unused. Reading Swarm costs nothing, and if
# restore ever starts needing a funded node then the archive is only readable by
# people who paid to read it, which defeats the point of archiving it.
#
# Credentials for the push come from the caller; see tests/stack/run.sh.

set -euo pipefail

HERE="$(cd "$(dirname "$0")/../.." && pwd)"

# Does not source .env: it names the developer's own node and funded batch, and
# this test pushes. An accidental mainnet publish is permanent.

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

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

ORIGIN="$TMP/origin"
RESTORED="$TMP/restored"
NAME="radicle-restore-$(date +%s)-$$"
URL="bzz::${SWARM_OWNER}/${NAME}"

export RAD_PASSPHRASE=''
unset SSH_AUTH_SOCK || true
unset SSH_AGENT_PID || true

echo "==> building the original repository"
RID="$("$HERE/tests/stack/seed-fixture.sh" "$ORIGIN" 2>/dev/null)" || skip "could not build a fixture"
SRC="$ORIGIN/storage/$RID"

RAD_HOME="$ORIGIN" rad inspect --identity "rad:$RID" > "$TMP/identity.before" 2>/dev/null \
  || fail "could not read the original identity"
# Compare the DIDs only. rad annotates a delegate with its local alias when the
# address book knows it — "did:key:z6Mks9… (fixturebot)" at the origin and a bare
# DID on a machine that has never met that peer. The alias is local metadata, not
# repository content, and a restored archive is expected not to carry it.
delegate_dids() {
  RAD_HOME="$1" rad inspect --delegates "rad:$RID" 2>/dev/null \
    | grep -o 'did:key:[A-Za-z0-9]*' | sort
}

delegate_dids "$ORIGIN" > "$TMP/delegates.before"
[ -s "$TMP/delegates.before" ] || fail "could not read the original delegates"
echo "    rad:$RID"

echo "==> archiving it to Swarm"
git -C "$SRC" push -q "$URL" 'refs/*:refs/*' 2>&1 | sed 's/^/    /' || fail "push failed"

# Everything below runs as someone who has the reference and nothing else.
echo "==> restoring on a fresh install, with no batch and no key"
mkdir -p "$RESTORED"
RAD_HOME="$RESTORED" rad auth --alias restorer >/dev/null 2>&1 \
  || fail "could not create a fresh identity"

DEST="$RESTORED/storage/$RID"
mkdir -p "$DEST"
git init -q --bare "$DEST"

deadline=$(( $(date +%s) + 90 ))
while :; do
  # env -u, not an empty value: the helper must never see these at all.
  if env -u SWARM_BATCH_ID -u SWARM_PRIVATE_KEY \
       git -C "$DEST" fetch -q "$URL" 'refs/*:refs/*' 2>/dev/null; then
    break
  fi
  [ "$(date +%s)" -lt "$deadline" ] || fail "could not restore within 90s"
  sleep 5
done
echo "==> fetched with no credentials configured        ok"

# 1. The refs are all there, same objects, same types.
git -C "$SRC"  for-each-ref --format='%(objectname) %(objecttype) %(refname)' | sort > "$TMP/before.refs"
git -C "$DEST" for-each-ref --format='%(objectname) %(objecttype) %(refname)' | sort > "$TMP/after.refs"
diff -u "$TMP/before.refs" "$TMP/after.refs" > "$TMP/refs.diff" || {
  cat "$TMP/refs.diff" >&2
  fail "restored ref set differs from the original"
}
echo "==> $(wc -l < "$TMP/before.refs" | tr -d ' ') refs restored identically              ok"

# 2. Radicle itself accepts it. This is the assertion that matters: a fresh
#    install, a different identity, no prior knowledge of the repository.
RAD_HOME="$RESTORED" rad inspect --identity "rad:$RID" > "$TMP/identity.after" 2>/dev/null \
  || fail "rad could not read the identity of the restored repository"
diff -u "$TMP/identity.before" "$TMP/identity.after" > "$TMP/identity.diff" || {
  cat "$TMP/identity.diff" >&2
  fail "restored identity document differs"
}
echo "==> rad reads the identity document, unchanged    ok"

delegate_dids "$RESTORED" > "$TMP/delegates.after"
[ -s "$TMP/delegates.after" ] || fail "rad could not read the delegates of the restored repository"
diff -u "$TMP/delegates.before" "$TMP/delegates.after" > "$TMP/delegates.diff" || {
  cat "$TMP/delegates.diff" >&2
  fail "restored delegate set differs"
}
echo "==> delegates intact                              ok"

# 3. The self-certification survived. Without this the repo is browsable and
#    unverifiable, which is the failure this whole archive exists to prevent.
nid="$(sed -n 's|.*refs/namespaces/\([^/]*\)/.*|\1|p' "$TMP/after.refs" | sed -n '1p')"
[ -n "$nid" ] || fail "no namespace in the restored repository"
sig="refs/namespaces/$nid/refs/rad/sigrefs"
[ "$(git -C "$DEST" cat-file -t "$(git -C "$DEST" rev-parse "$sig")")" = commit ] \
  || fail "restored sigrefs is not a commit"
tree="$(git -C "$DEST" ls-tree --name-only "$sig" | sort | tr '\n' ' ')"
[ "$tree" = "refs signature " ] || fail "restored sigrefs tree is '$tree'"
echo "==> sigrefs verifiable for $nid" | cut -c1-58
echo "                                                  ok"

echo
echo "PASS"
