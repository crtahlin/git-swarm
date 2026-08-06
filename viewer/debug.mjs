// Run the viewer's loader under Node — same code, real stack traces.
// Debugging this in a headless browser is slow; this takes seconds.
import { resolveManifest, loadRepository, commitLog, listTree } from './src/repo.js'
const gw = process.argv[3] || 'http://localhost:1633'
const ref = process.argv[2]
if (!ref) {
  console.error('usage: node debug.mjs <feed-manifest-ref> [gateway]')
  process.exit(64)
}
const target = { mode: 'manifest', ref }
const { manifest } = await resolveManifest(gw, target)
console.log('manifest ok:', manifest.repo, '| packs:', manifest.packs.length, '| head:', manifest.head)
const repo = await loadRepository(gw, manifest, (m) => console.log(' ', m))
const log = await commitLog(repo, manifest.head, 5)
console.log('commits:', log.length, log[0]?.commit.message.split('\n')[0])
const tree = await listTree(repo, manifest.refs[manifest.head], '')
console.log('tree entries:', tree.map(e => e.path).join(', ').slice(0, 200))
