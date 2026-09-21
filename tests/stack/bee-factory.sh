#!/usr/bin/env bash
# bee-factory on ports that do not collide with whatever else you run.
#
#   tests/stack/bee-factory.sh start
#   tests/stack/bee-factory.sh stop
#   tests/stack/bee-factory.sh ports | queen-api | offset
#
# bee-factory hardcodes 1633-1642 and 8545 in dist/config.js and hands them
# straight to Docker as PortBindings. There is no compose file, no CLI flag, and
# no environment variable — BEE_FACTORY_HUB_ORG is the only one it reads. 1633 is
# also where a developer's own Bee node lives, so the default collides with the
# machine of anyone actually working on Swarm. Observed here: a Bee node on
# 1633/1634 and Freedom Browser's antd on 11633.
#
# So: install a pinned copy locally, probe for a free block of ports, and rewrite
# the constants. The patch asserts it matched what it expected — a silent no-op
# would bring the cluster up on the defaults, fighting the node we set out to
# avoid, and the logs would look fine.
#
# Filed upstream: ethersphere/bee-factory#321 (ports not configurable, and the
# anvil --port trap below).

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
VERSION="${BEE_FACTORY_VERSION:-1.1.2}"
PREFIX="$HERE/.bee-factory"
PKG="$PREFIX/node_modules/@ethersphere/bee-factory"
BIN="$PREFIX/node_modules/.bin/bee-factory"
OFFSET_FILE="$PREFIX/.port-offset"
PATCHER="$HERE/patch-bee-factory-ports.py"

say() { echo "bee-factory: $*" >&2; }
die() { echo "bee-factory: $*" >&2; exit 1; }

# Upstream defaults, before the offset. Keep in step with config.js.
BASE_ANVIL=8545
BASE_API="1633 1635 1637 1639 1641"
BASE_P2P="1634 1636 1638 1640 1642"

# Tried in order. A fixed offset cannot know what else is on the machine, which
# is why 10000 is a candidate rather than the answer.
CANDIDATES="${BEE_FACTORY_PORT_OFFSETS:-10000 20000 30000 40000 50000}"

# No SO_REUSEADDR, and both addresses: docker publishes on 0.0.0.0, so a
# loopback-only listener still conflicts. Setting SO_REUSEADDR made an earlier
# version of this probe bind straight past a node listening on 127.0.0.1.
port_free() {
  python3 -c 'import socket, sys
port = int(sys.argv[1])
for host in ("0.0.0.0", "127.0.0.1"):
    s = socket.socket()
    try:
        s.bind((host, port))
    except OSError:
        sys.exit(1)
    finally:
        s.close()
sys.exit(0)' "$1"
}

block_free() {
  local off="$1" p
  for p in $BASE_API $BASE_P2P $BASE_ANVIL; do
    port_free $(( p + off )) || return 1
  done
  return 0
}

pick_offset() {
  # An explicit choice wins even if the probe dislikes it: the caller may know
  # something it does not.
  if [ -n "${BEE_FACTORY_PORT_OFFSET:-}" ]; then
    echo "$BEE_FACTORY_PORT_OFFSET"
    return 0
  fi
  # Reuse the offset of a cluster already up, so start and stop agree.
  if [ -f "$OFFSET_FILE" ] && docker ps --format '{{.Names}}' 2>/dev/null | grep -q '^bee-factory-'; then
    cat "$OFFSET_FILE"
    return 0
  fi
  local off
  for off in $CANDIDATES; do
    if block_free "$off"; then
      echo "$off"
      return 0
    fi
    say "offset +$off is occupied, trying the next"
  done
  die "no free port block in: $CANDIDATES (set BEE_FACTORY_PORT_OFFSET)"
}

install_pkg() {
  [ -x "$BIN" ] && return 0
  say "installing @ethersphere/bee-factory@$VERSION into tests/stack/.bee-factory"
  mkdir -p "$PREFIX"
  npm install --prefix "$PREFIX" --no-audit --no-fund --loglevel=error \
    "@ethersphere/bee-factory@$VERSION" >&2
  [ -x "$BIN" ] || die "install finished but $BIN is missing"
}

patch_ports() {
  [ -d "$PKG" ] || die "no bee-factory package at $PKG"
  # The patcher keeps its own pristine copies and always works from them, so
  # re-running with a different offset replaces the shift rather than adding to
  # it — which would look entirely plausible in the logs.
  python3 "$PATCHER" "$PKG" "$1"
  echo "$1" > "$OFFSET_FILE"
}

prepare() {
  install_pkg
  OFFSET="$(pick_offset)"
  patch_ports "$OFFSET"
}

ports() {
  local out="" p
  for p in $BASE_API $BASE_P2P $BASE_ANVIL; do
    out="$out $(( p + OFFSET ))"
  done
  echo "${out# }"
}

queen_api() { echo "http://localhost:$(( 1633 + OFFSET ))"; }

# Worker 1. Reading a repository back from a node that did not write it is the
# only way to tell "published" from "stored locally", which is the failure this
# project has shipped three times.
worker_api() { echo "http://localhost:$(( 1635 + OFFSET ))"; }

command -v docker >/dev/null 2>&1 || { echo "SKIP: docker not installed" >&2; exit 77; }
command -v npm >/dev/null 2>&1 || { echo "SKIP: npm not available" >&2; exit 77; }

case "${1:-}" in
  ports)     prepare; ports ;;
  queen-api)  prepare; queen_api ;;
  worker-api) prepare; worker_api ;;
  offset)    prepare; echo "$OFFSET" ;;
  start)
    shift
    prepare
    say "starting on +$OFFSET (queen API $(queen_api))"
    "$BIN" start --tag "${BEE_FACTORY_TAG:-v2.8.2}" "$@" >&2
    ;;
  stop)
    prepare
    "$BIN" stop >&2
    ;;
  *)
    die "usage: $0 {start|stop|ports|queen-api|worker-api|offset}"
    ;;
esac
