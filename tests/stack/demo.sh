#!/usr/bin/env bash
# Run the archive story end to end, against a throwaway Swarm cluster.
#
#   tests/stack/demo.sh              watch it
#   tests/stack/demo.sh --record     record it to docs/assets/demo.cast (+ .gif)
#   tests/stack/demo.sh --fast       no pauses, for checking it still works
#   tests/stack/demo.sh --keep       leave the cluster up afterwards, so the
#                                    archived repository can be opened in the viewer
#
# Brings the cluster up, runs the story in the harness container, tears down.
# Publishes nothing outside its own containers.

set -euo pipefail

HERE="$(cd "$(dirname "$0")/../.." && pwd)"
STACK="$HERE/tests/stack"
ASSETS="$HERE/docs/assets"

RECORD=0
PAUSE=2
KEEP=0
for arg in "$@"; do
  case "$arg" in
    --record) RECORD=1 ;;
    --fast)   PAUSE=0 ;;
    --keep)   KEEP=1 ;;
    *) echo "demo.sh: unknown option '$arg'" >&2; exit 64 ;;
  esac
done

say() { echo "demo: $*" >&2; }

command -v docker >/dev/null 2>&1 || { echo "SKIP: docker not installed" >&2; exit 77; }
docker info >/dev/null 2>&1 || { echo "SKIP: docker not running" >&2; exit 77; }
if [ "$RECORD" -eq 1 ]; then
  command -v asciinema >/dev/null 2>&1 || { echo "demo: asciinema not installed" >&2; exit 78; }
fi

say "building images"
docker build -q -f "$STACK/Dockerfile.radicle" -t git-swarm/radicle "$HERE" >/dev/null
docker build -q -f "$STACK/Dockerfile.harness" -t git-swarm/harness "$HERE" >/dev/null

say "starting a throwaway Swarm cluster"
env_file="$(mktemp)"
cleanup() {
  rm -f "$env_file" "${docker_env:-}"
  if [ "$KEEP" -eq 1 ]; then
    say "cluster left running — stop it with tests/stack/cluster-up.sh --down"
    say "gateway: ${SWARM_API:-}"
    say ""
    say "to browse the archived repository in the viewer:"
    say "  node viewer/build.mjs && (cd viewer/dist && python3 -m http.server 8088)"
    say "  then open the URL the demo printed, with ?gateway=${SWARM_API:-}"
  else
    say "tearing down"
    "$STACK/cluster-up.sh" --down >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

# The demo pushes seconds after the cluster starts and reads through a node that
# did not write the data, so it needs the mesh warm. The test suite does not.
GIT_SWARM_WARMUP=1 "$STACK/cluster-up.sh" > "$env_file" || { cat "$env_file" >&2; exit 1; }
# shellcheck disable=SC1090
. "$env_file"

api="${SWARM_API/localhost/host.docker.internal}"

# Credentials go in a file, not on the command line. asciinema records the
# command it ran into the cast header, so `-e SWARM_PRIVATE_KEY=...` would ship
# a signing key inside a published artefact. It is only the throwaway Foundry
# test key, but a recording that shows keys being passed that way teaches the
# habit to whoever copies it. It also keeps them out of `ps`.
docker_env="$(mktemp)"
cat > "$docker_env" <<ENV
SWARM_API=$api
SWARM_GATEWAY=$api
SWARM_BATCH_ID=$SWARM_BATCH_ID
SWARM_PRIVATE_KEY=$SWARM_PRIVATE_KEY
SWARM_OWNER=$SWARM_OWNER
SWARM_NO_WARN=1
DEMO_PAUSE=$PAUSE
SWARM_WORKER_API=${SWARM_WORKER_API/localhost/host.docker.internal}
ENV
chmod 600 "$docker_env"

docker_args=(
  --rm -v "$HERE:/work"
  --add-host=host.docker.internal:host-gateway
  --env-file "$docker_env"
)

if [ "$RECORD" -eq 1 ]; then
  mkdir -p "$ASSETS"
  cast="$ASSETS/demo.cast"
  rm -f "$cast"
  say "recording to $cast"
  # -t allocates a tty so colours and spacing survive into the recording.
  # No --cols/--rows: asciinema 3.x accepts them and ignores them, and without a
  # tty the recording is 80x24 regardless. The story is written to fit 80.
  asciinema rec --overwrite \
    --title "git-swarm: archive a Radicle repository to Swarm and get it back" \
    -c "docker run -t ${docker_args[*]} git-swarm/harness bash -lc './tests/stack/demo-story.sh'" \
    "$cast"
  say "recorded $(wc -c < "$cast" | tr -d ' ') bytes"
  if command -v agg >/dev/null 2>&1; then
    say "rendering $ASSETS/demo.gif"
    agg "$cast" "$ASSETS/demo.gif" >/dev/null 2>&1 \
      && say "gif written" || say "agg failed; the cast is still good"
  fi
  echo
  say "replay it with:  asciinema play $cast"
else
  docker run -t "${docker_args[@]}" git-swarm/harness bash -lc './tests/stack/demo-story.sh'
fi
