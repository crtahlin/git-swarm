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

**Caveat, and it is the important one:** the mirror is only as current as the last time
that script was run. The published mirror at
`b9250d4dd334ad8b140e754d08904328b5ff2e80f07a7c4dd0fc3a65bbc8601c` is a Phase 0 snapshot —
it predates the helper, so it cannot bootstrap anyone today. Re-running the mirror against
the current tree fixes that, and doing it on every push would keep it fixed. See #26.

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

> **Known gap.** A Phase 0 dumb-HTTP mirror exists at
> `b9250d4dd334ad8b140e754d08904328b5ff2e80f07a7c4dd0fc3a65bbc8601c`, clonable with stock
> `git` and no helper — but it is a Phase 0 snapshot, predating the helper itself, so it
> cannot bootstrap you. Re-running `scripts/swarm-git-mirror.sh` against the current tree
> would close that loop and make Swarm-only bootstrapping real: stock `git` clone → `npm
> link` → native `bzz://` from then on.

## Before you push anything

**What goes onto Swarm cannot be taken back.** Uploads are content-addressed and
replicated to nodes you do not control. There is no delete, no overwrite, and no
takedown — not by you, not by anyone.

For a Git tool this has a sharper edge than usual, because the habits that normally
save you do not work here:

- **`git push --force` does not unpublish anything.** It moves the feed to a new
  manifest. Every earlier manifest and every earlier packfile is still on Swarm at its
  own address, still readable by anyone holding the reference.
- **Rewriting history does not remove it.** `git rebase`, `git commit --amend` and
  `git filter-repo` change what your repository points at, not what Swarm already
  stores.
- **A committed secret is a published secret.** If a key, token or password reaches a
  push, treat it as compromised and rotate it. Removing it from the working tree
  changes nothing.

Unencrypted uploads are world-readable by anyone with the reference, and references
appear in manifests, feeds and links. Assume anything you publish is public and
permanent.

Two honest qualifications, because "permanent" is often overstated:

- Storage is **rented**. When a postage batch lapses, content stops being retrievable
  from the network — so data can *disappear*, even though you cannot *delete* it. Those
  are different things, and neither is under your control once published.
- Anyone who fetched it already has a copy, whatever happens to the batch.

Private repositories need encryption at upload time, which is not implemented yet.
Until then, publish nothing you would not put on a public website.

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

## Contributing

Issues are welcome and are read; there is no promise that any given one gets implemented,
or when. See [CONTRIBUTING.md](CONTRIBUTING.md).

MIT licensed — see [LICENSE](LICENSE).

## Status

Early proof of concept. Nothing here is production ready, and the postage economics
(§ "Swarm is rented storage" in the architecture doc) mean nothing stored by this
project survives without its batch being topped up.
