# Testing

Two kinds of test, and the difference matters more here than in most projects.

The tests that need no Swarm node run anywhere. The ones that do run against a **throwaway
five-node Bee cluster in Docker**, never against mainnet and never against your own node.
That is not fastidiousness: a push to Swarm is permanent, public, and spends a real postage
batch, so a test suite that publishes is a test suite you stop running.

```sh
tests/stack/run.sh              # everything: builds images, starts a cluster, tears it down
tests/stack/run.sh --no-cluster # only the tests that need no Bee node
tests/stack/run.sh --keep       # leave the cluster up to poke at
```

Exit codes follow the convention already used here: **0 pass, 1 fail, 77 skip**. `run.sh`
counts skips separately and returns 77 if any test skipped. In CI a skip is a failure — a
suite that skips everything because the helper or the cluster is missing looks exactly like
a suite that passed, and that is how a broken harness survives.

## What each test proves

| Test | Needs a node | Proves |
|---|---|---|
| `fixture-shape.sh` | no | What a Radicle storage repo actually contains. Every ref a commit, the namespace carrying `sigrefs`/`id`/`root`, sigrefs a commit over a `refs`+`signature` tree, and a second push fast-forwarding it |
| `radicle-archive.sh` | yes | A bare Radicle storage repo pushed with `refs/*:refs/*` and fetched back with every ref byte-identical, `fsck` clean, sigrefs still verifiable |
| `radicle-restore.sh` | yes | A **fresh** install with a **different** identity restores from `bzz://` and `rad inspect` recovers a byte-identical identity document — with no batch and no key in the environment |
| `batch-mutability.sh` | yes | A mutable batch is refused with the fix named in the message, the override works, an immutable batch is accepted |
| `radicle-archive-multipeer.sh` | yes | The same round trip for a repository holding two peers' namespaces, built by two real radicle-nodes replicating |
| `publication-durability.sh` | yes | A repository pushed through one node is readable from a **different** node — the only test that distinguishes "published" from "stored locally" |

`fixture-shape.sh` exists because two issues were filed from assumptions about the Radicle
ref layout and both were wrong. Reading heartwood's source was not enough. It is the
regression guard: if Radicle changes the shape, a test fails instead of a design document
going quietly stale.

## The stack

| Piece | What it is |
|---|---|
| `Dockerfile.radicle` | alpine, radicle 1.10.3 and radicle-httpd 0.29.0 pinned by version **and** sha256, non-root, arm64/amd64 |
| `Dockerfile.harness` | the above plus node and the helper. Product code baked, test scripts bind-mounted |
| `seed-fixture.sh` | builds a real storage repo: own `RAD_HOME`, no node started, no announce, repo private |
| `bee-factory.sh` | installs bee-factory and moves its ports out of the way |
| `batch-lib.sh` | buys a postage batch that the node can actually use |
| `cluster-up.sh` | starts the cluster and prints the environment to use |
| `run.sh` | runs the suite |

Images are pinned rather than tracking `latest`. A test image that drifts lets the fixture
shift underneath the assertions, which is exactly how the ref layout got misdescribed.

### Two upstream problems the stack works around

Both are filed; the workarounds are commented at the point of use.

**Ports** ([bee-factory#321](https://github.com/ethersphere/bee-factory/issues/321)).
bee-factory's ports are compile-time constants handed straight to Docker — no compose file,
no flag, no environment variable. 1633 is Bee's own default, so it collides with anyone who
already runs a node. `bee-factory.sh` installs a pinned copy, probes for a free block and
rewrites the constants. It also has to teach anvil to honour `ANVIL_PORT`, which upstream
never needed to pass because the constant always matched anvil's default.

**Lost batches** ([bee-factory#322](https://github.com/ethersphere/bee-factory/issues/322)).
Just after startup, a batch purchase can be mined into a block *behind* the node's synced
position. The transaction succeeds, the receipt says `status: 0x1`, and the node never sees
the batch. Waiting does not help; buying again does. `batch-lib.sh` retries the purchase.

## Running against a real node

`tests/e2e-push-clone.sh` still runs against your own node and batch, as it always has, and
reads `.env`:

```sh
SWARM_OWNER=… SWARM_BATCH_ID=… SWARM_PRIVATE_KEY=… ./tests/e2e-push-clone.sh
```

**The archive tests deliberately do not read `.env`.** A sourced assignment beats the
environment, so sourcing it would silently swap your real batch in place of the cluster's —
and those tests push. This is not hypothetical; it happened while they were being written,
and only failed because the cluster did not recognise the batch.

`cluster-up.sh` has an opt-in escape hatch, `GIT_SWARM_ALLOW_LIVE`, for running the suite
against an existing node. It warns loudly. Everything it publishes is permanent.

## Requirements

- Docker
- node ≥ 20 and npm, for bee-factory
- Roughly 1 GB of images on first run

Everything else — radicle, the helper, python3, git — lives in the containers. The tests
skip cleanly with 77 when Docker is missing or not running.
