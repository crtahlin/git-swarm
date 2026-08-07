// Re-publish a repository's entire history as a single packfile.
//
//   node scripts/republish.mjs
//
// Two reasons to do this:
//
//   1. Moving batches. A push only stamps the objects it uploads, so packs
//      written under an old batch stay there and lapse with it. Re-publishing
//      everything under the current batch puts the whole history on one clock.
//   2. Compaction. Ten pushes leave ten packs, and a clone downloads all of
//      them. One pack is one download.
//
// The feed address does not change — same owner, same topic — so every published
// link and any ENS record keeps working.

import { execFileSync } from 'node:child_process'
import { mkdtempSync, readFileSync, rmSync, statSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'

import { gitConfig, parseUrl, resolveSettings } from '../src/config.js'
import * as git from '../src/gitplumbing.js'
import * as m from '../src/manifest.js'
import { Swarm, topicFor } from '../src/swarm.js'

const REMOTE = process.env.REMOTE || 'swarm'
const url = gitConfig(`remote.${REMOTE}.url`)
if (!url) throw new Error(`no url for remote "${REMOTE}"`)

const target = parseUrl(url)
if (target.mode !== 'feed') throw new Error('republish needs a writable bzz::<owner>/<repo> remote')

const settings = resolveSettings(REMOTE)
const swarm = new Swarm(settings)
const topic = target.topicOverride ?? topicFor(target.repo)

console.log(`remote     ${url}`)
console.log(`batch      ${settings.batch.slice(0, 16)}…`)

swarm.requireWritable()
await swarm.checkNode()
const health = await swarm.checkBatch()
console.log(`batch ttl  ${Math.round(health.ttl / 86400)} days, ${Math.round(health.ratio * 100)}% full`)

// Current state: refs come from the local repository (the source of truth for
// what should be published), the parent from the feed.
const before = await swarm.feedState(target.owner, topic).catch(() => ({ ref: null, nextIndex: 0n }))
const previous = before.ref ? await swarm.downloadJson(before.ref).catch(() => null) : null
console.log(`previous   ${before.ref ?? '(none)'}${previous ? ` — ${previous.packs.length} packs` : ''}`)

const refLines = execFileSync('git', ['show-ref'], { encoding: 'utf8' }).trim().split('\n')
const refs = {}
for (const line of refLines) {
  const [sha, name] = line.split(' ')
  if (name.startsWith('refs/heads/') || name.startsWith('refs/tags/')) refs[name] = sha
}
const head = git.symbolicHead()
console.log(`refs       ${Object.keys(refs).length} (head ${head})`)

// One pack containing everything reachable, nothing excluded.
const dir = mkdtempSync(join(tmpdir(), 'swarm-git-republish-'))
try {
  const packPath = join(dir, 'all.pack')
  await git.packObjects(Object.values(refs), [], packPath)
  const size = statSync(packPath).size
  console.log(`pack       ${size} bytes (whole history, one pack)`)

  const ref = await swarm.uploadFile(readFileSync(packPath), 'pack', 'application/x-git-packfile')
  console.log(`uploaded   ${ref}`)

  const manifest = m.advance(m.emptyManifest(target.repo), {
    refUpdates: refs,
    pack: { ref, size, batch: settings.batch, tips: Object.values(refs), base: [] },
    parentRef: before.ref,
  })
  manifest.head = head in refs ? head : manifest.head

  const manifestRef = await swarm.uploadFile(
    Buffer.from(JSON.stringify(manifest, null, 2)), 'manifest.json', 'application/json',
  )
  await swarm.updateFeed(topic, manifestRef, before.nextIndex)
  const feedManifest = await swarm.ensureFeedManifest(topic, target.owner)

  console.log(`
────────────────────────────────────────────────────────────
manifest   ${manifestRef}
feed       ${feedManifest}   (unchanged — links keep working)

  git clone bzz://${feedManifest}
────────────────────────────────────────────────────────────`)
} finally {
  rmSync(dir, { recursive: true, force: true })
}
