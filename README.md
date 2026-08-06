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
| 1 | `git-remote-bzz` — real `git push bzz::…` / `git clone bzz://…` | **done** — [results](docs/phase-1-results.md), [format spec](docs/spec-swarm-git-format-v1.md) |
| 2 | Forge surface — static web viewer, Git-native issues, ACT private repos | viewer **done**, rest planned |
| 3 | Ecosystem — Radicle archival seeding, Forgejo post-receive mirror | planned |

Work is tracked as GitHub issues, one per phase plus one per task.

## Use it

Swarm as an ordinary git remote. Install the helper once:

```sh
npm install && npm link      # puts git-remote-bzz on PATH
```

Then point a repository at Swarm. Pushing needs a local Bee node, a postage batch and a
signing key; reading needs none of them.

```sh
git remote add origin bzz::<owner-address>/<repo-name>
git config remote.origin.swarmBatch <batch-id>
git config remote.origin.swarmKey   <hex-private-key>

git push origin main
git clone bzz::<owner-address>/<repo-name> elsewhere
```

A read-only clone works through a public gateway with no node, batch or key:

```sh
SWARM_GATEWAY=https://bzz.limo git clone bzz://<feed-manifest-ref> elsewhere
SWARM_GATEWAY=https://bzz.limo git clone bzz://<name>.eth elsewhere
```

`bzz://<reference>` is a **content reference** and means the same thing here as in a
browser; `bzz::<owner>/<repo>` is a **repository endpoint**, read-write and not something
a browser can open. Full rules, gateway choice and ENS setup:
[`docs/addressing.md`](docs/addressing.md).

Nothing here patches Git. `git-remote-bzz` is an executable on `PATH` — the extension
point `gitremote-helpers(7)` documents, and the same mechanism Git's own HTTPS transport
uses. `swarm://` and `git-remote-swarm` still work.

## Browse it in a browser

This project's own repository, rendered by a viewer that is itself stored on Swarm.
No server, no backend — the page fetches the packfiles and reconstructs the repository
in your browser:

**[bzz.limo/bzz/09a5c892…/#bzz/2659451a…](https://bzz.limo/bzz/09a5c8924336625cad2dc0be13c0dd74f8b5d1d33fb9ba5b057340893188a19c/#bzz/2659451ac307f86a6e9f2286ffbfc7f33776d0f154ce899eab4ea535ab35a237)**

Both halves of that URL are Swarm **feeds**, so both are permanent: the left one is the
viewer, republished with `./scripts/publish-viewer.sh`; the right one is this repository,
advanced by every `git push`. Neither address changes when the content does.

The viewer opens this repository by default, so the bare address works too:
[bzz.limo/bzz/09a5c892…](https://bzz.limo/bzz/09a5c8924336625cad2dc0be13c0dd74f8b5d1d33fb9ba5b057340893188a19c/).
Another deployment bakes in its own with `VIEWER_DEFAULT_TARGET`.

Use **bzz.limo**, not `download.gateway.ethswarm.org` — the latter sends
`Content-Disposition: attachment`, so a browser saves the page instead of rendering it
([why](docs/addressing.md#which-gateway)). Source in [`viewer/`](viewer/).

## Try the Phase 0 mirror

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
bin/        the git remote helper, installed as git-remote-bzz
src/        helper internals: protocol, manifest, swarm, git plumbing
viewer/     the static web viewer (builds to viewer/dist, published to Swarm)
docs/       architecture, addressing, format spec, phase results
scripts/    phase 0 mirror script
tests/      end-to-end checks — round trip, gateway clone, served-page links
```

| Document | What it covers |
|---|---|
| [`docs/addressing.md`](docs/addressing.md) | URL forms, gateways, ENS — what to type and why |
| [`docs/spec-swarm-git-format-v1.md`](docs/spec-swarm-git-format-v1.md) | the on-Swarm format, normative |
| [`docs/architecture.md`](docs/architecture.md) | the options considered, and the risk register |
| [`docs/phase-0-results.md`](docs/phase-0-results.md) · [`docs/phase-1-results.md`](docs/phase-1-results.md) | what was measured |

## Requirements

- A Bee node reachable on `http://localhost:1633` (light node is sufficient for uploads)
- A funded postage batch (`swarm-cli stamp list`) — Swarm storage is rented, not permanent
- `git` 2.x, `curl`, `python3`

## Status

Early proof of concept. Nothing here is production ready, and the postage economics
(§ "Swarm is rented storage" in the architecture doc) mean nothing stored by this
project survives without its batch being topped up.
