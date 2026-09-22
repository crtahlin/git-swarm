# Which Radicle repositories to archive, and what it costs

Finding for [#37](https://github.com/crtahlin/git-swarm/issues/37). Date: 2026-09-22.

Measured against the live `radicle-index/v1` index published by
`freedom-radicle-index` (feed `e1c89773…`, read through a public gateway) and the mainnet
postage price from a Bee node the same day.

## Summary

**Archive everything. A selection policy costs more to build and operate than the storage
it saves.**

The whole Radicle network is 15,737 repositories. At a plausible average size that is
**277 to 1,387 BZZ per year** — one postage batch. The `seeders < N` filter proposed in
[#31](https://github.com/crtahlin/git-swarm/issues/31) would save at most a few hundred
BZZ a year, and it selects on a number that does not measure what we want it to.

Use the seeder count to decide *order*, not *membership*.

## The network, as of 2026-09-22

```
knownRepos    15,815
indexedRepos  15,737
users          4,780
```

All 15,737 records carry a name, a head commit and a delegate set, so these are real
repositories rather than gossip noise.

**Median delegate count is 1.** Most repositories have a single maintainer, so when that
person stops seeding, availability rests entirely on public seeds.

## Seeder counts do not identify repositories at risk

| seeders | repos | share | cumulative |
|---|---|---|---|
| 1 | 30 | 0.2% | 0.2% |
| 2 | 171 | 1.1% | 1.3% |
| 3 | 427 | 2.7% | 4.0% |
| 5 | 1,351 | 8.6% | 17.9% |
| 8 | 2,206 | 14.0% | 57.0% |
| 10 | 1,560 | 9.9% | 79.4% |
| 13 | 538 | 3.4% | 95.4% |

Median 8, maximum 175, and the distribution is a tight hump between 5 and 12. Almost
nothing sits at 1.

That shape is the finding. A count clustered that tightly across 15,737 repositories of
wildly differing popularity is not measuring per-repository interest — it looks like a
handful of always-on public seeds picking up nearly everything, plus the delegate. If
that is what it is, then **seeder count measures announcements, not independent
custodians**, and eight seeders can be one operator's decision away from zero.

The index publishes a count and not a list, so this cannot be confirmed from the data
available. It is the single most important thing to check before anyone builds a filter on
it: **resolve seeders to operators, and see how many distinct ones there are.**

A filter would also barely fire. `seeders < 2` selects 30 repositories; `seeders < 5`
selects 1,470. Tuning N between those is a choice between archiving 0.2% and 9.3% of the
network on a signal we do not trust.

### One correlation, with a caveat

Repositories with ≤3 seeders are idler than those with ≥9 — median 130 days versus 35, and
36% versus 13% untouched for over a year. So the signal is not pure noise.

But that only covers the 2,218 repositories that have any issue or patch activity.
`lastActivity` tracks collaborative objects, not commits: the other 13,519 repositories
have names, heads and delegates but zero issues and patches, so they report no activity
while being perfectly real. Do not read "no lastActivity" as abandoned.

## Cost

Mainnet, read 2026-09-22: `currentPrice` 109,152 PLUR per chunk per block, 5-second
blocks, 4 KB chunks, 1 BZZ = 10¹⁶ PLUR.

**1 GB for one year = 18.05 BZZ.**

Batches are bought at a depth, so capacity arrives in powers of two and the whole batch is
paid for whether or not it is filled:

| depth | capacity | BZZ/year |
|---|---|---|
| 22 | 16 GB | 289 |
| 23 | 32 GB | 578 |
| 24 | 64 GB | 1,155 |

Whole network, by average repository size:

| average size | total | BZZ/year |
|---|---|---|
| 0.5 MB | 7.7 GB | 139 |
| 1 MB | 15.4 GB | 277 |
| 5 MB | 76.8 GB | 1,387 |
| 10 MB | 153.7 GB | 2,774 |
| 50 MB | 768 GB | 13,868 |

Against that, the filter saves almost nothing: `seeders < 5` at a 5 MB average is 7.2 GB,
**130 BZZ/year**, versus 1,387 for everything. The difference is roughly one depth-22
batch, and it buys a component that has to be written, tuned, monitored and explained.

**Average repository size is the one input not measured here**, and it moves the answer by
two orders of magnitude. It is also cheap to obtain: the index service already has each
repository on disk while extracting it. Asking it to publish a size per record would
settle this and is a smaller change than the `swarm` field already proposed in
[#38](https://github.com/crtahlin/git-swarm/issues/38).

## Recommendation

1. **Archive every repository the index knows about.** Simpler to operate, nothing to
   tune, and no risk of a filter excluding the repository that later mattered.
2. **Use the seeder count for ordering.** Fewest seeders first, so that if the budget or
   the crawl window runs out, the most exposed repositories are already stored.
3. **Publish a size per record** so this can be re-costed against real data rather than a
   range.
4. **Re-archive on ref movement, not on a timer.** The index already re-extracts only when
   gossip announces newer refs; archiving on the same trigger avoids paying to re-store
   unchanged packs. Packs are append-only and content-addressed, so an unchanged
   repository costs nothing to re-archive beyond the manifest.
5. **Before building any of it, resolve seeders to operators.** If eight seeders is three
   operators, the network is far more fragile than the distribution suggests, and that
   strengthens the case for archiving everything rather than weakening it.

## Who pays, and what happens when they stop

A lapsed batch is worse than no archive, because the index keeps pointing at it. Whoever
runs the archiver owns a renewal obligation, not a one-off cost.

- One immutable batch per epoch, per spec §6.3, with TTL monitoring and top-up before
  expiry. Dilution halves the TTL, so enlarging a batch means topping up as well.
- The index record should carry enough for a client to tell a live archive from a dead
  one — at minimum the time it was written, so a stale entry can be recognised rather than
  fetched and failed.
- At 277–1,387 BZZ/year this is an infrastructure line item rather than a funding round,
  which is the strongest argument for not over-engineering the policy around it.
