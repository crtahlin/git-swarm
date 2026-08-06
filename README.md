# swarm-git-POC

Proof of concept for hosting Git repositories — and eventually a full code forge — on
[Ethereum Swarm](https://www.ethswarm.org/).

## Why

Git already gives every clone a complete, cryptographically verifiable copy of a
repository. What it does not give you is a durable place for those objects to live when
nobody is running a server, or an authenticated way to publish "the current tip of
`main`". Centralised forges supply both, at the cost of a single point of deletion and a
single jurisdiction that can block you.

Swarm supplies exactly the two missing pieces: content-addressed durable chunk storage,
and feeds — signed, single-owner mutable pointers.

## The architectural bet

"GitHub on Swarm" decomposes into five layers, and only two are hard:

| Layer | Solved by Git already? | What we build |
|---|---|---|
| Objects (commits/trees/blobs) | Yes — content-addressed | Durable storage of packfiles on Swarm |
| Refs (authenticated mutable pointer) | No | Swarm feed, signed by the owner key |
| Identity / private access | Partly | Delegate keys + ACT encryption |
| Issues, patches, reviews | Yes, *if* stored as Git objects | Nothing — adopt Radicle COBs or git-bug |
| Web UI | No | Static SPA on Swarm |
| CI / compute | No | Out of scope — Swarm is storage |

The consequence, and the most important decision in this project: **we do not build an
issue tracker.** If issues and patches are Git objects, durable Git gives us the social
layer for free.

Full analysis, options considered and rejected, and the risk register:
[`docs/architecture.md`](docs/architecture.md).

## Phases

| Phase | Goal | Status |
|---|---|---|
| 0 | Static read-only mirror — `git clone` a repo from a Swarm gateway with stock Git | **done** — [results](docs/phase-0-results.md) |
| 1 | `git-remote-swarm` — real `git push swarm://…` / `git clone swarm://…` | planned |
| 2 | Forge surface — static web viewer, Git-native issues, ACT private repos | planned |
| 3 | Ecosystem — Radicle archival seeding, Forgejo post-receive mirror | planned |

Work is tracked as GitHub issues, one per phase plus one per task.

## Try it

This repository is published on Swarm. Clone it from there with stock `git` — no Bee
node, no plugin, no account:

```sh
git clone https://download.gateway.ethswarm.org/bzz/b9250d4dd334ad8b140e754d08904328b5ff2e80f07a7c4dd0fc3a65bbc8601c/ swarm-git-poc
```

That URL is a Swarm feed, so it keeps pointing at the latest published state. It stays
alive only while its postage batch is topped up — see the cost section of the
[Phase 0 results](docs/phase-0-results.md).

## Layout

```
docs/       architecture, specs, benchmark results
scripts/    working tools (phase 0: the mirror script)
tests/      end-to-end checks — the clone-from-gateway proof
```

## Requirements

- A Bee node reachable on `http://localhost:1633` (light node is sufficient for uploads)
- A funded postage batch (`swarm-cli stamp list`) — Swarm storage is rented, not permanent
- `git` 2.x, `curl`, `python3`

## Status

Early proof of concept. Nothing here is production ready, and the postage economics
(§ "Swarm is rented storage" in the architecture doc) mean nothing stored by this
project survives without its batch being topped up.
