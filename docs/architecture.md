# Git(Hub) on Swarm — architecture options and plan

Date: 2026-08-06 · Option C updated 2026-09-21
Status: Phases 0 and 1 shipped; Phase 2 partly shipped. This document is the
standing options analysis and risk register, not a status page — see the README
phase table and the issue tracker for where the work actually stands.
Author: Crt Ahlin (with agent assistance)

---

## 1. The problem, stated precisely

The trigger case: a developer lost blog posts hosted on a Google service; the surviving
copy was on GitHub. This exposes two distinct failure modes that are often conflated:

1. **Provider deletion / account loss** — the host removes the data or the account.
   GitHub mitigates this only if GitHub itself keeps working for you.
2. **Blocking / jurisdictional censorship** — GitHub is reachable, but not to you
   (national blocks, sanctions, corporate policy). GitHub has blocked
   sanctioned-country accounts before; it is a single, US-jurisdiction chokepoint.

Git itself already solves a third problem people assume it doesn't: **integrity and
replication**. Every clone is a full, cryptographically-verifiable copy. What Git does
*not* provide is: a durable place for those objects to live when no one is running a
server, an authenticated way to publish "the current tip of `main`", and the social
layer (issues, reviews, discovery) that makes GitHub sticky.

So "GitHub on Swarm" is not one problem. It is five layers, and only two of them are
genuinely hard.

---

## 2. Decomposition: what GitHub actually is

| Layer | What it does | Already solved by Git? | Swarm work needed |
|---|---|---|---|
| L0 Objects | Store commits/trees/blobs | Yes — content-addressed, verifiable | Durable storage of packfiles |
| L1 Refs | "`main` is at sha X", authenticated | No — refs are unsigned mutable pointers | Feeds (single-owner chunks), signed |
| L2 Identity / access | Who may move `main`? private repos | Partially (signed commits) | Delegate set + ACT for private repos |
| L3 Social | Issues, PRs, reviews, discussions | Yes, if you use Git-native CRDTs (Radicle COBs, git-bug) | Nothing — rides along in L0 |
| L4 Presentation | Web UI, browse, search, discovery | No | Static SPA on Swarm |
| L5 Compute | CI, merge queues, actions | No | Out of scope — Swarm is storage, not compute |

**Key insight:** if issues and patches are stored as Git objects (which Radicle's
Collaborative Objects and git-bug both do), then solving L0+L1 gives you L3 for free.
The whole "GitHub" surface collapses into "durable Git + a viewer". This is the single
most important architectural decision in this document: *do not build an issue tracker.*

---

## 3. Swarm primitive mapping

| Requirement | Swarm primitive | Notes / caveats |
|---|---|---|
| Immutable object storage | Chunks (4 KB), BMT, `/bzz` uploads, mantaray manifests | Content-addressed, dedupes naturally across pushes |
| Mutable "latest state" pointer | Feeds (sequential single-owner chunks, signed by an Ethereum key) | Authenticity is intrinsic — only the key holder can move the ref |
| Human-readable name | ENS content-hash → feed manifest | Mainnet gas cost; a Gnosis-side registry is the cheap alternative |
| Private repos | ACT (access control trie), grantee lists | Revocation = re-encryption; per-grantee cost |
| Push notification / discovery | GSOC / PSS | Optional; lets a mirror bot react to pushes |
| Durability | Postage batches (rented), erasure coding | **This is the sharp edge — see §6.1** |
| Serving to plain `git` clients | Gateway `/bzz/<ref>/<path>` static file serving | Enables Git's dumb-HTTP clone with zero client install |

---

## 4. Options considered

### Option A — Swarm mirror (static, read-only)
Publish a repo's `.git` directory (after `git update-server-info`) as a mantaray
manifest, plus a feed pointing at the latest manifest. Anyone can then run
`git clone https://<gateway>/bzz/<hash>/` with stock Git over the dumb-HTTP protocol —
no plugin, no node.

- Effort: **1–2 days** for a working script plus a demo repo.
- Value: immediately solves the actual scenario that started this (data survives even
  if GitHub disappears or is blocked), and is a strong demo.
- Limits: read-only, whole-tree republish per update (chunk-level dedup keeps the
  incremental cost low but every push re-stamps), and some *hosting platforms* have
  dropped dumb-HTTP support (Git the client still supports it — verify against the
  current Git release before promising it).

### Option B — `git-remote-swarm` (the missing primitive)
A Git remote helper, so `git push swarm://<owner>/<repo>` and
`git clone swarm://<owner>/<repo>` work natively. Push writes an incremental packfile
to Swarm and advances a feed; fetch resolves the feed, pulls the pack chain, and
indexes it locally. No server anywhere in the loop.

