// Publish a dumb-HTTP mirror of this repository to a Swarm feed.
//
//   node scripts/publish-mirror.mjs
//
// This is the clone path that needs no helper at all:
//
//   git clone https://<gateway>/bzz/<mirror-feed>/ git-swarm
//
// Stock git, nothing installed, one URL. It matters more than it looks: the
// helper ships *inside* this repository, so without a mirror the only way to get
// a first copy is a centralised forge — the dependency the project exists to
// remove.
//
// Behind a feed, so the URL is stable across republications.

import { execFileSync } from 'node:child_process'
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

import { Bee, EthAddress, FeedIndex, PrivateKey, Topic } from '@ethersphere/bee-js'

const HERE = join(dirname(fileURLToPath(import.meta.url)), '..')
const KEYFILE = process.env.SWARM_KEYFILE || join(HERE, '..', 'secrets', 'feed-owner.key')
const BEE_API = process.env.BEE_API || 'http://localhost:1633'
const TOPIC_STRING = 'git-swarm:mirror:v1'

const env = Object.fromEntries(
  readFileSync(KEYFILE, 'utf8').split('\n').filter((l) => l.includes('='))
    .map((l) => [l.slice(0, l.indexOf('=')).trim(), l.slice(l.indexOf('=') + 1).trim()]),
)
const key = new PrivateKey(env.feed_owner_privkey)
const owner = new EthAddress(env.feed_owner_address)
const topic = Topic.fromString(TOPIC_STRING)

const bee = new Bee(BEE_API)
const batch = (await bee.getPostageBatches()).find((b) => b.usable)
if (!batch) throw new Error(`no usable postage batch on ${BEE_API} — is this the node that owns it?`)

console.log(`topic      ${topic.toHex()}  ("${TOPIC_STRING}")`)
console.log(`batch      ${batch.batchID.toHex().slice(0, 16)}… ${Math.round(Number(batch.duration?.toSeconds?.() ?? 0) / 86400)} days`)

// ---------------------------------------------------------------- stage
// A bare mirror, repacked, with the files Git's dumb-HTTP transport needs.
// Packing matters: dumb HTTP fetches whole files, so thousands of loose objects
// would be thousands of round trips.
const stage = mkdtempSync(join(tmpdir(), 'git-swarm-mirror-'))
const bare = join(stage, 'repo.git')
console.log('\nstaging…')
execFileSync('git', ['clone', '--quiet', '--mirror', HERE, bare])
execFileSync('git', ['--git-dir', bare, 'repack', '-a', '-d', '-q'])
execFileSync('git', ['--git-dir', bare, 'update-server-info'])
rmSync(join(bare, 'hooks'), { recursive: true, force: true })

for (const f of ['info/refs', 'objects/info/packs', 'HEAD']) {
  try { readFileSync(join(bare, f)) } catch { throw new Error(`missing ${f} — dumb HTTP will not work`) }
}

console.log('uploading…')
const upload = await bee.uploadFilesFromDirectory(batch.batchID, bare)
console.log(`content    ${upload.reference.toHex()}`)

// Explicit index, then read back: a feed write can succeed and publish nothing.
let next = FeedIndex.fromBigInt(0n)
try {
  const state = await bee.makeFeedReader(topic, owner).downloadReference()
  if (state.feedIndexNext) next = state.feedIndexNext
} catch { /* first publication */ }

await bee.makeFeedWriter(topic, key).uploadReference(batch.batchID, upload.reference, { index: next })
const after = await bee.makeFeedReader(topic, owner).downloadReference()
if (after.reference.toHex() !== upload.reference.toHex()) {
  throw new Error('feed did not advance — nothing was published')
}
const feed = (await bee.createFeedManifest(batch.batchID, topic, owner)).toHex()

rmSync(stage, { recursive: true, force: true })

console.log(`
────────────────────────────────────────────────────────────
mirror feed  ${feed}

Clone with stock git, nothing installed:

  git clone https://bzz.limo/bzz/${feed}/ git-swarm
────────────────────────────────────────────────────────────`)
