"""Make bee-factory's ports configurable, by rewriting them.

Usage: patch-bee-factory-ports.py <package-dir> <offset>

bee-factory bakes 1633-1642 and 8545 into dist/config.js and hands them to
Docker as PortBindings. Nothing about them is configurable — no compose file, no
flag, and BEE_FACTORY_HUB_ORG is the only environment variable it reads. Port
1633 is where a developer's own Bee node usually lives, so the defaults collide
with the machine of anyone working on Swarm.

Two edits:

  config.js   shift apiPort, p2pPort and ANVIL_PORT by the offset.
  manager.js  pass --port to anvil. Upstream never did, because ANVIL_PORT was
              always 8545 and so was anvil's default. Shift the constant without
              this and the container publishes a port nothing listens on, which
              fails sixty seconds later as a health-check timeout that says
              nothing about ports.

Every edit reads from a pristine copy kept alongside the original, so re-running
with a different offset replaces the shift instead of compounding it.

Each edit asserts its match count. A silent no-op would leave the cluster on the
default ports, fighting the node this exists to avoid, and every log line after
that would look correct.
"""

import re
import shutil
import sys
from pathlib import Path


def pristine_copy(path):
    """Return a pristine copy of path, creating it on first use."""
    orig = path.with_suffix(path.suffix + ".orig")
    if not orig.exists():
        shutil.copy2(path, orig)
    return orig


def patch_config(path, offset):
    src = pristine_copy(path).read_text()

    def bump(match):
        return "{}{}".format(match.group(1), int(match.group(2)) + offset)

    src, api = re.subn(r"(apiPort: )(\d+)", bump, src)
    src, p2p = re.subn(r"(p2pPort: )(\d+)", bump, src)
    src, anvil = re.subn(r"(exports\.ANVIL_PORT = )(\d+)", bump, src)

    if (api, p2p, anvil) != (5, 5, 1):
        sys.exit(
            "config.js matched api={} p2p={} anvil={}, expected 5/5/1 — "
            "bee-factory's config shape changed".format(api, p2p, anvil)
        )

    path.write_text(src)
    return api + p2p + anvil


def patch_manager(path):
    src = pristine_copy(path).read_text()

    needle = "        'anvil',\n        '--host', '0.0.0.0',\n"
    replacement = (
        "        'anvil',\n"
        "        '--host', '0.0.0.0',\n"
        "        '--port', String(config_1.ANVIL_PORT),\n"
    )

    count = src.count(needle)
    if count != 1:
        sys.exit(
            "manager.js: found {} anvil argument lists, expected 1 — "
            "bee-factory's anvil launch changed".format(count)
        )

    path.write_text(src.replace(needle, replacement, 1))
    return 1


def main(argv):
    if len(argv) != 3:
        sys.exit("usage: patch-bee-factory-ports.py <package-dir> <offset>")

    pkg, offset = Path(argv[1]), int(argv[2])
    config = pkg / "dist" / "config.js"
    manager = pkg / "dist" / "docker" / "manager.js"

    for path in (config, manager):
        if not path.is_file():
            sys.exit("no such file: {}".format(path))

    ports = patch_config(config, offset)
    patch_manager(manager)

    print(
        "patched {} ports by +{}, and taught anvil to honour its port".format(
            ports, offset
        ),
        file=sys.stderr,
    )


if __name__ == "__main__":
    main(sys.argv)
