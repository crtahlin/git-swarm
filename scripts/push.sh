#!/usr/bin/env bash
#
# Push to the Swarm remote, signing with the shared ontheswarm feed key.
#
#   ./scripts/push.sh [git push args…]
#
# The key is read from the sibling secrets directory at run time and passed via
# the environment. It is deliberately NOT stored in .git/config: one canonical
# copy of a secret is easier to protect, rotate and reason about than two.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KEYFILE="${SWARM_KEYFILE:-$HERE/../secrets/feed-owner.key}"
REMOTE="${REMOTE:-swarm}"

[ -f "$KEYFILE" ] || { echo "no key file at $KEYFILE" >&2; exit 78; }

SWARM_PRIVATE_KEY="$(awk -F= '/^feed_owner_privkey/{print $2}' "$KEYFILE" | tr -d ' \r')"
[ -n "$SWARM_PRIVATE_KEY" ] || { echo "feed_owner_privkey not found in $KEYFILE" >&2; exit 78; }
export SWARM_PRIVATE_KEY

exec git push "$REMOTE" "${@:-main}"
