// Loading a swarm-git repository in the browser.
//
// Everything here runs client-side: the page fetches the manifest and packfiles
// straight from a Swarm gateway and reconstructs the repository in an in-memory
// filesystem. There is no backend, and nothing but the reader's own browser ever
// executes.

import git from 'isomorphic-git'
import { keccak256 } from 'js-sha3'
import { createMemFs } from './memfs.js'

const DIR = '/repo'
const GITDIR = '/repo/.git'

export function gatewayFromLocation() {
  // When this page is itself served from a gateway at /bzz/<hash>/, the gateway
  // root is simply the page's origin — so a viewer published to Swarm reads
  // repositories through whichever gateway served it.
  const explicit = new URLSearchParams(location.search).get('gateway')
  return (explicit || location.origin).replace(/\/+$/, '')
}

/**
 * Parse the fragment:
 *   #bzz/<feed-manifest-ref>       resolve through a feed manifest (works on a gateway)
 *   #<owner>/<repo>               resolve through /feeds (needs a local Bee node)
 */
export function parseTarget(hash) {
  const raw = (hash || '').replace(/^#\/?/, '')
  if (!raw) return null

  const [path] = raw.split('?')
  const parts = path.split('/').filter(Boolean)

  if (parts[0] === 'bzz' && /^[0-9a-f]{64}$/i.test(parts[1] || '')) {
    return { mode: 'manifest', ref: parts[1].toLowerCase() }
  }
  if (/^(0x)?[0-9a-f]{40}$/i.test(parts[0] || '') && parts[1]) {
    return { mode: 'feed', owner: parts[0].replace(/^0x/i, '').toLowerCase(), repo: parts.slice(1).join('/') }
  }
  return null
}

async function fetchBytes(gateway, reference) {
  const res = await fetch(`${gateway}/bzz/${reference}/`)
  if (!res.ok) throw new Error(`gateway returned ${res.status} for ${reference.slice(0, 8)}…`)
  return new Uint8Array(await res.arrayBuffer())
}

export async function resolveManifest(gateway, target) {
  let manifestRef = target.ref

  if (target.mode === 'feed') {
    // /feeds is not exposed by public gateways — this path only works against a
    // local Bee node, and the UI says so when it fails.
    const res = await fetch(`${gateway}/feeds/${target.owner}/${await topicHex(target.repo)}`)
    if (!res.ok) {
      throw new Error(
        `could not resolve the feed (${res.status}). Public gateways do not serve /feeds — ` +
          'use a #bzz/<feed-manifest> link, or point the viewer at a local Bee node with ?gateway=',
      )
    }
    manifestRef = (await res.json()).reference
  }

  const bytes = await fetchBytes(gateway, manifestRef)
  const manifest = JSON.parse(new TextDecoder().decode(bytes))
  if (manifest.format !== 'swarm-git/1') {
    throw new Error(`unsupported manifest format: ${manifest.format}`)
  }
  return { manifest, manifestRef }
}

/** topic = keccak256("swarm-git:v1:" + repo) — see the format spec. */
async function topicHex(repo) {
  return keccak256('swarm-git:v1:' + repo)
}

/**
 * Rebuild the repository in memory: write each packfile into .git/objects/pack,
 * index it, then materialise the refs the manifest advertises.
 */
export async function loadRepository(gateway, manifest, onProgress = () => {}) {
  // In memory on purpose: a viewer needs no persistence, and IndexedDB-backed
  // filesystems stall in some browser contexts and depend on storage permissions
  // that a page served from a gateway should not need.
  const fs = createMemFs()
  const pfs = fs.promises

  await pfs.mkdir(DIR)
  await git.init({ fs, dir: DIR, gitdir: GITDIR, defaultBranch: 'main' })
  await pfs.mkdir(`${DIR}/.git/objects/pack`, { recursive: true }).catch(() => {})

  for (const [i, pack] of manifest.packs.entries()) {
    onProgress(`downloading pack ${i + 1}/${manifest.packs.length}`)
    const bytes = await fetchBytes(gateway, pack.ref)

    const filepath = `.git/objects/pack/pack-${pack.ref.slice(0, 40)}.pack`
    await pfs.writeFile(`${DIR}/${filepath}`, bytes)
    onProgress(`indexing pack ${i + 1}/${manifest.packs.length}`)
    await git.indexPack({ fs, dir: DIR, gitdir: GITDIR, filepath })
  }

  for (const [name, oid] of Object.entries(manifest.refs)) {
    await git.writeRef({ fs, dir: DIR, gitdir: GITDIR, ref: name, value: oid, force: true })
  }
  if (manifest.head) {
    await git.writeRef({ fs, dir: DIR, gitdir: GITDIR, ref: 'HEAD', value: manifest.head, force: true, symbolic: true })
  }

  return { fs, dir: DIR, gitdir: GITDIR }
}

export async function commitLog(repo, ref, depth = 50) {
  return git.log({ ...repo, ref, depth })
}

export async function listTree(repo, oid, path = '') {
  const { tree } = await git.readTree({ ...repo, oid, filepath: path || undefined })
  return tree
}

export async function readFile(repo, oid, filepath) {
  const { blob } = await git.readBlob({ ...repo, oid, filepath })
  return blob
}
