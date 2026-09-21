#!/usr/bin/env bash
# Build a real Radicle storage repo to archive in tests.
#
# Everything the archive tests assert about ref layout comes from a repo this
# script made, not from reading heartwood's source. That distinction has already
# cost this project two wrong issues — see #33 and #34.
#
# Isolated by construction: its own RAD_HOME, no node started, no announce, and
# the repo is private so nothing reaches the network even if a node appears.
#
# Usage: seed-fixture.sh <rad-home> [peer-alias]
# Prints the RID on stdout. Everything else goes to stderr.

set -euo pipefail

HOME_DIR="${1:-}"
ALIAS="${2:-fixturebot}"

[ -n "$HOME_DIR" ] || { echo "usage: $0 <rad-home> [peer-alias]" >&2; exit 64; }

for bin in rad git; do
  command -v "$bin" >/dev/null 2>&1 || {
    echo "seed-fixture: $bin not on PATH" >&2
    exit 77
  }
done

# The node's control socket path has a ~100 character limit, and the error you
# get when you exceed it does not mention the socket. Fail here instead, where
# the cause is obvious.
# Warn, do not fail: the limit bites only once a node is running, and this
# script never starts one. The script that does must treat it as fatal.
if [ ${#HOME_DIR} -gt 60 ]; then
  echo "seed-fixture: warning — RAD_HOME is ${#HOME_DIR} chars" >&2
  echo "seed-fixture: fine here, but radicle-node's control socket lives under it" >&2
  echo "seed-fixture: and has a ~100 char limit. Use a shorter path to run a node." >&2
fi

export RAD_HOME="$HOME_DIR"
export RAD_PASSPHRASE=''      # empty => unencrypted keystore => no ssh-agent, no prompt
unset SSH_AUTH_SOCK || true   # heartwood's own create-env.sh does this
unset SSH_AGENT_PID || true

WORK="$HOME_DIR.work"
mkdir -p "$HOME_DIR" "$WORK"

if [ ! -f "$HOME_DIR/keys/radicle" ]; then
  rad auth --alias "$ALIAS" >&2
fi

# Keep the node off the public network even if someone starts one later.
CONFIG="$HOME_DIR/config.json"
if [ -f "$CONFIG" ]; then
  python3 - "$CONFIG" <<'PY' >&2
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
print('seed-fixture: isolated config written')
PY
fi

cd "$WORK"
if [ ! -d .git ]; then
  git init -q -b main .
  printf 'fixture repository for git-swarm archive tests\n' > README.md
  git add -A
  git -c user.email=fixture@example.invalid -c user.name="$ALIAS" \
      commit -qm "initial commit"
fi

if ! rad . >/dev/null 2>&1; then
  rad init \
    --name fixture \
    --description "git-swarm archive fixture" \
    --default-branch main \
    --private \
    --no-confirm >&2
fi

RID="$(rad . | sed 's/^rad://')"

# A second commit, so sigrefs has a parent and the archive covers an update
# rather than only a creation. A single-entry sigrefs is a root commit and
# hides every ancestry question worth testing.
if [ "$(git rev-list --count HEAD)" -lt 2 ]; then
  printf 'second line\n' >> README.md
  git add -A
  git -c user.email=fixture@example.invalid -c user.name="$ALIAS" \
      commit -qm "second commit"
  git push -q rad main >&2 2>/dev/null || git push rad main >&2
fi

echo "seed-fixture: storage repo at $HOME_DIR/storage/$RID" >&2
echo "$RID"
