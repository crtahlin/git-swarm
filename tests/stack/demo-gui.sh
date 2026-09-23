#!/usr/bin/env bash
# Show a restored repository in canopy — the Radicle forge UI.
#
#   tests/stack/demo-gui.sh              bring it up and leave it running
#   tests/stack/demo-gui.sh --record     record docs/assets/canopy.gif and tear down
#
# The terminal demo (demo.sh) shows the archive and restore. This shows what you
# get at the end of it: an ordinary forge — file tree, commits, issues, patches —
# reading a repository that exists only because it came back out of Swarm.
#
# It does NOT touch your own Radicle install or Freedom Browser. canopy reads
# CANOPY_HTTPD and CANOPY_BEE from the environment, so it is pointed at a
# throwaway node in a container.
#
# canopy is a third-party application (solardev-xyz). This clones and runs it
# from a cache directory; nothing is added to this repository.

set -euo pipefail

HERE="$(cd "$(dirname "$0")/../.." && pwd)"
STACK="$HERE/tests/stack"
CACHE="${GIT_SWARM_CACHE:-${TMPDIR:-/tmp}/git-swarm-demo}"
CANOPY="$CACHE/canopy"
CANOPY_REPO="${CANOPY_REPO:-https://github.com/solardev-xyz/canopy.git}"
HTTPD_PORT="${HTTPD_PORT:-8099}"
CANOPY_PORT="${CANOPY_PORT:-5173}"
CONTAINER=git-swarm-demo-gui

RECORD=0
[ "${1:-}" = "--record" ] && RECORD=1
[ -n "${1:-}" ] && [ "${1:-}" != "--record" ] && { echo "unknown option '$1'" >&2; exit 64; }

say() { echo "demo-gui: $*" >&2; }

command -v docker >/dev/null 2>&1 || { echo "SKIP: docker not installed" >&2; exit 77; }
docker info >/dev/null 2>&1 || { echo "SKIP: docker not running" >&2; exit 77; }
command -v npm >/dev/null 2>&1 || { echo "SKIP: npm not available" >&2; exit 77; }

canopy_pid=""
cleanup() {
  [ -n "$canopy_pid" ] && kill "$canopy_pid" 2>/dev/null || true
  docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
  if [ "$RECORD" -eq 1 ]; then
    say "tearing down"
    "$STACK/cluster-up.sh" --down >/dev/null 2>&1 || true
  else
    say "left running. stop with:"
    say "  docker rm -f $CONTAINER && $STACK/cluster-up.sh --down"
  fi
}
trap cleanup EXIT

say "building images"
docker build -q -f "$STACK/Dockerfile.radicle" -t git-swarm/radicle "$HERE" >/dev/null
docker build -q -f "$STACK/Dockerfile.harness" -t git-swarm/harness "$HERE" >/dev/null

if [ ! -d "$CANOPY/node_modules" ]; then
  say "fetching canopy into $CANOPY (third-party, solardev-xyz)"
  mkdir -p "$CACHE"
  [ -d "$CANOPY/.git" ] || git clone -q --depth 1 "$CANOPY_REPO" "$CANOPY"
  (cd "$CANOPY" && npm install --no-audit --no-fund --loglevel=error >/dev/null)
fi

say "starting a Swarm cluster (with warm-up, because we read through a second node)"
env_file="$(mktemp)"
GIT_SWARM_WARMUP=1 "$STACK/cluster-up.sh" > "$env_file" || { cat "$env_file" >&2; exit 1; }
# shellcheck disable=SC1090
. "$env_file"
rm -f "$env_file"

api="${SWARM_API/localhost/host.docker.internal}"
worker="${SWARM_WORKER_API:-$SWARM_API}"
worker="${worker/localhost/host.docker.internal}"

