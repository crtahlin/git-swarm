#!/usr/bin/env bash
# Restore a repository from Swarm and get a Radicle node to seed it again.
#
# The last half of #36. radicle-restore.sh proves `rad` can read what came back;
# this proves a node will carry it: the repository re-enters the network from an
# archive, on a machine that never had it, after every original peer is gone.
# Without this the archive is a backup with no restore path, and #31 is paying
# BZZ for something nobody has shown works.
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

# A node starts here, and its control socket path is limited to about 100
# characters, so this cannot live under a deep mktemp path.
BASE=/rad/reseed
rm -rf "$BASE"
mkdir -p "$BASE" 2>/dev/null || skip "cannot create $BASE (run this in the harness container)"

ORIGIN="$BASE/origin"
RESTORED="$BASE/restored"
LOG="$BASE/node.log"
NODE_PID=''
cleanup() { [ -n "$NODE_PID" ] && kill "$NODE_PID" 2>/dev/null; rm -rf "$BASE"; }
trap cleanup EXIT

NAME="reseed-$(date +%s)-$$"
URL="bzz::${SWARM_OWNER}/${NAME}"

export RAD_PASSPHRASE=''
unset SSH_AUTH_SOCK || true
unset SSH_AGENT_PID || true

# Public on purpose. A node will not inventory a private repository for an
# identity that is not on its allow list — correct behaviour, and it would make
# this test assert the wrong thing. Archived repositories are public ones: the
# index service finds them by crawling the public network.
echo "==> building a public repository"
RID="$("$HERE/tests/stack/seed-fixture.sh" "$ORIGIN" origin public 2>/dev/null)" \
  || skip "could not build a fixture"
echo "    rad:$RID"

echo "==> archiving it to Swarm"
git -C "$ORIGIN/storage/$RID" push -q "$URL" 'refs/*:refs/*' 2>&1 | sed 's/^/    /' \
  || fail "push failed"

# From here on, pretend the original is gone. Everything below is a machine that
# has the bzz reference and nothing else.
echo "==> restoring onto a machine that never had it"
mkdir -p "$RESTORED"
RAD_HOME="$RESTORED" rad auth --alias restorer >/dev/null 2>&1 \
  || fail "could not create a fresh identity"

# Keep the node off the public network. Without this it dials iris and rosa on
# startup, which would make the test depend on the internet and announce a test
# repository to strangers.
python3 - "$RESTORED/config.json" <<'PY'
import json, sys
path = sys.argv[1]
with open(path) as f:
    cfg = json.load(f)
cfg['preferredSeeds'] = []
node = cfg.setdefault('node', {})
node['connect'] = []
node['network'] = 'test'
node.setdefault('peers', {})['type'] = 'static'
with open(path, 'w') as f:
    json.dump(cfg, f, indent=2)
PY

DEST="$RESTORED/storage/$RID"
mkdir -p "$DEST"
git init -q --bare "$DEST"

deadline=$(( $(date +%s) + 120 ))
while :; do
  # No batch and no key: reading an archive must not require paying to read it.
  env -u SWARM_BATCH_ID -u SWARM_PRIVATE_KEY \
      git -C "$DEST" fetch -q "$URL" 'refs/*:refs/*' 2>/dev/null || true
  git -C "$DEST" show-ref --quiet && break
  [ "$(date +%s)" -lt "$deadline" ] || fail "could not restore within 120s"
  sleep 5
done
echo "==> restored with no batch and no key             ok"

# Seeding policy. Writes to the policy database and needs no running node.
RAD_HOME="$RESTORED" rad seed "rad:$RID" >/dev/null 2>&1 \
  || fail "could not set a seeding policy on the restored repository"

echo "==> starting a node on the restored copy"
rm -f "$RESTORED/node/control.sock"   # a stale socket blocks startup
RAD_HOME="$RESTORED" radicle-node > "$LOG" 2>&1 &
NODE_PID=$!
deadline=$(( $(date +%s) + 45 ))
while [ ! -S "$RESTORED/node/control.sock" ]; do
  [ "$(date +%s)" -lt "$deadline" ] || { tail -20 "$LOG" >&2; fail "node did not start"; }
  sleep 1
done

# The assertion. Inventory is what the node announces it holds, so a repository
# in it is one this node will serve to the network.
deadline=$(( $(date +%s) + 60 ))
while :; do
  if RAD_HOME="$RESTORED" rad node inventory 2>/dev/null | grep -q "$RID"; then
    break
  fi
  [ "$(date +%s)" -lt "$deadline" ] || {
    echo "--- node log ---" >&2; tail -25 "$LOG" >&2
    fail "the node started but never took the restored repository into its inventory"
  }
  sleep 3
done
echo "==> the node announces the restored repository    ok"

# The repository came back whole, not just as an entry in a list.
RAD_HOME="$RESTORED" rad inspect --identity "rad:$RID" >/dev/null 2>&1 \
  || fail "node inventories it but rad cannot read its identity"
nid="$(git -C "$DEST" for-each-ref --format='%(refname)' \
  | sed -n 's|refs/namespaces/\([^/]*\)/.*|\1|p' | sed -n '1p')"
[ -n "$nid" ] || fail "no namespace in the restored repository"
git -C "$DEST" show-ref --verify --quiet "refs/namespaces/$nid/refs/rad/sigrefs" \
  || fail "restored repository lost its self-certification"
echo "==> identity and self-certification intact        ok"

# The test must not have touched the public network. If this fires, the
# isolation config above stopped working and the suite has been announcing test
# repositories to real seeds.
if grep -q "radicle.network\|seed.radicle" "$LOG"; then
  grep "radicle.network\|seed.radicle" "$LOG" | head -3 >&2
  fail "the node contacted the public Radicle network"
fi
echo "==> stayed off the public network                 ok"

echo
echo "PASS"