Sketch of the on-Swarm format:

```
feed(owner=0x…, topic=H("repo:<name>"))  ->  manifest_N
manifest_N = {
  format: 1,
  refs:  { "refs/heads/main": "<sha>", "refs/tags/v1": "<sha>", … },
  packs: [ { ref: "<bzz-ref>", batch: "<batch-id>", tips: […], base: […] } ],
  prev:  "<bzz-ref of manifest_{N-1}>"
}
```

- Effort: **1–3 weeks** for an MVP (single writer, public repos, push/fetch/clone);
  **+2–4 weeks** for ACT-encrypted private repos, multiple writers, and ENS naming.
- Value: this is the piece that **does not exist today**. Equivalents exist for IPFS
  (`git-remote-ipfs`, largely unmaintained since ~2021), Arweave, and Gitopia (Cosmos),
  but there is no Swarm one. It is also the foundation every other option needs.

### Option C — Radicle + Swarm (archival seeding)
Radicle Heartwood is peer-to-peer Git with identity, issues and patches as Git-native
CRDTs, plus a working desktop and web client. Its documented weak spot is **data
availability**: a repo lives only as long as some node chooses to seed it, and nothing
pays anyone to keep seeding. That is what Swarm sells.

**Updated 2026-09-21.** Most of this option now exists, built by
[solardev-xyz](https://github.com/solardev-xyz) rather than by us. They proposed the
integration in [#31](https://github.com/crtahlin/git-swarm/issues/31).

Swarm plays three separate roles in that stack. Two are already built:

| Role | What it means | Built by | Status |
|---|---|---|---|
| App delivery | The forge UI is served from `bzz://` | canopy | done |
| Discovery | A signed feed lists what is on the network | radicle-index-service | done |
| Repo persistence | The Git objects survive when no peer seeds them | nobody | **open — our piece** |

The parts that exist:

- [canopy](https://github.com/solardev-xyz/canopy) — a GitHub-style forge for Radicle,
  served from Swarm. Reads go to the user's own `radicle-httpd`; actions go through a
  `window.radicle` provider.
- [radicle-index-service](https://github.com/solardev-xyz/radicle-index-service) —
  crawls the Radicle gossip network and publishes a signed `radicle-index/v1` index to a
  Swarm feed. Its trust rule: the index decides what you see, your node decides what is
  true.
- [libradicle](https://github.com/solardev-xyz/libradicle) — an embeddable Radicle node
  in Rust with a napi binding.
- [Freedom Browser](https://github.com/solardev-xyz/freedom-browser) — a browser that
  embeds both a Bee node and a Radicle node, so `bzz://` and `rad:` resolve locally with
  no gateway. That also removes the gateway limitation in spec §4.1: `/feeds` works, so
  the `bzz::<owner>/<repo>` endpoint form resolves client-side.

So Swarm is already a publishing and discovery backend for Radicle. It is not yet a
storage backend. Availability is still "some node chose to seed this", and the index
will keep listing repos whose data is gone.

The archival mirror is what is missing, and `git-remote-bzz` is the only missing part.
It has two halves:

1. **Archive.** The index service pushes each repo it crawls to Swarm in the Option B
   format, and records `"swarm": "bzz://<feed-manifest-ref>"` in the repo's index entry.
2. **Restore.** A client clones from that reference when no peer is seeding. Nobody has
   built this half. Without it the archive is never read and proves nothing.

Four constraints to hold:

- **This is a mirror, not a storage driver.** radicle-node will not learn to speak
  Swarm; its storage layer is not pluggable. That is the same finding as Option D below.
  Say "Swarm archives Radicle repos", not "Swarm backs Radicle".
- **Archive the bare storage repo, not one namespace's view.** Radicle
  self-certification lives in `refs/namespaces/<nid>/refs/rad/sigrefs` for every peer,
  plus `refs/rad/id` and `refs/rad/root`. An archive holding only `refs/heads` cannot be
  verified after restore. swarm-git/1 does not filter refs, so the format already allows
  the full set — but the helper enforces fast-forward on every ref, and Radicle
  force-writes sigrefs as a normal operation (`force_save` in heartwood
  `crates/radicle/src/storage/refs.rs`). An archival mirror needs mirror semantics:
  record what the source says, rather than defending a branch from its own history.
- **Two batches, split by recovery path.** The index service needs a mutable batch,
  because its heal loop re-stamps the whole feed chain. A mutable batch evicts old
  stamps under that churn: they measured 292 of 2428 chain chunks lost on 2026-08-19.
  That is survivable for an index, which rebuilds from gossip. It is not survivable for
  an archive, which rebuilds from nothing. Keep packs on an immutable batch, per §6.1.
- **No single-vendor dependency.** Browser, forge, index and Radicle binding are one
  vendor today. The archive must stay readable with stock `git` plus the helper, with no
  Freedom Browser and no canopy. Test that; do not assume it.

- Effort: **2–4 weeks**, down from 4–8. The node, the index and the client already
  exist. We supply the push path, the restore path and the format guarantees.
- Value: unchanged, and still the highest ceiling. We inherit identity, issues, patches
  and a client, and supply the one thing Radicle lacks.
- Risk: dependency on another project's roadmap and goodwill, now concentrated in a
  single vendor. The neutrality constraint above is the mitigation.

### Option D — Forgejo/Gitea with Swarm underneath
Checked and **partially blocked**: Forgejo/Gitea can put LFS, attachments, avatars,
packages and Actions artifacts in S3-compatible storage, but *not the Git repositories
themselves* — the server shells out to `git`, and `git` cannot operate on object
storage. Storing repos in S3/Swarm would require switching to the pure-Go `gogit`
path and writing a storage driver against it: substantial, poorly-tested work.

The tractable version: run Forgejo normally as the "hot" forge (fast, familiar, has
CI), and add (i) a push-mirror or post-receive hook that publishes each repo to Swarm
using Option B, and (ii) an S3-compatible Swarm shim for the LFS/artifact buckets.
Swarm becomes the durable cold layer; Forgejo stays the working surface.

- Effort: **1–2 weeks** for the mirror hook once Option B exists; the S3 shim is a
  separate, optional piece.
- Value: this is the enterprise-shaped answer and it fits the existing
  self-hosted GitLab/Gitea setup.

### Option E — Build a full forge from scratch
Rejected. It means re-implementing identity, CRDT collaboration, a client, and a web
UI, all before delivering anything. Every hard part except storage is already solved by
someone whose licence lets you use it.

---

## 5. Recommendation

**Sequence A → B → (D and C in parallel).** Concretely:

- **Phase 0 (this week, ~2 days): "my code cannot be deleted."**
  Script that mirrors a Git repo to Swarm as a static tree + feed, and proves
  `git clone https://<gateway>/bzz/<ref>/` works from a machine with nothing installed.
  Also solves the trigger case for the personal blog/notes.

- **Phase 1 (2–4 weeks): `git-remote-swarm`.**
  The real primitive: `git push swarm://…`. Public repos, single writer, incremental
  packs, feed-backed refs, batch rollover handled. Ship it as an open-source repo, a
  Swarm blog post and a SWIP-style format note so the on-Swarm layout is a standard
  rather than one tool's private format.

- **Phase 2 (4–6 weeks): make it a forge.**
  (a) Static web viewer on Swarm — repo browsing, commits, and issues rendered
  client-side with `isomorphic-git` reading the packs. This is the same
  SPA-on-Swarm pattern already proven in `adapt-to-swarm`.
  (b) Adopt Radicle COBs or git-bug for issues/patches instead of inventing anything.
  (c) ACT-encrypted private repos.

- **Phase 3: Radicle archival backend and Forgejo integration.**
  No longer opportunistic. The Radicle side came to us in
  [#31](https://github.com/crtahlin/git-swarm/issues/31) once Phase 1 shipped, which is
  what the sequencing above was for. The client, the index and the embeddable node
  already exist; we supply the archive path, the restore path and the format
  guarantees (§4 Option C). In parallel, the Forgejo post-receive mirror gives a
  self-hosting story for Datafund's own repos.

The thread through all four phases: **Swarm supplies durable, incentivised,
censorship-resistant storage and authenticated mutable pointers. Everything else is
borrowed from projects that already do it well.**

---

## 6. Hard problems — be honest about these

### 6.1 Swarm is rented storage, not permanent storage
This is the biggest product risk and it must not be papered over. Postage batches have
a TTL that depends on the price oracle; when a batch expires, the data is gone. The
docs are explicit that the TTL calculation assumes a static future price and that
batches need monitoring. Arweave's pay-once-store-forever model is an easier story to
tell here, and any marketing that says "your code can never be taken down" is false
unless the rent is paid.

Mitigations that must be part of the design, not bolted on:
- Automated TTL monitoring plus `stamps/topup` before expiry (a watchdog service).
- **Batch rollover strategy.** Immutable batches become unusable at capacity; mutable
  batches overwrite old chunks at capacity — which for an append-only repo archive is
  data loss. Plan: one immutable batch per epoch, with the manifest recording which
  batch stamped which pack, and a new batch when the current one nears capacity.
- Erasure coding for anything that matters.
- Costed against a real network rather than argued about: archiving all 15,737
  Radicle repositories is 277–1,387 BZZ/year at 1–5 MB average, one postage batch.
  See [`archival-policy.md`](archival-policy.md), which also finds that the
  `seeders < N` filter proposed in #31 selects on a number that probably measures
  announcements rather than independent custodians.
- Note the documented caveat that unencrypted content stamped with an *expired* batch
  cannot simply be re-uploaded — this needs to be verified experimentally before it is
  designed around, because it determines whether "revive an expired repo" is possible.

### 6.2 Clone latency
A 100 MB packfile is roughly 25,000 chunks. Retrieval performance, not storage cost,
will decide whether this feels usable. Pack-based layout (a handful of large objects)
is mandatory; a naive "one Git object per chunk" mapping would be elegant and unusably
slow. Measure early — the existing `swarm_perf_test` project is the right harness.

### 6.3 Multiple writers
A feed has one owner key. Real projects have several maintainers. Do not invent a
consensus scheme: adopt the per-contributor-namespace model (each writer publishes
their own feed; an identity document lists delegates; canonical refs require a delegate
signature). This is exactly Radicle's design, which is another argument for §4 Option C.

### 6.4 Permanence cuts both ways
Unremovable public storage means leaked secrets, personal data (GDPR erasure requests),
and abusive content cannot be taken down. A censorship-resistant forge will eventually
host something someone has a legitimate legal claim against. Decide the policy posture
before launch, not during the first incident. At minimum: encrypt-by-default for
anything non-public, and a documented, honest statement that public uploads are final.

### 6.5 No compute
No CI, no server-side merge, no webhooks. Phase 1–2 deliberately do not attempt this.
The realistic answer is that CI stays on a machine you control (self-hosted runners),
triggered by a GSOC/PSS push notification.

---

## 7. Immediate next steps

1. Spike Phase 0 on one real repo, end to end, and confirm the plain-`git` clone from a
   gateway URL actually works. One afternoon; it either works or it kills a whole branch
   of the design early.
2. Benchmark: clone a 50 MB and a 500 MB repo from Swarm versus from GitHub. Publish the
   numbers — honest performance data is more persuasive than the architecture diagram.
3. Verify the expired-batch re-upload semantics experimentally (§6.1).
4. Write up the on-Swarm repo format as a short spec before writing the helper, so the
   format outlives the first implementation.
5. Decide the framing: DevRel showcase, Swarm grant, or a Datafund product line. The
   engineering is the same for all three; the packaging is not.

---

## 8. References

- [Git remote helpers overview](https://nesbitt.io/2026/03/18/git-remote-helpers.html)
- [git-remote-ipfs (cryptix)](https://github.com/cryptix/git-remote-ipfs) — prior art, largely dormant
- [git-remote-gitopia](https://github.com/gitopia/git-remote-gitopia-mvp) — Cosmos/Arweave-backed equivalent
- [Radicle Heartwood protocol overview](https://hackmd.io/@radicle/rJ2UH54P6)
- [Radicle Collaborative Objects](https://deepwiki.com/radicle-dev/heartwood/6.1-collaborative-objects-(cobs))
- [canopy](https://github.com/solardev-xyz/canopy) — Radicle forge served from Swarm
- [radicle-index-service](https://github.com/solardev-xyz/radicle-index-service) — signed Radicle index on a Swarm feed
- [libradicle](https://github.com/solardev-xyz/libradicle) — embeddable Radicle node (Rust + napi)
- [Freedom Browser](https://github.com/solardev-xyz/freedom-browser) — browser embedding both a Bee node and a Radicle node
- [Radicle FAQ — seed nodes and availability](https://radicle.dev/faq)
- [Forgejo storage settings](https://forgejo.org/docs/latest/admin/setup/storage/) and
  [minio-for-all-repos request](https://codeberg.org/forgejo/forgejo/issues/2664) — repos cannot live in object storage today
- [Git transfer protocols (dumb HTTP)](https://git-scm.com/book/en/v2/Git-Internals-Transfer-Protocols)
- Local: `5-swarm/2-projects/bee-docs/docs/develop/tools-and-features/{feeds,buy-a-stamp-batch}.md`
