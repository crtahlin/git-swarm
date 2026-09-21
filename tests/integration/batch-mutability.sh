#!/usr/bin/env bash
# A mutable batch must be refused, and an immutable one accepted.
#
# swarm-git/1 is append-only. A mutable batch evicts its oldest stamps once a
# bucket fills and the network collects the chunks behind them, so pushes keep
# reporting success while older packs stop resolving. That is the worst shape a
# storage bug can take, and it is not hypothetical: radicle-index-service runs a
# mutable batch for its feed heal loop and measured 292 of 2428 chain chunks
# gone in a day.
#
# Credentials come from the caller. This test buys its own batches, so it needs
# a node it is allowed to spend on — tests/stack/run.sh provides a throwaway one.

set -euo pipefail

HERE="$(cd "$(dirname "$0")/../.." && pwd)"
. "$HERE/tests/stack/batch-lib.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
skip() { echo "SKIP: $*" >&2; exit 77; }

command -v git-remote-bzz >/dev/null 2>&1 || skip "git-remote-bzz not on PATH"

API="${SWARM_API:-}"
[ -n "$API" ]                   || skip "SWARM_API not set"
[ -n "${SWARM_PRIVATE_KEY:-}" ] || skip "SWARM_PRIVATE_KEY not set"
[ -n "${SWARM_OWNER:-}" ]       || skip "SWARM_OWNER not set"

# Never buy batches on someone's real node. The throwaway cluster runs on a
# local chain, so a wallet with a plausible mainnet balance means we are pointed
# at the wrong place.
chain="$(curl -fsS "$API/wallet" 2>/dev/null \
  | python3 -c 'import json,sys; print(json.load(sys.stdin).get("chainID",0))' 2>/dev/null || echo 0)"
[ "${chain:-0}" = "1337" ] || skip "not a local test chain (chainID $chain); this test buys batches"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

make_repo() {
  local dir="$1"
  git init -q -b main "$dir"
  printf 'batch mutability probe\n' > "$dir/README.md"
  git -C "$dir" add -A
  git -C "$dir" -c user.email=t@example.invalid -c user.name=probe commit -qm "probe"
}

push_with() {
  local batch="$1" dir="$2" name="$3"
  SWARM_BATCH_ID="$batch" SWARM_NO_WARN=1 \
    git -C "$dir" push "bzz::${SWARM_OWNER}/${name}" main 2>&1
}

echo "==> buying a mutable batch"
mutable="$(buy_usable_batch "$API" false)" || fail "could not get a usable mutable batch"
flag="$(curl -fsS "$API/stamps/$mutable" | python3 -c 'import json,sys; print(json.load(sys.stdin)["immutableFlag"])')"
[ "$flag" = "False" ] || fail "asked for a mutable batch and got immutableFlag=$flag"
echo "    $mutable (immutableFlag false)"

make_repo "$TMP/a"
echo "==> pushing with it — must be refused"
if out="$(push_with "$mutable" "$TMP/a" "mutable-probe-$$")"; then
  fail "push with a mutable batch succeeded; it must be refused"
fi
case "$out" in
  *"is mutable"*) : ;;
  *) echo "$out" >&2; fail "refused, but not for mutability" ;;
esac
# The message has to say what to do, not just that something is wrong.
case "$out" in
  *"immutable: true"*) : ;;
  *) echo "$out" >&2; fail "refusal does not show how to buy an immutable batch" ;;
esac
echo "==> refused, with the fix in the message                ok"

echo "==> same push with SWARM_ALLOW_MUTABLE_BATCH=1 — must proceed"
if out="$(SWARM_ALLOW_MUTABLE_BATCH=1 push_with "$mutable" "$TMP/a" "mutable-override-$$")"; then
  echo "==> override honoured                                  ok"
else
  echo "$out" >&2
  fail "override did not let the push through"
fi

echo "==> buying an immutable batch"
immutable="$(buy_usable_batch "$API" true)" || fail "could not get a usable immutable batch"

make_repo "$TMP/b"
echo "==> pushing with it — must succeed"
if out="$(push_with "$immutable" "$TMP/b" "immutable-probe-$$")"; then
  echo "==> immutable batch accepted                           ok"
else
  echo "$out" >&2
  fail "push with an immutable batch was refused"
fi

echo
echo "PASS"
