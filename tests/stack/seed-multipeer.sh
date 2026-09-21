#!/usr/bin/env bash
# Build a Radicle storage repo that holds TWO peers' namespaces.
#
# The single-peer fixture cannot answer the question #33 and #34 are both left
# open on: what an archive has to carry once other peers are replicated into a
# repository. That is where refs are added, removed and regressed between
# crawls, and it is the shape an index service actually sees.
#
# Faking it by copying refs into a second namespace would produce something
# structurally plausible whose sigrefs do not verify — worse than no fixture,
# because it would pass. So this runs two real nodes and lets Radicle replicate.
#
# Usage: seed-multipeer.sh <base-dir>
# Prints the RID on stdout; everything else goes to stderr. The two RAD_HOMEs
# are <base-dir>/a and <base-dir>/b.

set -euo pipefail

BASE="${1:-}"
[ -n "$BASE" ] || { echo "usage: $0 <base-dir>" >&2; exit 64; }

for bin in rad radicle-node git; do
  command -v "$bin" >/dev/null 2>&1 || { echo "seed-multipeer: $bin not on PATH" >&2; exit 77; }
done

# radicle-node's control socket lives under RAD_HOME and the path has a ~100
# character limit, with an error that never mentions the socket. Here a node
# really does start, so this is fatal rather than a warning.
if [ ${#BASE} -gt 40 ]; then
  echo "seed-multipeer: base dir is ${#BASE} chars; keep it short — a node's" >&2
  echo "seed-multipeer: control socket path is limited to about 100 characters" >&2
  exit 78
fi

A="$BASE/a"
B="$BASE/b"
WORK_A="$BASE/wa"
WORK_B="$BASE/wb"
LOG="$BASE/logs"
mkdir -p "$A" "$B" "$WORK_A" "$LOG"

export RAD_PASSPHRASE=''
unset SSH_AUTH_SOCK || true
unset SSH_AGENT_PID || true

NODE_PIDS=''
cleanup() {
  for pid in $NODE_PIDS; do kill "$pid" 2>/dev/null || true; done
}
trap cleanup EXIT

say() { echo "seed-multipeer: $*" >&2; }

# Keep both nodes off the public network. They can still reach each other: the
# isolation is about preferred seeds and bootstrap, not about refusing peers we
# connect to deliberately.
isolate() {
  python3 - "$1/config.json" <<'PY'
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
}

start_node() {
  local home="$1" name="$2" listen="${3:-}"
  rm -f "$home/node/control.sock"   # a stale socket blocks startup
  if [ -n "$listen" ]; then
    RAD_HOME="$home" radicle-node --listen "$listen" > "$LOG/$name.log" 2>&1 &
  else
    RAD_HOME="$home" radicle-node > "$LOG/$name.log" 2>&1 &
  fi
  NODE_PIDS="$NODE_PIDS $!"
  local deadline=$(( $(date +%s) + 30 ))
  while [ ! -S "$home/node/control.sock" ]; do
    [ "$(date +%s)" -lt "$deadline" ] || {
      say "node $name did not create its control socket"
      tail -20 "$LOG/$name.log" >&2 || true
      return 1
    }
    sleep 1
  done
  say "node $name up"
}

# --- peer A: creates the repository -------------------------------------------
[ -f "$A/keys/radicle" ] || RAD_HOME="$A" rad auth --alias alice >/dev/null 2>&1
isolate "$A"
A_NID="$(RAD_HOME="$A" rad self --nid)"

cd "$WORK_A"
if [ ! -d .git ]; then
  git init -q -b main .
  printf 'multi-peer archive fixture\n' > README.md
  git add -A
  git -c user.email=alice@example.invalid -c user.name=alice commit -qm "alice: initial"
fi

# Public, not private: a private repository is only visible to peers explicitly
# allowed, and replication is the whole point here. Safe because both nodes sit
# on an isolated test network with no seeds.
if ! rad . >/dev/null 2>&1; then
  RAD_HOME="$A" rad init --name multipeer --description "two-peer archive fixture" \
    --default-branch main --public --no-confirm >/dev/null 2>&1
fi
RID="$(RAD_HOME="$A" rad . | sed 's/^rad://')"
say "peer A $A_NID created rad:$RID"

start_node "$A" alice "0.0.0.0:8776"

# --- peer B: clones it, contributes, pushes back ------------------------------
[ -f "$B/keys/radicle" ] || RAD_HOME="$B" rad auth --alias bob >/dev/null 2>&1
isolate "$B"
B_NID="$(RAD_HOME="$B" rad self --nid)"
start_node "$B" bob

say "connecting B to A"
RAD_HOME="$B" rad node connect "$A_NID@127.0.0.1:8776" --timeout 30sec >&2 \
  || { say "connect failed"; tail -20 "$LOG/bob.log" >&2; exit 1; }

say "B cloning rad:$RID"
cd "$BASE"
RAD_HOME="$B" rad clone "rad:$RID" --no-confirm >&2 2>/dev/null \
  || RAD_HOME="$B" rad clone "rad:$RID" >&2

cd "$WORK_B" 2>/dev/null || cd "$BASE/multipeer"
printf 'a line from bob\n' >> README.md
git add -A
git -c user.email=bob@example.invalid -c user.name=bob commit -qm "bob: contribution"
RAD_HOME="$B" git push rad >&2

say "waiting for A to see B's namespace"
deadline=$(( $(date +%s) + 90 ))
while :; do
  if git -C "$A/storage/$RID" show-ref --verify --quiet \
       "refs/namespaces/$B_NID/refs/rad/sigrefs"; then
    break
  fi
  [ "$(date +%s)" -lt "$deadline" ] || {
    say "A never replicated B's namespace"
    say "--- alice ---"; tail -25 "$LOG/alice.log" >&2 || true
    say "--- bob ---";   tail -25 "$LOG/bob.log" >&2 || true
    exit 1
  }
  sleep 3
done

peers="$(git -C "$A/storage/$RID" for-each-ref --format='%(refname)' \
  | sed -n 's|refs/namespaces/\([^/]*\)/.*|\1|p' | sort -u | wc -l | tr -d ' ')"
say "storage repo holds $peers namespaces"
[ "$peers" -ge 2 ] || { say "expected at least 2 namespaces"; exit 1; }

echo "$RID"
