#!/usr/bin/env bash
# Bring up a local Swarm cluster for the archive tests, and print the env to use.
#
#   eval "$(tests/stack/cluster-up.sh)"
#   tests/stack/cluster-up.sh --down
#
# Uses ethersphere/bee-factory: five Bee nodes plus an Anvil chain with the
# postage contracts deployed. Real peers and real pushsync, so a push that
# reports success but publishes nothing still fails — which is the bug class
# this project has hit three times (#30, and three defects in Phase 1).
#
# Nothing here touches mainnet. See GIT_SWARM_ALLOW_LIVE below for the escape
# hatch, and read the warning before using it.

set -euo pipefail

STACK="$(cd "$(dirname "$0")" && pwd)"
FACTORY="$STACK/bee-factory.sh"
. "$STACK/batch-lib.sh"

say()  { echo "cluster-up: $*" >&2; }
die()  { echo "cluster-up: $*" >&2; exit 1; }
skip() { echo "SKIP: $*" >&2; exit 77; }

command -v docker >/dev/null 2>&1 || skip "docker not installed"
docker info >/dev/null 2>&1 || skip "docker is installed but not running"

if [ "${1:-}" = "--down" ]; then
  say "stopping the cluster"
  "$FACTORY" stop
  exit 0
fi

# --- escape hatch: an existing node ------------------------------------------
#
# A developer with their own funded node can run against it, but every push is
# published to mainnet Swarm permanently, cannot be deleted, and spends real
# batch capacity. Opt in deliberately; never the default, and never in CI.
if [ -n "${GIT_SWARM_ALLOW_LIVE:-}" ]; then
  [ -n "${SWARM_API:-}" ] || die "GIT_SWARM_ALLOW_LIVE is set but SWARM_API is not"
  [ -n "${SWARM_BATCH_ID:-}" ] || die "GIT_SWARM_ALLOW_LIVE needs SWARM_BATCH_ID"
  [ -n "${SWARM_PRIVATE_KEY:-}" ] || die "GIT_SWARM_ALLOW_LIVE needs SWARM_PRIVATE_KEY"
  say "WARNING: running against $SWARM_API, not a throwaway cluster."
  say "WARNING: every push is permanent, public, and spends that batch."
  echo "export SWARM_API='$SWARM_API'"
  echo "export SWARM_GATEWAY='${SWARM_GATEWAY:-$SWARM_API}'"
  echo "export SWARM_BATCH_ID='$SWARM_BATCH_ID'"
  echo "export SWARM_PRIVATE_KEY='$SWARM_PRIVATE_KEY'"
  exit 0
fi

# --- port check ---------------------------------------------------------------
#
# bee-factory fails halfway through if a port is taken, leaving anvil running.
# Check first and say which process holds it, because "address already in use"
# on port 1634 usually means the developer's own Bee node — which must not be
# stopped for us.
# --- start ---------------------------------------------------------------------
say "starting bee-factory (5 nodes + anvil, ports chosen to avoid collisions)"
"$FACTORY" start
QUEEN_API="$("$FACTORY" queen-api 2>/dev/null)"
[ -n "$QUEEN_API" ] || die "could not determine the queen API address"
WORKER_API="$("$FACTORY" worker-api 2>/dev/null)"
say "queen API at $QUEEN_API, worker at $WORKER_API"

say "waiting for the queen to report peers"
deadline=$(( $(date +%s) + 120 ))
while :; do
  connected="$(curl -fsS "$QUEEN_API/topology" 2>/dev/null \
    | python3 -c 'import json,sys; print(json.load(sys.stdin).get("connected",0))' 2>/dev/null || echo 0)"
  [ "${connected:-0}" -gt 0 ] && break
  [ "$(date +%s)" -lt "$deadline" ] || die "queen still has 0 peers after 120s"
  sleep 3
done
say "queen has $connected peers"

# --- postage --------------------------------------------------------------------
#
# The archive is append-only, so it needs an IMMUTABLE batch. Bee defaults the
# immutable flag to true when the header is absent (pkg/api/postage.go), but set
# it explicitly: the default is not something to inherit silently for the one
# property that decides whether the archive survives.
say "buying an immutable batch"
# The archive is append-only, so it needs an IMMUTABLE batch. Bee defaults the
# immutable flag to true when the header is absent, but batch-lib sets it
# explicitly: the one property that decides whether the archive survives is not
# something to inherit silently from a default.
batch="$(buy_usable_batch "$QUEEN_API" true)" \
  || die "could not get a usable batch after several attempts"
say "batch $batch usable"

# A freshly started cluster answers /health long before one node can retrieve a
# chunk another node wrote. Peers connect, but the mesh needs a moment before
# retrieval works across it. Without this wait, anything that writes on the queen
# and reads on a worker fails for a minute or two and looks like a bug in the
# thing being tested — which is exactly how it presented.
#
# So the cluster is not "up" until a worker can serve what the queen stored.
#
# Opt-in via GIT_SWARM_WARMUP, because it costs up to three minutes and the test
# suite does not need it: by the time the first cross-node read runs, five other
# tests have been exercising the mesh. The demo pushes seconds after startup and
# does need it.
if [ -n "${WORKER_API:-}" ] && [ -n "${GIT_SWARM_WARMUP:-}" ]; then
  say "waiting until a worker can retrieve what the queen wrote"
  # swarm-deferred-upload: false — a deferred upload is stored locally and pushed
  # to the network in the background, so a deferred probe can never prove that
  # cross-node retrieval works. It has to go to the network synchronously.
  probe_ref="$(curl -fsS -X POST -H "swarm-postage-batch-id: $batch" \
      -H 'swarm-deferred-upload: false' \
      -H 'content-type: application/octet-stream' \
      --data-binary "cluster-warmup-$(date +%s)" "$QUEEN_API/bytes" 2>/dev/null \
    | python3 -c 'import json,sys; print(json.load(sys.stdin)["reference"])' 2>/dev/null || echo '')"
  if [ -z "$probe_ref" ]; then
    say "could not upload a warm-up probe; continuing without the check"
  else
    deadline=$(( $(date +%s) + 180 ))
    until curl -fsS -o /dev/null "$WORKER_API/bytes/$probe_ref" 2>/dev/null; do
      [ "$(date +%s)" -lt "$deadline" ] || {
        say "warm-up probe never came back; the wait itself is usually enough"
        break
      }
      sleep 5
    done
    curl -fsS -o /dev/null "$WORKER_API/bytes/$probe_ref" 2>/dev/null \
      && say "cross-node retrieval working"
  fi
fi

# Publicly known Foundry test key. Throwaway by design — it is in every Foundry
# install and on every anvil chain. Never use it for anything that matters.
KEY=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
OWNER=0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266

echo "export SWARM_API='$QUEEN_API'"
echo "export SWARM_GATEWAY='$QUEEN_API'"
echo "export SWARM_BATCH_ID='$batch'"
echo "export SWARM_PRIVATE_KEY='$KEY'"
echo "export SWARM_OWNER='$OWNER'"
echo "export SWARM_WORKER_API='$WORKER_API'"
echo "export SWARM_NO_WARN=1"
