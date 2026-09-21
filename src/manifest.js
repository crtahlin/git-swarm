// The swarm-git/1 manifest — see docs/spec-swarm-git-format-v1.md.

export const FORMAT = 'swarm-git/1'

/**
 * The names each object is stored under inside its bzz manifest.
 *
 * Shared because a reader must ask for the entry by name — see downloadBytes in
 * swarm.js — so writer and reader drifting apart would break retrieval on some
 * nodes and not others. They were duplicated in protocol.js and republish.mjs
 * before anything read them.
 */
export const ENTRY_PACK = 'pack'
export const ENTRY_MANIFEST = 'manifest.json'

export function emptyManifest(repo) {
  return { format: FORMAT, repo, head: null, refs: {}, packs: [], parent: null }
}

export function validate(obj) {
  if (!obj || typeof obj !== 'object') throw new Error('manifest is not an object')
  if (obj.format !== FORMAT) {
    throw new Error(`unsupported manifest format ${JSON.stringify(obj.format)}, expected ${FORMAT}`)
  }
  if (!obj.refs || typeof obj.refs !== 'object') throw new Error('manifest has no refs')
  if (!Array.isArray(obj.packs)) throw new Error('manifest has no packs array')
  if (obj.head && !(obj.head in obj.refs)) {
    throw new Error(`manifest head ${obj.head} is not among its refs`)
  }
  return obj
}

/** Ref advertisement lines for the remote-helper `list` command. */
export function listLines(manifest) {
  const lines = Object.entries(manifest.refs).map(([name, sha]) => `${sha} ${name}`)
  if (manifest.head) lines.push(`@${manifest.head} HEAD`)
  return lines
}

/**
 * A new manifest built on top of `base`, applying ref updates and appending one
 * pack. `packs` stays cumulative and oldest-first: a reader needs the whole list
 * and indexes it in order.
 */
export function advance(base, { refUpdates, pack, parentRef }) {
  const refs = { ...base.refs }
  for (const [name, sha] of Object.entries(refUpdates)) {
    if (sha === null) delete refs[name]
    else refs[name] = sha
  }

  let head = base.head
  if (!head || !(head in refs)) {
    head = refs['refs/heads/main'] ? 'refs/heads/main'
      : refs['refs/heads/master'] ? 'refs/heads/master'
      : Object.keys(refs).find((r) => r.startsWith('refs/heads/')) || null
  }

  return {
    format: FORMAT,
    repo: base.repo,
    head,
    refs,
    packs: pack ? [...base.packs, pack] : [...base.packs],
    parent: parentRef ?? null,
  }
}
