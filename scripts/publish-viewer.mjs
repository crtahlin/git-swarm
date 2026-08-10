// Build and publish the viewer to its Swarm feed.
//
//   node scripts/publish-viewer.mjs
//
// Signed by the shared ontheswarm feed owner, the same key behind
// excalidraw.ontheswarm.eth and the rest — so git.ontheswarm.eth is on the same
// footing as the other apps rather than a throwaway demo key.
//
// The feed address is derived from (owner, topic), so it never changes: rebuild
// and re-run as often as you like, and the ENS contenthash stays valid.

import { Bee, EthAddress, FeedIndex, PrivateKey, Topic } from '@ethersphere/bee-js'
import { execFileSync } from 'node:child_process'
import { readFileSync, writeFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

const HERE = join(dirname(fileURLToPath(import.meta.url)), '..')
// Where the feed signing key lives. Override with SWARM_KEYFILE; the default
// points outside this repository on purpose, so no secret is ever near a commit.
const KEYFILE = process.env.SWARM_KEYFILE || join(HERE, '..', 'secrets', 'feed-owner.key')

const BEE_API = process.env.BEE_API || 'http://localhost:1633'
const TOPIC_STRING = 'git-swarm:viewer:v1'
const LABEL = 'git'

const env = Object.fromEntries(
  readFileSync(KEYFILE, 'utf8')
    .split('\n').filter((l) => l.includes('='))
    .map((l) => [l.slice(0, l.indexOf('=')).trim(), l.slice(l.indexOf('=') + 1).trim()]),
)
const key = new PrivateKey(env.feed_owner_privkey)
const owner = new EthAddress(env.feed_owner_address)
const topic = Topic.fromString(TOPIC_STRING)

const bee = new Bee(BEE_API)
const batch = (await bee.getPostageBatches()).find((b) => b.usable)
if (!batch) throw new Error(
  `no usable postage batch on ${BEE_API}.\n` +
  '  A batch can only issue stamps from the node that bought it — check you are\n' +
  '  pointed at that node.',
)

// Which repository this build opens when no fragment is given.
const defaultTarget = process.env.VIEWER_DEFAULT_TARGET
if (!defaultTarget) throw new Error('set VIEWER_DEFAULT_TARGET, e.g. bzz/<repo-feed-manifest>')

console.log(`owner      ${owner.toHex()}`)
console.log(`topic      ${topic.toHex()}  ("${TOPIC_STRING}")`)
console.log(`batch      ${batch.batchID.toHex().slice(0, 16)}…`)
console.log(`default    ${defaultTarget}`)

console.log('\nbuilding…')
execFileSync('node', ['build.mjs'], {
  cwd: join(HERE, 'viewer'),
  env: { ...process.env, VIEWER_DEFAULT_TARGET: defaultTarget },
  stdio: 'inherit',
})

console.log('uploading…')
const upload = await bee.uploadFilesFromDirectory(batch.batchID, join(HERE, 'viewer', 'dist'), {
  indexDocument: 'index.html',
})
console.log(`content    ${upload.reference.toHex()}`)

// Explicit index: bee-js can otherwise reuse one right after a previous update,
// and the write is then silently dropped.
let next = FeedIndex.fromBigInt(0n)
try {
  const state = await bee.makeFeedReader(topic, owner).downloadReference()
  if (state.feedIndexNext) next = state.feedIndexNext
} catch { /* first publication */ }

await bee.makeFeedWriter(topic, key).uploadReference(batch.batchID, upload.reference, { index: next })

// Read back: a feed write can succeed and publish nothing, if the index already
// exists. The network keeps the chunk it has; only this node sees the change.
// The node's own lookup can lag its own write, so retry before concluding
// anything: a lagging lookup catches up, a dropped update stays wrong.
let after = null
for (let attempt = 0; attempt < 6; attempt++) {
  after = await bee.makeFeedReader(topic, owner).downloadReference().catch(() => null)
  if (after?.reference.toHex() === upload.reference.toHex()) break
  await new Promise((r) => setTimeout(r, 500 * (attempt + 1)))
}
if (after?.reference.toHex() !== upload.reference.toHex()) {
  throw new Error('feed did not advance — nothing was published')
}
const feed = (await bee.createFeedManifest(batch.batchID, topic, owner)).toHex()

// Record it where the other five are recorded, so the topic is never lost again.
// Recorded beside the key, wherever that is.
const path = join(dirname(KEYFILE), 'feed-manifests.json')
const manifests = JSON.parse(readFileSync(path, 'utf8'))
manifests[LABEL] = {
  ens_name: 'git.ontheswarm.eth',
  feedManifest: feed,
  bzz: `bzz://${feed}`,
  contenthash: `0xe40101fa011b20${feed}`,
  topic: topic.toHex(),
  topic_string: TOPIC_STRING,
  owner: owner.toHex().replace(/^0x/, ''),
  type: 'Sequence',
}
writeFileSync(path, JSON.stringify(manifests, null, 2) + '\n')

console.log(`
────────────────────────────────────────────────────────────
viewer feed  ${feed}
ENS          git.ontheswarm.eth → bzz://${feed}

  https://bzz.limo/bzz/${feed}/
────────────────────────────────────────────────────────────`)
