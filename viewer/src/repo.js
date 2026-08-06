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

const FALLBACK_GATEWAY = 'https://bzz.limo'

export function gatewayFromLocation() {
  const explicit = new URLSearchParams(location.search).get('gateway')
  if (explicit) return explicit.replace(/\/+$/, '')

  // Subdomain-style gateways (eth.limo, bzz.link) serve exactly one ENS name and
  // have no /bzz/<ref> path, so the page's own origin cannot be used to fetch the
  // repository. Path-style gateways can, and a viewer served from one should keep
  // using it rather than sending readers somewhere else.
  if (/\.(eth\.limo|eth\.link|bzz\.link)$/i.test(location.hostname)) return FALLBACK_GATEWAY
  if (location.protocol === 'file:') return FALLBACK_GATEWAY
  return location.origin.replace(/\/+$/, '')
}

/**
 * Parse the fragment:
 *   #bzz/<feed-manifest-ref>      resolve a feed manifest by reference
 *   #ens/<name.eth>              resolve an ENS name whose contenthash is the feed manifest
 *   #<name.eth>                  same, shorthand
 *   #<owner>/<repo>              resolve through /feeds (needs a local Bee node)
 *
 * Any of them may carry a path after `/-/`, which opens that file or directory:
 *   #bzz/<ref>/-/docs/architecture.md
 *
 * Deep links rather than in-page navigation, so a link inside a rendered README is a
 * real URL: shareable, bookmarkable, and testable by loading it.
 *
 * ENS names need no special handling beyond being allowed through: a gateway
 * serves /bzz/<name.eth>/ exactly as it serves /bzz/<reference>/, resolving the
 * contenthash itself. Verified against swarm.eth on both a local node and
 * bzz.limo.
 */
export function parseTarget(hash) {
  const raw = (hash || '').replace(/^#\/?/, '')
  if (!raw) return null

  const [beforeQuery] = raw.split('?')
  const [locator, ...pathParts] = beforeQuery.split('/-/')

  // A markdown link may carry an in-page anchor — `docs/addressing.md#which-gateway`.
  // The browser puts everything after the first `#` in location.hash, so the anchor
  // arrives glued to the path and must be split off, or it becomes part of the
  // filename and nothing resolves.
  const [rawPath, ...anchorParts] = (pathParts.join('/-/') || '').split('#')
  const filePath = rawPath || null
  const anchor = anchorParts.join('#') || null
  const parts = locator.split('/').filter(Boolean)

  if (parts[0] === 'bzz' && /^[0-9a-f]{64}$/i.test(parts[1] || '')) {
    return { mode: 'manifest', ref: parts[1].toLowerCase(), filePath, anchor }
  }
  if (parts[0] === 'ens' && isEnsName(parts[1] || '')) {
    return { mode: 'manifest', ref: parts[1].toLowerCase(), filePath, anchor }
  }
  if (parts.length === 1 && isEnsName(parts[0])) {
    return { mode: 'manifest', ref: parts[0].toLowerCase(), filePath, anchor }
  }
  if (/^(0x)?[0-9a-f]{40}$/i.test(parts[0] || '') && parts[1]) {
    return {
      mode: 'feed',
      owner: parts[0].replace(/^0x/i, '').toLowerCase(),
      repo: parts.slice(1).join('/'),
      filePath,
      anchor,
    }
  }
  return null
}

function isEnsName(value) {
  return /^[a-z0-9-]+(\.[a-z0-9-]+)*\.eth$/i.test(value)
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

/** The fragment prefix that addresses this repository, without any file path. */
export function targetPrefix(target) {
  if (target.mode === 'manifest') {
    return /^[0-9a-f]{64}$/.test(target.ref) ? `bzz/${target.ref}` : `ens/${target.ref}`
  }
  return `${target.owner}/${target.repo}`
}

/** Resolve a relative link against the directory holding the file it appeared in. */
export function resolveRelative(fromFile, href) {
  const base = href.startsWith('/') ? [] : String(fromFile || '').split('/').slice(0, -1)
  const out = [...base]
  for (const segment of href.replace(/^\//, '').split('/')) {
    if (!segment || segment === '.') continue
    if (segment === '..') out.pop()
    else out.push(segment)
  }
  return out.join('/')
}

/** Links we must not rewrite: absolute, protocol-relative, in-page anchors, mail. */
export function isExternalHref(href) {
  return /^([a-z][a-z0-9+.-]*:|\/\/|#)/i.test(href)
}
