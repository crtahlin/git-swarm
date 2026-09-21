# Design note — branch leases without a second chain

Status: draft · Date: 2026-09-16 · Relates to: [#16](https://github.com/crtahlin/git-swarm/issues/16) (multiple writers)

Lifting one idea from **gitkiv** (ETHRome 2026), which put Git metadata in Arkiv and
file bytes on Swarm. Its nicest detail is the branch lock: a lock is an entity with a
block-based expiry, **nothing in the application ever deletes a lock** — it simply stops
being returned by the query once its expiry block passes. No release call, no cleanup
job, no stuck branch when a client crashes.

We want that property. We do not want Arkiv, or any other product, underneath our
repository format.

## 1. What their lock actually buys, and what we already have

Separate two things that the word "lock" runs together:

| | Mechanism | Do we have it? |
|---|---|---|
| **Safety** — two writers must not silently clobber each other | Compare-and-swap on publish | **Yes.** `manifest.parent` records the manifest a push was based on; if the feed has moved, the push is rejected (spec §6.2). |
| **Coordination** — don't let two people do expensive work when only one push can win | Advisory lock, announced ahead of time | No. |

So we are not missing a safety mechanism. We are missing a courtesy: a way to say "I am
about to push to `main`" so the other person does not spend twenty minutes on a rebase
that will be refused.

That reframing matters, because an advisory lease has far weaker requirements than a
real distributed lock — and the weaker requirements are the ones Swarm can meet.

**A real mutual-exclusion lock is not buildable on Swarm and we should stop wanting one.**
It needs consensus to order two simultaneous claims, and Swarm has no consensus. gitkiv
did not build one either; it borrowed Arkiv's. What is buildable is a lease that is
honoured by cooperating writers and that never affects correctness when ignored.

## 2. The hard part is the clock, and we already pay for one

gitkiv needed Arkiv for two things: somewhere multiple parties can write, and a clock to
expire against. Swarm feeds solve the first. The clock looks like the blocker, because
a Swarm feed has **sequence numbers, not timestamps** — an ordinal, not a time.

But every Bee node already tracks **Gnosis**. It has to: postage batches are bought,
topped up and diluted on-chain, and a node cannot price or validate a stamp without
following that chain. Batch TTL is denominated in it.

So Gnosis block height is a clock that is:

- already available wherever a writer exists, since writing already requires a Bee node
  and a batch (spec §4.2)
- **not a new trust assumption** — Swarm does not function without it
- monotonic, adversary-resistant, and agreed on by every participant

This is the whole trick. gitkiv reached for a second chain because it had no clock.
We do not need a second chain, because Swarm already stands on one.

## 3. Proposal

A **lease** — advisory, self-expiring, never authoritative.

### 3.1 Where it lives

One lease feed per writer, not one per repository, so that no two writers ever need to
write to the same feed and the ordering problem never arises:

```
topic = keccak256( utf8( "swarm-git:v1:lease:" + <repo> ) )
```

addressed at `(writer address, topic)`. Every member of the delegate set has one at the
same topic under their own address.

### 3.2 What it says

```json
{
  "format": "swarm-git-lease/1",
  "repo": "git-swarm",
  "refs": ["refs/heads/main"],
  "since": 41234567,
  "until": 41234807,
  "parent": "b91d42e69f9d…",
  "note": "rebasing onto v2 packfile layout"
}
```

| Field | Meaning |
|---|---|
| `refs` | Which refs the holder intends to move. Never the whole repository. |
| `since` / `until` | **Gnosis block numbers.** Expiry is `until`; no release call exists. |
| `parent` | The manifest the holder is working from. Lets a reader tell a stale lease from a live one even before `until`. |
| `note` | Free text for humans. Advisory only. |

The feed update is a single-owner chunk signed by the writer's key, so a lease is
attributable by construction — same property that makes refs authentic (spec §3.3).

### 3.3 Rules

1. A writer MUST NOT publish a lease with `until - since` greater than **1200 blocks**
   (about 100 minutes at Gnosis's 5-second blocks). A reader MUST ignore a lease that
   exceeds it. This bounds the damage from a wrong clock, a careless `--duration`, or a
   malicious delegate, without needing anyone to be honest.
2. Before a push that will take real work, a writer SHOULD read the lease feed of every
   address in the delegate set, and warn if any unexpired lease names a ref it intends to
   move.
3. A lease MUST NOT block a push. The `parent` check is the only thing that decides
   whether a push succeeds. A writer who ignores a lease gets the same correctness
   guarantee as one who honours it — they just annoy a colleague.
4. Nothing ever deletes a lease. It stops being honoured when `until` is below the
   current block. This is the gitkiv property, preserved exactly.
5. A writer SHOULD publish a lease with `until` set to the current block after a
   successful push — an early release, but as a hint, not a requirement.

### 3.4 What it costs

One feed lookup per delegate before a push. For a handful of maintainers that is
milliseconds. It does not scale to hundreds of writers, and it should not try to: a
repository with hundreds of direct pushers has a social problem, not a locking problem.

Storage cost is one chunk per lease, on the repository's existing batch.

## 4. Things considered and rejected

**Expiry by postage-stamp TTL.** Tempting and wrong. Stamp the lease chunk with a
short-TTL batch and let the lease vanish when the rent runs out — no clock needed. It
fails on the same fact that undermines the GDPR-erasure story: batch expiry ends the
*rent*, not the *bytes*. Our own shred measurement on Gnosis mainnet showed that a chunk
retrieved even once stayed retrievable for 15+ hours afterwards, because retrieval seeds
caches that expiry cannot reach. A lease that lingers unpredictably past its expiry is
worse than no lease, because it produces exactly the stuck branch the design was meant to
avoid.

**A shared lease feed.** One feed, all writers. Requires a shared key (everyone can forge
everyone) or feed writes that Swarm cannot order. Per-writer feeds cost N lookups and
avoid both.

**Wall-clock timestamps.** Removes the Gnosis dependency but trusts the claimant's clock.
Since a Gnosis connection is already mandatory for anyone who can push, this buys nothing
and costs the only property that makes the bound enforceable.

**A lock contract on Base or Gnosis.** Would give real mutual exclusion. Adds a
transaction, a fee and a wallet to every push, for a courtesy. Rejected on cost, not on
principle — if leases prove insufficient for something that matters, this is the escalation.

**Doing nothing.** The honest default, and the right one until multi-writer exists.
Nothing in this note is needed while a repository has one writer key, which is all of v1.

## 5. Recommendation

Do not build this yet. Land it as a design attached to [#16](https://github.com/crtahlin/git-swarm/issues/16),
and build it only when multi-writer is real. When it is built, it goes in as
`swarm-git-lease/1` — a **separate format alongside** `swarm-git/1`, not a change to it,
so a reader that has never heard of leases still clones the repository correctly.

The thing worth remembering even if we never build it: **when a design seems to need a
second chain, check whether the one underneath Swarm already answers it.** Here it did.
