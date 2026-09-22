#!/usr/bin/env bash
# The archive story, end to end, doing the real thing at every step.
#
# Runs inside the harness container. Driven by tests/stack/demo.sh, which brings
# up the Swarm cluster and sets the environment.
#
# Nothing here is staged. The repository is created by a real Radicle node, the
# archive is a real push to a real cluster, the original is really deleted, and
# the restore really goes back to the network. If a step is broken the demo
# breaks rather than narrating a success that did not happen.

set -euo pipefail

PAUSE="${DEMO_PAUSE:-2}"
RID=""

b() { printf '\033[1m%s\033[0m\n' "$*"; }
dim() { printf '\033[2m%s\033[0m\n' "$*"; }
step() { echo; b "── $* "; sleep "$PAUSE"; }
run() { dim "\$ $*"; eval "$@"; sleep "$PAUSE"; }
# Display only: a 48-character node ID wraps a 100-column terminal three times
# per ref. The ellipsis makes the elision obvious.
short() { sed -E 's@(z6Mk[A-Za-z0-9]{8})[A-Za-z0-9]+@\1…@g; s@([0-9a-f]{10})[0-9a-f]{30,}@\1…@g'; }
runshort() { dim "\$ $*"; eval "$@" | short; sleep "$PAUSE"; }

ORIGIN=/rad/demo-origin
RESTORED=/rad/demo-restored
rm -rf "$ORIGIN" "$RESTORED"

export RAD_PASSPHRASE=''
unset SSH_AUTH_SOCK || true

NAME="demo-$(date +%s)"
URL="bzz::${SWARM_OWNER}/${NAME}"

echo
b "git-swarm — archiving a Radicle repository to Swarm, and getting it back"
dim "Every command below is real. Nothing is mocked or pre-baked."
echo
sleep "$PAUSE"
b "What the pieces are"
dim "  Radicle  peer-to-peer git. No server: a repository lives on whichever"
dim "           nodes choose to seed it, and its identity, issues and patches"
dim "           are git objects rather than a database. Its weak spot is that"
dim "           when nobody seeds a repository any more, it is simply gone."
sleep "$PAUSE"
dim "  Swarm    decentralised storage you rent. Content is split into 4 KB"
dim "           chunks addressed by their hash, and a \"feed\" is a mutable"
dim "           pointer signed by an Ethereum key — so refs can move, and"
dim "           anyone can check who moved them. Storage is paid for with a"
dim "           postage batch, and lapses when the rent stops."
sleep "$PAUSE"
dim "  git-swarm  the bridge. git-remote-bzz makes Swarm an ordinary git"
dim "           remote, so \"git push bzz::…\" works with no server anywhere."
dim "           Radicle gets durable storage; Swarm gets a real use."
sleep "$PAUSE"
echo
dim "Running against a local five-node bee-factory cluster on a throwaway chain,"
dim "not mainnet Swarm — so nothing here is published to the real network."
dim "The repository is written through one node and read back through a DIFFERENT"
dim "one, so \"it worked\" cannot mean \"it was still in the writer's own store\"."
sleep "$PAUSE"

WRITER="${SWARM_API:?}"
READER="${SWARM_WORKER_API:-$SWARM_API}"
if [ "$READER" = "$WRITER" ]; then
  dim "   note: no separate reader node configured; reads would come from the"
  dim "   writing node and would prove less. Run this through tests/stack/demo.sh."
fi

# ---------------------------------------------------------------------------
step "1. A Radicle repository"

RID="$("$(dirname "$0")/seed-fixture.sh" "$ORIGIN" alice public 2>/dev/null)"
echo "   created rad:$RID"
run "cd $ORIGIN/storage/$RID"
runshort "git for-each-ref --format='%(objecttype) %(refname)'"
dim "   Under the hood: a Radicle repository on disk is a bare git repo where"
dim "   every peer gets its own refs/namespaces/<node-id>/ subtree. sigrefs is"
dim "   that peer signing its own ref list, so a copy can be checked by anyone"
dim "   without trusting whoever handed it over."

# ---------------------------------------------------------------------------
step "2. Archive it to Swarm"

dim "   Under the hood: git packs the objects, the helper uploads the pack to"
dim "   Swarm, writes a small JSON manifest listing every ref and pack, and"
dim "   moves a signed feed to point at that manifest. The feed is the only"
dim "   mutable part, and only the key holder can move it."
dim ""
dim "   A forced refspec, because an archive tracks its source rather than"
dim "   defending a branch from it."
run "cd $ORIGIN/storage/$RID"
runshort "git push '$URL' '+refs/*:refs/*' 2>&1 | tail -6"

# ---------------------------------------------------------------------------
step "3. Now lose everything"

dim "   Not a simulation: the storage, the identity, the keys, all deleted."
cd /            # step 2 left us inside the directory about to be removed
run "rm -rf $ORIGIN"
run "ls $ORIGIN 2>&1 || echo '   gone.'"
dim "   On the real network this is every seeder going away. The repository"
dim "   is now unreachable by any Radicle peer."

# ---------------------------------------------------------------------------
step "4. Restore, holding nothing but a bzz reference"

