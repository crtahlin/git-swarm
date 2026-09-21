#!/usr/bin/env bash
# Drive the Radicle test container.
#
#   tests/stack/radicle.sh build        build (or rebuild) the image
#   tests/stack/radicle.sh test         build if needed, then run the fixture tests
#   tests/stack/radicle.sh run <cmd>…   run a command inside the container
#   tests/stack/radicle.sh shell        interactive shell
#
# The repo is bind-mounted at /work, so edits to tests apply without a rebuild.

set -euo pipefail

HERE="$(cd "$(dirname "$0")/../.." && pwd)"
IMAGE="${GIT_SWARM_RADICLE_IMAGE:-git-swarm/radicle}"
DOCKERFILE="$HERE/tests/stack/Dockerfile.radicle"

die() { echo "radicle.sh: $*" >&2; exit 1; }

command -v docker >/dev/null 2>&1 || {
  echo "SKIP: docker not installed" >&2
  exit 77
}
docker info >/dev/null 2>&1 || {
  echo "SKIP: docker is installed but not running" >&2
  exit 77
}

have_image() { docker image inspect "$IMAGE" >/dev/null 2>&1; }

build() {
  echo "==> building $IMAGE (pinned radicle + httpd, checksums verified)" >&2
  docker build -f "$DOCKERFILE" -t "$IMAGE" "$HERE"
}

in_container() {
  docker run --rm -v "$HERE:/work" "$@"
}

case "${1:-test}" in
  build)
    build
    ;;
  run)
    shift
    [ $# -gt 0 ] || die "run needs a command"
    have_image || build
    in_container "$IMAGE" bash -lc "$*"
    ;;
  shell)
    have_image || build
    docker run --rm -it -v "$HERE:/work" "$IMAGE" bash
    ;;
  test)
    have_image || build
    echo "==> radicle versions" >&2
    in_container "$IMAGE" bash -lc 'rad --version; radicle-node --version' >&2
    echo "==> tests/integration/fixture-shape.sh" >&2
    in_container "$IMAGE" bash -lc './tests/integration/fixture-shape.sh'
    ;;
  *)
    die "unknown command '${1}'. Try: build, test, run, shell"
    ;;
esac
