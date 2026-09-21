#!/usr/bin/env bash
# Buying a postage batch on a local test chain, reliably.
#
# Sourced by tests/stack/cluster-up.sh on the host and by integration tests
# inside the harness container. Both hit the same two hazards.

# Minimum spend Bee will accept, read from the chain. A hardcoded amount is
# rejected outright with "insufficient amount for 24h minimum validity", and both
# the price and the minimum validity move.
batch_amount() {
  local api="$1"
  curl -fsS "$api/chainstate" | python3 -c '
import json, sys
d = json.load(sys.stdin)
print(int(d["currentPrice"]) * int(d["minimumValidityBlocks"]) * 2)'
}

# True once the node has an issuer for this batch.
#
# GET /stamps/<id> answers 404 "issuer does not exist" until then, which means
# "not yet" and not "not usable" — a failed request has to keep us waiting.
batch_usable() {
  local api="$1" id="$2"
  curl -fsS "$api/stamps/$id" 2>/dev/null | python3 -c '
import json, sys
sys.exit(0 if json.load(sys.stdin).get("usable") else 1)' 2>/dev/null
}

# Buy a batch and return its id once the node can actually use it.
#
#   buy_usable_batch <api> <immutable true|false> [depth] [attempts] [per-attempt seconds]
#
# Retries the purchase, not just the wait. Shortly after the cluster starts, a
# batch transaction can be mined into a block *behind* the node's scan position:
# the transaction succeeds, the receipt says status 0x1, and the node never sees
# the batch at all. Observed on bee-factory right after its anvil state restore —
# mined at block 494 while the node was already synced past 500. Waiting longer
# does not help; buying again does. Filed upstream: ethersphere/bee-factory#322.
buy_usable_batch() {
  local api="$1" immutable="$2" depth="${3:-20}" attempts="${4:-3}" window="${5:-90}"
  local amount id deadline n=1

  amount="$(batch_amount "$api")" || return 1
  [ -n "$amount" ] || return 1

  while [ "$n" -le "$attempts" ]; do
    id="$(curl -fsS -X POST -H "immutable: $immutable" "$api/stamps/$amount/$depth" \
      | python3 -c 'import json,sys; print(json.load(sys.stdin)["batchID"])' 2>/dev/null)"

    if [ -n "$id" ]; then
      deadline=$(( $(date +%s) + window ))
      while [ "$(date +%s)" -lt "$deadline" ]; do
        if batch_usable "$api" "$id"; then
          echo "$id"
          return 0
        fi
        sleep 3
      done
      echo "batch-lib: batch ${id:0:8}… never registered (attempt $n/$attempts), buying another" >&2
    else
      echo "batch-lib: purchase failed (attempt $n/$attempts)" >&2
    fi
    n=$(( n + 1 ))
  done

  return 1
}