mkdir -p "$RESTORED"
RAD_HOME="$RESTORED" rad auth --alias restorer >/dev/null 2>&1
python3 - "$RESTORED/config.json" <<'PY'
import json, sys
p = sys.argv[1]
c = json.load(open(p))
c['preferredSeeds'] = []
n = c.setdefault('node', {})
n['connect'] = []; n['network'] = 'test'; n.setdefault('peers', {})['type'] = 'static'
json.dump(c, open(p, 'w'), indent=2)
PY
dim "   A different machine. A different identity. No postage batch and no"
dim "   signing key — reading an archive must never require paying to read it."
dim "   And a different Swarm node: $READER"
dim "   That node never saw the push. If the data had not really propagated,"
dim "   it would have nothing to serve."
mkdir -p "$RESTORED/storage/$RID"
git init -q --bare "$RESTORED/storage/$RID"
run "cd $RESTORED/storage/$RID"
dim "   Propagation is not instant, so this retries until the reader has it."
dim "\$ env -u SWARM_BATCH_ID -u SWARM_PRIVATE_KEY \\"
dim "    SWARM_API=$READER SWARM_GATEWAY=$READER \\"
dim "    git fetch '$URL' '+refs/*:refs/*'"
deadline=$(( $(date +%s) + 180 ))
attempt=0
while :; do
  attempt=$(( attempt + 1 ))
  out="$(env -u SWARM_BATCH_ID -u SWARM_PRIVATE_KEY \
           SWARM_API="$READER" SWARM_GATEWAY="$READER" \
           git fetch "$URL" '+refs/*:refs/*' 2>&1)" && \
    git show-ref --quiet && break
  [ "$(date +%s)" -lt "$deadline" ] || {
    echo "$out" | short
    echo "   the reader never got it within 180s — that would be a real failure"
    exit 1
  }
  if [ "$attempt" -eq 1 ]; then
    # Show why the first attempt failed. A demo that hides its errors and then
    # times out tells you nothing about what went wrong.
    printf '%s\n' "$out" | short | sed 's/^/   /'
  fi
  [ $(( attempt % 3 )) -eq 1 ] && dim "   not there yet, waiting for it to reach $READER"
  sleep 5
done
printf '%s\n' "$out" | short
dim "   arrived after $attempt attempt(s)"

# ---------------------------------------------------------------------------
step "5. Is it really the same repository?"

runshort "git for-each-ref --format='%(objecttype) %(refname)'"
run "git fsck --no-progress --no-dangling && echo '   fsck: clean'"
dim "   And Radicle itself accepts it — identity and delegates recovered"
dim "   from the archive, by an identity that has never seen this repo:"
run "RAD_HOME=$RESTORED rad inspect --identity rad:$RID | head -14"

# ---------------------------------------------------------------------------
step "6. Put it back on the network"

run "RAD_HOME=$RESTORED rad seed rad:$RID 2>&1 | tail -1"
rm -f "$RESTORED/node/control.sock"
RAD_HOME="$RESTORED" radicle-node > /tmp/demo-node.log 2>&1 &
for _ in $(seq 40); do [ -S "$RESTORED/node/control.sock" ] && break; sleep 1; done
dim "   node started"
for _ in $(seq 20); do
  RAD_HOME="$RESTORED" rad node inventory 2>/dev/null | grep -q "$RID" && break
  sleep 3
done
run "RAD_HOME=$RESTORED rad node inventory"
dim "   Inventory is what a node announces it will serve. The repository is"
dim "   back on the network, from an archive, after every peer was gone."
dim ""
dim "   Under the hood: restoring took two things — the git objects, and a"
dim "   seeding policy telling the node it should carry this repository."

# ---------------------------------------------------------------------------
step "7. And it is readable with no Radicle at all"

BIN=/tmp/demo-bin
rm -rf "$BIN"; mkdir -p "$BIN"
for t in git node env sh sed head; do ln -sf "$(command -v $t)" "$BIN/$t" 2>/dev/null || true; done
ln -sf "$(command -v git-remote-bzz)" "$BIN/git-remote-bzz"
dim "   A PATH with git, node and the helper — and nothing from Radicle:"
run "PATH=$BIN command -v rad || echo '   rad: not found'"
rm -rf /tmp/demo-plain.git
PATH="$BIN" git init -q --bare /tmp/demo-plain.git
run "cd /tmp/demo-plain.git"
runshort "PATH=$BIN env -u SWARM_BATCH_ID -u SWARM_PRIVATE_KEY SWARM_API=$READER SWARM_GATEWAY=$READER git fetch '$URL' '+refs/*:refs/*' 2>&1 | tail -3"
runshort "PATH=$BIN git for-each-ref --count=3 --format='%(refname)'"

echo
b "── Done "
echo "   Archived to Swarm, lost completely, restored through a node that"
echo "   never saw the push, re-seeded onto the network, and readable with"
echo "   stock git alone."
echo
dim "   Local bee-factory cluster, not mainnet. Write node $WRITER,"
dim "   read node $READER."
echo
echo "   Clone it with the helper:"
echo "     git clone $URL"
echo
echo "   Or browse it: the push above printed a feed manifest reference."
echo "   Open the viewer against this cluster with"
echo "     ?gateway=\$SWARM_GATEWAY#bzz/<that reference>"
echo
