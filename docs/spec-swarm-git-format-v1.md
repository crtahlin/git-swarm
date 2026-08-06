# swarm-git format, version 1

Status: draft · Date: 2026-08-06 · Issue: [#11](https://github.com/crtahlin/swarm-git-POC/issues/11)

How a Git repository is represented on Ethereum Swarm, so that `git clone`, `git fetch`
and `git push` work against a `bzz` remote with no server involved.

This document is normative for the format. It is deliberately independent of any one
implementation: everything here can be built with the Bee HTTP API alone, and a second
client written in another language must be able to read what the first one writes. That
is the whole reason it exists.

Format identifier: `swarm-git/1`.

---

## 1. The idea in one paragraph

Git is already a content-addressed object store, so the objects need nothing but durable
storage. What Git lacks — and what a hosting provider normally supplies — is an
authenticated, mutable pointer saying "the current tip of `main` is this commit". Swarm
supplies both: immutable chunks for the objects, and **feeds** — single-owner chunks
signed by an Ethereum key — for the pointer. Everything below is the minimum needed to
join those two facts.

## 2. Addressing

### 2.1 URL forms

Two grammars, and the difference between them is deliberate.

```
bzz::<owner>/<repo>                 repository endpoint; read and write
bzz::<owner>/<repo>?topic=<hex>     explicit topic, bypassing derivation
bzz://<feed-manifest-ref>           content reference; read-only
bzz://<name.eth>                    content reference by ENS name; read-only
```

`bzz://<reference>` means, here, exactly what it means in a browser or an ENS
contenthash record: **fetch this content-addressed thing**. It is read-only and
singular, and the same string works in both places. Deliberately so.

A repository is not a content reference. It is a read-write endpoint whose address
is a (feed owner, topic) pair, and pasting `<owner>/<repo>` into a browser cannot
work. Reusing `bzz://` for it would produce *partial* portability — some Swarm URLs
openable in a browser, some not, indistinguishable by eye. So the repository form
uses Git's `<transport>::<address>` grammar, which `gitremote-helpers(7)` documents
as the explicit way to hand a foreign address to a helper, and which other
transports already use (`hg::`, `gcrypt::`). The `::` is the signal: git address,
not a URL.

Implementations MUST also accept `swarm://<owner>/<repo>` and
`swarm://bzz/<ref>`, the forms used before this convention was settled.

The helper is installed as **`git-remote-bzz`**, with `git-remote-swarm` as an
alias.

- `<owner>` — the feed owner's Ethereum address, 40 hex characters, with or without `0x`.
- `<repo>` — the repository name. Used only to derive the topic; it is not stored as a
  lookup key anywhere.
- `<feed-manifest-ref>` — a 64-hex bzz reference to a feed manifest (§4.3), or an
  ENS name whose contenthash is one.

A Swarm feed is addressed by the pair **(owner address, 32-byte topic)** — not by a
content hash. That is why `bzz::<owner>/<repo>` needs no registry, no index and no
name service: the address *is* the address.

### 2.2 Topic derivation

```
topic = keccak256( utf8( "swarm-git:v1:" + <repo> ) )
```

32 bytes, lower-case hex when written out. In bee-js this is
`Topic.fromString("swarm-git:v1:" + repo)`.

The `swarm-git:v1:` prefix namespaces the topic so a repository does not collide with
some other application's feed of the same name, and so a future format version can move
without disturbing v1 readers.

Two people may use the same repository name without collision, because the owner address
differs.

Implementations MUST support the `?topic=<hex>` override. It exists so a feed created by
other tooling — for example `swarm-cli --topic-string`, whose derivation differs — can
still be served.

## 3. Objects stored on Swarm

Three kinds, all written with the repository's postage batch.

### 3.1 Packfiles

Standard Git packfiles, exactly as `git pack-objects` emits them. Each is uploaded as a
**single bzz file** and retrieved at `/bzz/<ref>`, which is what keeps them readable
through public gateways.

Packs are the unit of transfer on purpose. A repository stored as individual loose
objects would be one Swarm retrieval per object; Phase 0 measured a 22 MB repository as a
handful of files cloning in 41 seconds, and a per-object layout would be far worse.

Packs are append-only. A push adds a pack; it never rewrites one.

### 3.2 Manifest

A JSON document, uploaded as a single bzz file with content type `application/json`.

```json
{
  "format": "swarm-git/1",
  "repo": "swarm-git-poc",
  "head": "refs/heads/main",
  "refs": {
    "refs/heads/main": "2288fcf3577c7c4a0f485c3329f8e8405b74adfe",
    "refs/tags/v1":    "43800f7e2b4a298c597c6028deaf422d45f0ad25"
  },
  "packs": [
    {
      "ref":   "eb1f380f6a94c2ceb4a8d9e67f423f7a3d3a7eac…",
      "size":  1048576,
      "batch": "be02ac7973a269ec32386f46a3a96945f05571ad…",
      "tips":  ["2288fcf3577c7c4a0f485c3329f8e8405b74adfe"],
      "base":  ["43800f7e2b4a298c597c6028deaf422d45f0ad25"]
    }
  ],
  "parent": "b91d42e69f9d9c903bd22685d536e560629484c1…"
}
```

| Field | Meaning |
|---|---|
| `format` | MUST be `swarm-git/1`. A reader MUST refuse anything else. |
| `repo` | The repository name the topic was derived from. Informational; readers MUST NOT rely on it for addressing. |
| `head` | The ref `HEAD` points at. MUST be a key of `refs`. |
| `refs` | Full ref name → 40-hex object id. Includes branches and tags. |
| `packs` | **Cumulative** — every pack needed to reconstruct `refs`, oldest first. |
| `packs[].ref` | bzz reference of the packfile. |
| `packs[].size` | Byte length, so a client can budget before downloading. |
| `packs[].batch` | The postage batch that stamped it. Under one-batch-per-repo this is constant; it is recorded so a future multi-batch layout needs no format change. |
| `packs[].tips` | Object ids this pack makes reachable. |
| `packs[].base` | Object ids this pack assumes already exist. Empty for the first pack. |
| `parent` | bzz reference of the manifest this push was based on, or `null` for the first. |

`packs` is cumulative rather than incremental so that a clone costs one feed lookup, one
manifest read, and then the packs — no chain walking. `parent` preserves history and
makes concurrent writes detectable (§6.2); it is not needed to read the repository.

Manifest ordering: `packs` MUST be listed oldest first. Readers depend on it (§5.3).

### 3.3 Feed

A sequential feed at `(owner, topic)` whose payload is the bzz reference of the current
manifest.

The feed is what makes refs authentic: a feed update is a single-owner chunk signed by
the owner's key, so only the key holder can move a ref, and any reader can verify that
without trusting the node that served it.

## 4. Transport

### 4.1 What a public gateway can and cannot do

Measured 2026-08-06 against `download.gateway.ethswarm.org`:

| | `/feeds/{owner}/{topic}` | `/bytes`, `/chunks` | `/bzz/<ref>/…` | upload |
|---|---|---|---|---|
| Local Bee node | yes | yes | yes | yes |
| Public gateway | **404** | 200 | yes | no |

### 4.2 Writing always needs a local node

Pushing requires a postage batch and a signing key. No public gateway offers either.
This is not a gap to be worked around; it is the shape of the system. Anyone who wants
to publish runs a Bee node — a light node is sufficient, as Phase 0 showed.

### 4.3 Reading works either way

- **With a local node**: resolve `/feeds/{owner}/{topic}` → manifest reference → packs.
- **Gateway only**: `/feeds` is unavailable, so resolution goes through a **feed
  manifest** — a bzz reference that wraps (owner, topic) and which the gateway resolves
  server-side. This is the `bzz://<feed-manifest-ref>` URL form.

A writer MUST therefore publish both on every push: the feed update, and a feed manifest
reference. The feed manifest address is stable across pushes while serving the newest
state — verified in Phase 0.

## 5. Reading a repository

### 5.1 Resolve

1. Derive the topic (§2.2), or take the feed manifest reference from the URL.
2. Fetch the current manifest reference from the feed.
3. Download the manifest and validate `format`.

### 5.2 Advertise refs

Emit every entry of `refs`, plus a symbolic ref for `head`.

### 5.3 Download objects

Download the packs and index each into the local object store, **oldest first**. Order is
mandatory: a pack may be thin, meaning it omits base objects it expects to already exist,
and those bases come from earlier packs.

A client MAY skip a pack whose `tips` are all present locally. A client MUST NOT skip a
pack whose `base` objects are absent.

### 5.4 Verification

Two independent checks, and both are free:

- **Authenticity** — the feed update is signed by the owner key. A reader that resolved
  by `(owner, topic)` knows the refs came from the owner.
- **Integrity** — every Git object id is a hash of its content. A corrupted or
  substituted pack fails `git index-pack`.

A reader therefore does not have to trust the Bee node or gateway that served the bytes.

## 6. Writing a repository

### 6.1 Push

1. Read the current feed state; remember the manifest reference it points at.
2. For each ref being pushed, reject a non-fast-forward update unless force was
   requested.
3. Build one packfile containing the objects reachable from the new tips but not from any
   ref already in the manifest.
4. Upload the pack.
5. Build a new manifest: updated `refs`, `packs` extended with the new entry, `parent`
   set to the reference observed in step 1.
6. Upload the manifest, advance the feed, refresh the feed manifest.

Steps 4–6 are not atomic. A crash between them leaves orphaned but harmless data: an
uploaded pack no manifest references, or a manifest the feed does not yet point at. A
reader only ever sees state the feed points at.

### 6.2 Concurrent writers

A feed has exactly one writer key, so v1 assumes a single writer. It does not pretend
otherwise; it detects the problem instead. If the feed has moved past the manifest
recorded in step 1 by the time the writer is ready to publish, the push MUST be rejected
rather than overwriting. Multi-writer collaboration is a later version
([#16](https://github.com/crtahlin/swarm-git-POC/issues/16)).

### 6.3 Postage

One batch per repository, supplied by the operator — v1 never purchases one.

A writer MUST check the batch before uploading and refuse when it is missing, unusable or
expiring. Swarm storage is rented: when the batch lapses, the repository becomes
unreadable.

When the batch approaches capacity it is **enlarged in place**, not replaced:

```
PATCH /stamps/dilute/{batchID}/{newDepth}     doubles capacity per depth step
PATCH /stamps/topup/{batchID}/{amount}        restores the TTL dilution just halved
```

Dilution works on immutable batches — verified in the Bee source, which requires only
that the new depth exceed the current one. Because a batch grows in place, the constant
`packs[].batch` field is expected to stay constant for the life of a repository.

## 7. Deliberately not in v1

Private repositories (ACT encryption), multiple writers, ENS or any other naming layer,
issues and patches, pack compaction, and garbage collection of superseded packs. Each is
tracked as its own issue. None of them requires a change to what is written above; they
add fields or layers on top of it.

## 8. Reference values

From the live Phase 0 publication, useful for testing a reader:

| | |
|---|---|
| Owner | `0x7f651ac31490cea51c509ec17619c4900097685d` |
| Topic (swarm-cli derivation, not §2.2) | `d8c64654ce0646486a318b335d0deb69da999f348bb111384c564293c4fd966c` |
| Feed manifest | `b9250d4dd334ad8b140e754d08904328b5ff2e80f07a7c4dd0fc3a65bbc8601c` |
| Batch | `be02ac7973a269ec32386f46a3a96945f05571ad81f578c073744f96dcf526ab`, immutable, depth 19, expires ~2026-08-13 |

That feed predates this spec: it holds a Phase 0 dumb-HTTP tree rather than a
`swarm-git/1` manifest, and its topic uses swarm-cli's derivation. It is reachable with
the `?topic=` override and is useful for exercising feed resolution, not manifest
parsing.
