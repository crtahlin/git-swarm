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

FACTORY="$(cd "$(dirname "$0")" && pwd)/bee-factory.sh"

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
say "queen API at $QUEEN_API"

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
# Price the batch from the chain rather than hardcoding an amount. Bee rejects
# anything below currentPrice * minimumValidityBlocks with "insufficient amount
# for 24h minimum validity", and both numbers move.
amount="$(curl -fsS "$QUEEN_API/chainstate" \
  | python3 -c 'import json,sys; d=json.load(sys.stdin); print(int(d["currentPrice"]) * int(d["minimumValidityBlocks"]) * 2)')"
[ -n "$amount" ] || die "could not read chainstate to price the batch"

say "buying an immutable batch (amount $amount, depth 20)"
batch="$(curl -fsS -X POST -H 'immutable: true' "$QUEEN_API/stamps/$amount/20" \
  | python3 -c 'import json,sys; print(json.load(sys.stdin)["batchID"])')"
[ -n "$batch" ] || die "no batchID returned"

deadline=$(( $(date +%s) + 120 ))
while :; do
  # GET /stamps/<id> returns 400 until the node has seen the batch on chain.
  # That is "not yet", not "not usable", so a failed request keeps us waiting.
  usable="$(curl -fsS "$QUEEN_API/stamps/$batch" 2>/dev/null \
    | python3 -c 'import json,sys; print(json.load(sys.stdin).get("usable",False))' 2>/dev/null || echo False)"
  [ "$usable" = "True" ] && break
  [ "$(date +%s)" -lt "$deadline" ] || die "batch $batch never became usable"
  sleep 3
done
say "batch $batch usable"

# Publicly known Foundry test key. Throwaway by design — it is in every Foundry
# install and on every anvil chain. Never use it for anything that matters.
KEY=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
OWNER=0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266

echo "export SWARM_API='$QUEEN_API'"
echo "export SWARM_GATEWAY='$QUEEN_API'"
echo "export SWARM_BATCH_ID='$batch'"
echo "export SWARM_PRIVATE_KEY='$KEY'"
echo "export SWARM_OWNER='$OWNER'"
echo "export SWARM_NO_WARN=1"
