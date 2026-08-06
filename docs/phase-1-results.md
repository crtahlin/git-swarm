# Phase 1 results — git push and git clone against Swarm

Date: 2026-08-06
Issues: [#2](https://github.com/crtahlin/swarm-git-POC/issues/2) (epic), #11, #12, #13, #14

## Verdict

**Both acceptance criteria are met.**

```sh
git clone swarm://<owner>/<repo> myrepo     # read
cd myrepo && git commit -m "…"
git push                                    # write
```

works against a local Bee node, and a **read-only clone succeeds through a public
gateway** with no Bee node, no postage batch and no key.

Swarm is now an ordinary git remote. No server, no forge, no account, and no patch to
Git — `git-remote-swarm` is an executable on `PATH`, which is the extension point
`gitremote-helpers(7)` documents and the same mechanism Git's own HTTPS transport uses.

## What was built

| File | Role |
|---|---|
| `bin/git-remote-swarm` | The helper Git spawns for `swarm://` URLs |
| `src/protocol.js` | `capabilities` / `list` / `fetch` / `push` over stdin/stdout |
| `src/swarm.js` | Feeds, uploads, downloads, node and batch preflight |
| `src/manifest.js` | Build, validate and advance the `swarm-git/1` manifest |
| `src/gitplumbing.js` | Shell-outs to `rev-list`, `pack-objects`, `index-pack` |
| `docs/spec-swarm-git-format-v1.md` | The on-Swarm format, written before the code |
| `tests/e2e-push-clone.sh` | The acceptance test |

No packfile logic of our own: Git already has all of it, and shelling out to plumbing
keeps the format compatible by construction.

## Test result

`tests/e2e-push-clone.sh`, end to end against the live network:

```
==> push 1        uploading 238 bytes of new objects
==> clone 1       HEAD matches
==> push 2        uploading 283 bytes of new objects   (incremental)
==> clone 2       HEAD matches, full history present
==> rejects a push with no batch configured        rejected
==> rejects a non-fast-forward without force       rejected
==> accepts the same push when forced              accepted, feed moved

PASS
```

Gateway-only read, separately verified — no local node, no batch, no key:

```
git clone swarm://bzz/fadc093f9c82e7dcfaefb23e3151c07b2a09dd74f9978f8c7b0a1e19ae7dd586
  downloading pack 1/3 … 2/3 … 3/3
  HEAD 9fdb009 "rewritten second commit"
```

Incrementality is visible in those numbers: the second push uploaded 283 bytes — the new
commit, tree and blob — not the repository. Phase 0 republished the whole tree every time.

## Three defects found, and what they cost

### 1. A Bee node with no peers hangs the push instead of failing it

Mid-session the node dropped to **0 connected peers**. The failure signature is nasty: a
deferred file upload still returns in 30 ms because it is only stored locally, while the
feed write hangs indefinitely, because a feed update has to reach the network.
`swarm-cli feed upload` hung at exactly the same point, so this is not client-specific.

The helper now preflights `/topology` and refuses immediately:

```
 ! [remote rejected] main -> main (Bee node at http://localhost:1633 has 0 connected peers)
```

A five-minute silent hang became a one-second actionable error.

### 2. Automatic feed indexing silently drops updates

bee-js works out the next feed index by looking up the current head. Immediately after a
previous update that lookup can still return the old index, so the new update is written
to an index that already exists — and is silently ignored. The feed simply stops moving
while every call reports success.

Fixed by passing the index explicitly. The push already reads the feed to compute the
delta, so it knows exactly which index comes next; the lookup was never needed.

### 3. Gateways send a `Content-Disposition` header bee-js rejects

When a gateway resolves a feed manifest it answers `Content-Disposition: attachment` with
no filename, and bee-js's `downloadFile` treats that as malformed — which broke the
gateway read path entirely. Downloads need no header parsing, so they now use plain
`fetch`. This works identically against a local node and a gateway.

## One property that is not a defect

**A feed read can lag a write on the same node.** A clone immediately after a push may
resolve the previous feed update; a probe seconds later shows the new index correctly.
The write is durable and correct — the lookup catches up.

The acceptance test tolerates this by retrying the clone until the expected commit
appears, rather than pretending reads are instantaneous. Anything that pushes and
immediately reads back should expect the same.

## Not covered

- **Performance at size.** The 22 MB `bee-js` comparison against the Phase 0 baseline of
  41 seconds is not run: the development batch is at 62.5% utilisation, and a 22 MB push
  would exhaust it. Pending on [#8](https://github.com/crtahlin/swarm-git-POC/issues/8),
  and it needs a diluted or larger batch first.
- **Fetch optimisation.** A clone downloads every pack listed in the manifest. The
  `tips`/`base` fields exist so packs whose objects are already present can be skipped;
  that is deliberately deferred until the round trip was proven.
- Single writer, public repositories, raw hex addresses. Private repos, multi-writer and
  ENS naming remain Phase 2 and later.

## Reproducing

```sh
npm install && npm link
git remote add origin swarm://<owner>/<repo>
git config remote.origin.swarmBatch <batch-id>
git config remote.origin.swarmKey   <hex-private-key>
git push origin main

SWARM_OWNER=<owner> SWARM_BATCH_ID=<batch> SWARM_PRIVATE_KEY=<key> ./tests/e2e-push-clone.sh
```