docker_env="$(mktemp)"
cat > "$docker_env" <<ENV
SWARM_API=$api
SWARM_GATEWAY=$api
SWARM_WORKER_API=$worker
SWARM_BATCH_ID=$SWARM_BATCH_ID
SWARM_PRIVATE_KEY=$SWARM_PRIVATE_KEY
SWARM_OWNER=$SWARM_OWNER
SWARM_NO_WARN=1
ENV
chmod 600 "$docker_env"

say "archiving a repository, deleting it, and restoring it through another node"
docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
docker run -d --name "$CONTAINER" -p "$HTTPD_PORT:8080" \
  -v "$HERE:/work" --add-host=host.docker.internal:host-gateway \
  --env-file "$docker_env" git-swarm/harness bash -lc '
set -e
export RAD_PASSPHRASE=
N="gui-$(date +%s)"; U="bzz::$SWARM_OWNER/$N"
RID=$(/work/tests/stack/seed-fixture.sh /rad/o alice public 2>/dev/null)
cd /rad/o/storage/$RID && git push -q "$U" "+refs/*:refs/*"
cd / && rm -rf /rad/o          # the original is gone, keys and all
R=/rad/r; mkdir -p $R
RAD_HOME=$R rad auth --alias viewer >/dev/null 2>&1
mkdir -p $R/storage/$RID && git init -q --bare $R/storage/$RID && cd $R/storage/$RID
env -u SWARM_BATCH_ID -u SWARM_PRIVATE_KEY \
    SWARM_API=$SWARM_WORKER_API SWARM_GATEWAY=$SWARM_WORKER_API \
    git fetch -q "$U" "+refs/*:refs/*"
echo "$RID" > /tmp/rid
RAD_HOME=$R rad seed "rad:$RID" >/dev/null 2>&1
rm -f $R/node/control.sock
RAD_HOME=$R radicle-node > /tmp/node.log 2>&1 &
for i in $(seq 30); do [ -S $R/node/control.sock ] && break; sleep 1; done
RAD_HOME=$R radicle-httpd --listen 0.0.0.0:8080 > /tmp/httpd.log 2>&1 &
sleep 7200
' >/dev/null
rm -f "$docker_env"

deadline=$(( $(date +%s) + 420 ))
until docker exec "$CONTAINER" cat /tmp/rid >/dev/null 2>&1; do
  [ "$(date +%s)" -lt "$deadline" ] || {
    docker logs "$CONTAINER" 2>&1 | tail -20 >&2
    echo "demo-gui: restore never completed" >&2; exit 1
  }
  sleep 8
done
RID="$(docker exec "$CONTAINER" cat /tmp/rid)"
say "restored rad:$RID"

until curl -fsS "http://localhost:$HTTPD_PORT/api/v1/repos/rad:$RID" >/dev/null 2>&1; do sleep 3; done
say "radicle-httpd is serving it on :$HTTPD_PORT"

say "starting canopy against that node"
( cd "$CANOPY" && CANOPY_HTTPD="http://localhost:$HTTPD_PORT" CANOPY_BEE="$SWARM_API" \
    npm run dev -- --port "$CANOPY_PORT" > "$CACHE/canopy.log" 2>&1 ) &
canopy_pid=$!
until curl -fsS -o /dev/null "http://localhost:$CANOPY_PORT/"; do sleep 2; done

URL="http://localhost:$CANOPY_PORT/#/rad:$RID"
if [ "$RECORD" -eq 1 ]; then
  say "recording"
  ( cd "$HERE/viewer" && node record-canopy.mjs "http://localhost:$CANOPY_PORT" "$RID" \
      "$HERE/docs/assets/canopy.gif" )
  say "wrote docs/assets/canopy.gif"
else
  say ""
  say "open this:  $URL"
  say ""
  say "It is an ordinary forge — file tree, commits, issues, patches. The"
  say "repository it is showing exists only because it came back out of Swarm."
  say "Press Ctrl-C to stop."
  wait "$canopy_pid"
fi
