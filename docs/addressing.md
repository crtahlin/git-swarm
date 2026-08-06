# Addressing and gateways

How to name a repository, how to read one over HTTPS, and where ENS fits.

The normative rules live in [`spec-swarm-git-format-v1.md`](spec-swarm-git-format-v1.md)
§2 and §4. This document is the practical version: what to type, and why.

## The forms

| Form | What it names | Read | Write | Opens in a browser |
|---|---|---|---|---|
| `bzz://<reference>` | a content reference | yes | no | **yes** |
| `bzz://<name>.eth` | the same, by ENS name | yes | no | **yes** |
| `bzz::<owner>/<repo>` | a repository endpoint | yes | **yes** | no |
| `bzz::<owner>/<repo>?topic=<hex>` | the same, with an explicit topic | yes | yes | no |
| `swarm://…` | the pre-convention forms, still accepted | yes | yes | no |

### Why two grammars

`bzz://<reference>` means here exactly what it means in Freedom Browser or an ENS
contenthash record: *fetch this content-addressed thing*. The identical string works in
both places, which is the point.

A repository is not a content reference. Its address is a **(feed owner, topic)** pair, it
is read-write, and no browser can render it. Giving it the same `bzz://` prefix would
produce *partial* portability — some Swarm URLs openable in a browser, some not, with no
way to tell by looking. So the repository form uses `<transport>::<address>`, which
`gitremote-helpers(7)` documents as the explicit way to hand a foreign address grammar to
a helper, and which `hg::` and `gcrypt::` already use. The `::` is the tell.

The helper installs as **`git-remote-bzz`**, with `git-remote-swarm` as an alias.

## Writing

Pushing always needs a **local Bee node**: it requires a postage batch and a signing key,
and no public gateway offers either.

```sh
git remote add origin bzz::<owner-address>/<repo-name>
git config remote.origin.swarmBatch <batch-id>
git config remote.origin.swarmKey   <hex-private-key>
git push origin main
```

## Reading over HTTPS

Cloning needs no node, no batch and no key — only a gateway and a reference:

```sh
SWARM_GATEWAY=https://bzz.limo git clone bzz://<feed-manifest-ref> myrepo
SWARM_GATEWAY=https://bzz.limo git clone bzz://<name>.eth myrepo
```

Or per remote, so it survives:

```sh
git config remote.origin.swarmGateway https://bzz.limo
```

Resolution order:

```
remote.<name>.swarmGateway  →  SWARM_GATEWAY  →  SWARM_API  →  BEE_API  →  http://localhost:1633
```

### Which gateway

Use **`bzz.limo`**. It serves content inline with the correct `Content-Type` and CORS `*`,
and resolves ENS names and feed manifests server-side.

Avoid `download.gateway.ethswarm.org` as a default. It returns identical bytes, but sends
`Content-Disposition: attachment` — the name is literal. That is harmless for `git clone`,
and fatal for the web viewer, because a browser saves the page instead of rendering it.
One gateway that works for both beats two rules to remember.

### What a gateway can and cannot do

| | `/feeds/{owner}/{topic}` | `/bytes`, `/chunks` | `/bzz/<ref>/…` | upload |
|---|---|---|---|---|
| Local Bee node | yes | yes | yes | yes |
| Public gateway | **no** (404) | yes | yes | no |

Because `/feeds` is not exposed publicly, a gateway-only reader resolves through the
**feed manifest** instead — a bzz address wrapping (owner, topic) that the gateway
resolves itself. Every push publishes one, and its address is stable across pushes.

## ENS

Set the name's contenthash to `bzz://<hash>` in the [ENS app](https://app.ens.domains/).
No encoding, no tooling.

| Name | contenthash | Why |
|---|---|---|
| `git.ontheswarm.eth` | the viewer's hash | the app |
| `git-repo.ontheswarm.eth` | the **feed manifest** | the repository |

Point the repository name at the *feed manifest*, not at a manifest or pack hash. The feed
manifest address never changes while always serving the newest push, so the ENS record is
set once and every later push is visible at that name with no further transaction. The Bee
docs recommend the same pattern for websites.

The viewer is published the same way, by `scripts/publish-viewer.sh`, which uploads the
build to a feed rather than as a plain upload. A plain upload mints a new reference on
every build, which invalidates every link you have handed out and would need an ENS
transaction each time. Behind a feed the address is fixed for the life of the topic.

Live addresses for this project, both stable:

| | |
|---|---|
| Viewer feed manifest | `09a5c8924336625cad2dc0be13c0dd74f8b5d1d33fb9ba5b057340893188a19c` |
| Repository feed manifest | `2659451ac307f86a6e9f2286ffbfc7f33776d0f154ce899eab4ea535ab35a237` |

### Reading by name works today

```sh
git clone bzz://git-repo.ontheswarm.eth
```

Verified against `swarm.eth`. It costs nothing because the gateway resolves the
contenthash — the helper passes the name straight through and needs no Ethereum RPC.

In the browser:

```
https://bzz.limo/bzz/git.ontheswarm.eth/#ens/git-repo.ontheswarm.eth
https://git.ontheswarm.eth.limo/#ens/git-repo.ontheswarm.eth
http://localhost:1633/bzz/git.ontheswarm.eth/#ens/git-repo.ontheswarm.eth
```

Note that `eth.limo` and `bzz.link` are **subdomain** gateways: they serve exactly one ENS
name and have no `/bzz/<ref>` path, so a viewer served from one cannot fetch a repository
from its own origin. The viewer detects this and falls back to a path-style gateway.

### Writing by name is not implemented

An ENS contenthash names *content*; a push needs the feed's **owner address**, which a
contenthash cannot supply. The route is the ordinary `addr` record, and the cost is an
Ethereum RPC inside the helper — see [#25](https://github.com/crtahlin/git-swarm/issues/25).

Nothing is blocked by its absence: anyone who can push already holds the key, and
therefore already knows the owner address.

## Resolution, end to end

```
bzz://name.eth                    bzz://<reference>              bzz::<owner>/<repo>
      │                                  │                              │
      ▼ gateway resolves ENS             │                              ▼ topic = keccak256(
  contenthash                            │                              │   "swarm-git:v1:"+repo)
      │                                  │                              ▼
      └──────────► feed manifest ◄───────┘                    feed (owner, topic)
                         │                                             │
                         ▼ gateway resolves the feed                   ▼ /feeds, local node only
                    manifest JSON  ◄───────────────────────────────────┘
                         │
                         ▼
                   packfiles → git index-pack
```
