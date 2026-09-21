# git-swarm

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

## Clone this repository

This project is stored on Swarm, and you can fetch it from there. Which command depends
on whether you already have the helper — which lives *inside* this repository.

### With stock git, no helper at all

The original premise, and it still works — one HTTPS URL through any gateway, nothing
installed:

```sh
git clone https://bzz.limo/bzz/<feed-manifest>/ git-swarm
```

That is Git's dumb-HTTP transport reading a tree published by
`scripts/swarm-git-mirror.sh`. It needs no helper, no node, no key and no environment.

It is kept behind a feed, so the address below is stable across republications — refresh
it after a release with `./scripts/publish-mirror.mjs`.

```
94189800f037ae60a2910d56a5447d051819dfbbdedf618eb72f38378bcb6955
```

### If you have the helper

```sh
git clone bzz://de4a9c970f265dbff707ac01f3bfa825d119a4dcdbcfeae41eff4a338f41d2d1 git-swarm
```

No Bee node, no postage batch, no key — reading is free. To read through a specific
gateway rather than a local node:

```sh
SWARM_GATEWAY=https://bzz.limo \
  git clone bzz://de4a9c970f265dbff707ac01f3bfa825d119a4dcdbcfeae41eff4a338f41d2d1 git-swarm
```

### If you do not

You need `git-remote-bzz` on `PATH` first, and it ships in this repository — so the first
copy has to come from somewhere stock `git` can already read:

```sh
git clone https://github.com/crtahlin/git-swarm.git git-swarm   # or your fork
cd git-swarm && npm install && npm link
```

Then the `bzz://` command above works, and `git pull` inside that clone comes from Swarm.

### Verify what you got

```sh
cd git-swarm
git log --oneline -3
git fsck            # every object is hash-verified; a bad byte cannot survive this
```

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

**[bzz.limo/bzz/09a5c892…/#bzz/2659451a…](https://bzz.limo/bzz/02a7f5a1109e7058734055cf07be6c361ce13534fb43ecf09a6020018020be43/#bzz/de4a9c970f265dbff707ac01f3bfa825d119a4dcdbcfeae41eff4a338f41d2d1)**

Both halves of that URL are Swarm **feeds**, so both are permanent: the left one is the
viewer, republished with `./scripts/publish-viewer.sh`; the right one is this repository,
advanced by every `git push`. Neither address changes when the content does.

The viewer opens this repository by default, so the bare address works too:
[bzz.limo/bzz/09a5c892…](https://bzz.limo/bzz/02a7f5a1109e7058734055cf07be6c361ce13534fb43ecf09a6020018020be43/).
Another deployment bakes in its own with `VIEWER_DEFAULT_TARGET`.

Use **bzz.limo**, not `download.gateway.ethswarm.org` — the latter sends
`Content-Disposition: attachment`, so a browser saves the page instead of rendering it
([why](docs/addressing.md#which-gateway)). Source in [`viewer/`](viewer/).

## The mirror, and why it matters

The HTTPS clone above is a **dumb-HTTP mirror**: a bare repository published to Swarm as
a static file tree, which stock `git` clones with no plugin, no node and no key.

The helper ships *inside* this repository, so without a mirror the only way to get a first
copy is a centralised forge — the dependency this project exists to remove. With it the
loop closes: clone from Swarm with stock git, `npm link`, and everything after that can be
native `bzz://`.

## Layout

```
bin/        the git remote helper, installed as git-remote-bzz
src/        helper internals: protocol, manifest, swarm, git plumbing
viewer/     the static web viewer (builds to viewer/dist, published to Swarm)
docs/       architecture, addressing, format spec, phase results, testing
scripts/    phase 0 mirror script
tests/      end-to-end checks, plus stack/ — a dockerised Bee + Radicle harness
```

| Document | What it covers |
|---|---|
| [`docs/addressing.md`](docs/addressing.md) | URL forms, gateways, ENS — what to type and why |
| [`docs/spec-swarm-git-format-v1.md`](docs/spec-swarm-git-format-v1.md) | the on-Swarm format, normative |
| [`docs/architecture.md`](docs/architecture.md) | the options considered, and the risk register |
| [`docs/phase-0-results.md`](docs/phase-0-results.md) · [`docs/phase-1-results.md`](docs/phase-1-results.md) | what was measured |
| [`docs/testing.md`](docs/testing.md) | how to run the tests, and what each one proves |

## Requirements

- A Bee node reachable on `http://localhost:1633` (light node is sufficient for uploads)
- A funded postage batch (`swarm-cli stamp list`) — Swarm storage is rented, not permanent
- `git` 2.x, `curl`, `python3`

Reading needs none of it. To run the tests you need Docker instead of a node — see
[`docs/testing.md`](docs/testing.md); they use a throwaway cluster and never touch mainnet.

## Contributing

Issues are welcome and are read; there is no promise that any given one gets implemented,
or when. See [CONTRIBUTING.md](CONTRIBUTING.md).

MIT licensed — see [LICENSE](LICENSE).

## Status

Early proof of concept. Nothing here is production ready, and the postage economics
(§ "Swarm is rented storage" in the architecture doc) mean nothing stored by this
project survives without its batch being topped up.
