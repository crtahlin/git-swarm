# Phase 0 results — a repository on Swarm, cloned with stock git

Date: 2026-08-06
Issues: #1 (epic), #5, #6, #7, #10

## Verdict

**It works.** A Git repository published to Swarm can be cloned by anyone with nothing
but `git` and a URL, through a public gateway, with no Bee node, no plugin and no
account:

```
git clone https://download.gateway.ethswarm.org/bzz/<reference>/ myrepo
```

The clone passes `git fsck` and its HEAD matches the source. This closes the go/no-go
question the phase existed to answer, and it means the scenario that started the project
— a forge deleting your data, or a jurisdiction blocking it — has a working answer today,
without waiting for Phase 1.

## What was built

- `scripts/swarm-git-mirror.sh` — stages a bare mirror, repacks, writes the dumb-HTTP
  server info, uploads the tree to Swarm, and advances a feed
- `tests/clone-from-gateway.sh` — the go/no-go test: clone from a gateway, `fsck`,
  compare HEAD

The mechanism is Git's dumb-HTTP transport. It needs three things present at fixed
paths, which `git update-server-info` produces and Swarm's mantaray manifests serve
unchanged: `HEAD`, `info/refs`, and `objects/info/packs`.

The repack step is not cosmetic. Dumb HTTP over Swarm fetches whole files; a repository
left as thousands of loose objects would mean thousands of round trips. Packed, a
22 MB repository is a handful of files.

## Two URLs, two different guarantees

| URL | Backed by | Guarantee |
|---|---|---|
| Snapshot | A bzz reference | Immutable — always exactly this state of the repository |
| Feed | A Swarm feed (signed single-owner chunk) | Stable across republishes — only the key holder can move it |

Both were verified. The feed case is the important one: after committing new work and
re-running the mirror, **the feed address was unchanged and a fresh clone of that same
URL returned the new commit**. That is the authenticated mutable pointer that Git lacks
and that a centralised forge normally provides.

Feed address for this repository: `b9250d4dd334ad8b140e754d08904328b5ff2e80f07a7c4dd0fc3a65bbc8601c`
(topic `swarm-git-poc`; the owner address is whichever key signs the feed).

## Measurements

| Repository | Mirror size | Publish | Clone from Swarm gateway | Clone from GitHub |
|---|---|---|---|---|
| git-swarm (this repo) | 52 kB | ~3 s | 8–17 s (feed) / <1 s (snapshot) | — |
| ethersphere/bee-js | 22 MB | 15 s | **41 s** | **2 s** |

Roughly **20× slower than GitHub** for a 22 MB repository. That is a usable number for
archival and disaster recovery, and not yet a number that would make anyone switch their
daily workflow. It is also the honest baseline Phase 1 has to improve on, and it says the
pack-based layout decision was correct — a per-object mapping would have been far worse.

The feed path costs a fixed penalty (feed lookup) that dominates for small repositories:
8–17 s for a 52 kB repo where the snapshot URL was effectively instant.

## Cost, and the expiry that comes with it

| | |
|---|---|
| Batch | a depth-19 immutable batch bought for the phase |
| Type | Immutable, depth 19, amount 8,423,654,400 |
| Cost | **0.441 xBZZ** (wallet 3.818 → 3.377) |
| Capacity | 102.49 MB usable |
| TTL at purchase | ~7 days (604,436 s) |

**Every URL in this document dies when that batch expires**, some time around
2026-08-13, unless it is topped up. This is the central honesty constraint of the whole
project: Swarm is rented storage. Any claim that code published this way "can never be
taken down" is false unless someone keeps paying.

Batch utilisation is measured in bucket fill, not bytes, so small repositories look
disproportionately expensive: the 52 kB repo alone registered 13% utilisation, and the
22 MB repo took it to 38%.

## Findings worth carrying into Phase 1

1. **Deferred uploads are not immediately retrievable.** The 22 MB repository returned
   200 from `localhost:1633` straight away but **404 from the public gateway for roughly
   30–60 seconds** while chunks propagated. The mirror script currently prints a clone
   URL that may not work yet. It should poll the public gateway before declaring
   success — a URL that 404s for a minute reads as a broken product.
2. **The feed lookup is the latency floor** for small repositories. Worth measuring
   properly against feed type before Phase 1 commits to a feed layout.
3. **Path fidelity through mantaray is exact.** `objects/info/packs` and `info/refs`
   resolved unchanged through both the local node and the public gateway, and Git's
   smart-protocol probe (`info/refs?service=git-upload-pack`) fell back to dumb HTTP
   cleanly. No query-string handling problem materialised.
4. **`--mirror` publishes everything**, including every branch and tag. That is correct
   for an archive and wrong for a light publish — 22 MB on Swarm versus an 11 MB default
   GitHub clone of the same project.

## Limits of what was proven

- **Read-only.** There is no push. Updating means re-running the mirror from a machine
  that holds the batch and the feed key. That is Phase 1.
- **Single writer**, one feed key, no delegation.
- **Public only.** Everything published here is world-readable and, for as long as the
  batch lives, unremovable.
- The feed signing key was generated with `swarm-cli identity create --only-keypair`,
  which stores it in cleartext in the local swarm-cli config. Acceptable for a
  throwaway POC key that holds no funds; not acceptable for anything real.

## Reproducing

```sh
cp .env.example .env          # set SWARM_BATCH_ID and SWARM_FEED_IDENTITY
./scripts/swarm-git-mirror.sh <repo-path-or-url> [name]
./tests/clone-from-gateway.sh <reference> [expected-head-sha]
```
