#!/usr/bin/env bash
# Run the integration suite against a local Swarm cluster.
#
#   tests/stack/run.sh              build, start, run everything, tear down
#   tests/stack/run.sh --keep       leave the cluster up afterwards
#   tests/stack/run.sh --no-cluster run only the tests that need no Swarm node
#
# Exit codes follow the repo convention: 0 pass, 1 fail, 77 skip. A skip here is
# a real result for a developer and a failure in CI — see .github/workflows.

set -euo pipefail

HERE="$(cd "$(dirname "$0")/../.." && pwd)"
STACK="$HERE/tests/stack"

KEEP=0
CLUSTER=1
for arg in "$@"; do
  case "$arg" in
    --keep)       KEEP=1 ;;
    --no-cluster) CLUSTER=0 ;;
    *) echo "run.sh: unknown option '$arg'" >&2; exit 64 ;;
  esac
done

say() { echo "run: $*" >&2; }

# Tests that need no Bee node. Run them first: they are fast, and if the ref
# layout has shifted there is no point starting a cluster.
OFFLINE_TESTS="fixture-shape.sh"
# Tests that need SWARM_API, a batch and a key.
ONLINE_TESTS="radicle-archive.sh radicle-archive-multipeer.sh radicle-archive-rewrite.sh radicle-restore.sh radicle-reseed.sh publication-durability.sh batch-mutability.sh"

build() {
  say "building images"
  docker build -q -f "$STACK/Dockerfile.radicle" -t git-swarm/radicle "$HERE" >/dev/null
  docker build -q -f "$STACK/Dockerfile.harness" -t git-swarm/harness "$HERE" >/dev/null
}

# shellcheck disable=SC2086
in_harness() {
  docker run --rm -v "$HERE:/work" ${HARNESS_ENV:-} git-swarm/harness bash -lc "$1"
}

failures=0
skips=0
ran=0

run_test() {
  local name="$1"
  local path="tests/integration/$name"
  [ -f "$HERE/$path" ] || { say "no such test: $path"; return; }
  ran=$((ran + 1))
  say "--- $name"
  set +e
  in_harness "./$path"
  local rc=$?
  set -e
  case $rc in
    0)  say "    PASS" ;;
    77) say "    SKIP"; skips=$((skips + 1)) ;;
    *)  say "    FAIL ($rc)"; failures=$((failures + 1)) ;;
  esac
}

command -v docker >/dev/null 2>&1 || { echo "SKIP: docker not installed" >&2; exit 77; }
docker info >/dev/null 2>&1 || { echo "SKIP: docker not running" >&2; exit 77; }

build

for t in $OFFLINE_TESTS; do run_test "$t"; done

if [ "$CLUSTER" -eq 1 ]; then
  say "bringing up the cluster"
  env_file="$(mktemp)"
  set +e
  "$STACK/cluster-up.sh" > "$env_file"
  rc=$?
  set -e
  if [ $rc -ne 0 ]; then
    cat "$env_file" >&2 || true
    rm -f "$env_file"
    say ""
    say "cluster unavailable (exit $rc); online tests not run"
    say "run with --no-cluster to skip this step deliberately"
    exit $rc
  fi

  # shellcheck disable=SC1090
  . "$env_file"
  rm -f "$env_file"

  # Reach the host's published ports from inside the container.
  host_api="${SWARM_API/localhost/host.docker.internal}"
  HARNESS_ENV="-e SWARM_API=$host_api -e SWARM_GATEWAY=$host_api"
  HARNESS_ENV="$HARNESS_ENV -e SWARM_BATCH_ID=$SWARM_BATCH_ID"
  HARNESS_ENV="$HARNESS_ENV -e SWARM_PRIVATE_KEY=$SWARM_PRIVATE_KEY"
  HARNESS_ENV="$HARNESS_ENV -e SWARM_OWNER=$SWARM_OWNER -e SWARM_NO_WARN=1"
  # A node that did not write the data, reachable from inside the container.
  host_worker="${SWARM_WORKER_API/localhost/host.docker.internal}"
  HARNESS_ENV="$HARNESS_ENV -e SWARM_WORKER_API=$host_worker"
  HARNESS_ENV="$HARNESS_ENV --add-host=host.docker.internal:host-gateway"
  export HARNESS_ENV

  for t in $ONLINE_TESTS; do run_test "$t"; done

  if [ "$KEEP" -eq 0 ]; then
    say "tearing down"
    "$STACK/cluster-up.sh" --down >/dev/null 2>&1 || true
  else
    say "cluster left running; stop it with tests/stack/cluster-up.sh --down"
  fi
fi

say ""
say "$ran run, $failures failed, $skips skipped"
[ "$failures" -eq 0 ] || exit 1
[ "$skips" -eq 0 ] || exit 77
exit 0
