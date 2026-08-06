// URL parsing and settings resolution for git-remote-swarm.
//
// Git invokes the helper as `git-remote-swarm <remote> <url>`, where <remote> is
// either a configured remote name or the URL again. Settings are read from that
// remote's git config first, then the environment, then defaults.

import { execFileSync } from 'node:child_process'

export const TOPIC_PREFIX = 'swarm-git:v1:'
const DEFAULT_API = 'http://localhost:1633'

export function gitConfig(key) {
  try {
    return execFileSync('git', ['config', '--get', key], { encoding: 'utf8' }).trim()
  } catch {
    return ''
  }
}

/**
 * Two grammars, deliberately distinguished — see the format spec §2.1.
 *
 *   bzz://<reference|name.eth>       a CONTENT reference: read-only, and means
 *                                    exactly what bzz:// means in a browser or
 *                                    an ENS contenthash, so it is portable
 *   bzz::<owner>/<repo>[?topic=hex]  a REPOSITORY endpoint: clone, fetch, push.
 *                                    Git's `<transport>::<address>` form, which
 *                                    is its documented idiom for a foreign
 *                                    address grammar — and a visible signal that
 *                                    this is not a URL a browser can open.
 *
 * `swarm://…` is still accepted for anything already published with it, and Git
 * passes the bare address for the `::` form, so a schemeless string is valid too.
 */
export function parseUrl(raw) {
  const url = String(raw || '')

  const stripped = url.replace(/^(swarm|bzz):(\/\/|:)/i, '')
  const [pathPart, queryPart] = stripped.split('?')
  const params = new URLSearchParams(queryPart || '')

  // `?gateway=` makes a URL self-contained: paste it to anyone and it reads from
  // the endpoint you named, with no environment to set up first.
  const gateway = params.get('gateway') || null

  // `bzz://<64hex>` and `bzz://<name>.eth` are content references — the same
  // read-only form as `swarm://bzz/<ref>`, spelled the way the rest of the
  // ecosystem spells it.
  const single = pathPart.replace(/\/+$/, '')
  if (/^bzz:\/\//i.test(url) && single && !/[/]/.test(single) && !/^bzz$/i.test(single)) {
    const value = single.toLowerCase()
    if (/^[0-9a-f]{64}$/.test(value) || isEnsName(value)) {
      return { mode: 'manifest', feedManifest: value, gateway }
    }
  }
  const segments = pathPart.split('/').filter(Boolean)

  if (segments[0] === 'bzz') {
    const value = (segments[1] || '').toLowerCase()
    if (!/^[0-9a-f]{64}$/.test(value) && !isEnsName(value)) {
      throw new Error('bzz/<ref> needs a 64-hex feed manifest reference or an ENS name')
    }
    return { mode: 'manifest', feedManifest: value, gateway }
  }

  // A single ENS name with no repo segment is a content reference too.
  if (segments.length === 1 && isEnsName(segments[0])) {
    return { mode: 'manifest', feedManifest: segments[0].toLowerCase(), gateway }
  }

  const owner = (segments[0] || '').replace(/^0x/i, '').toLowerCase()
  const repo = segments.slice(1).join('/')
  if (!/^[0-9a-f]{40}$/.test(owner)) {
    throw new Error(
      `expected bzz::<owner-address>/<repo> or bzz://<reference|name.eth>, got: ${url}`,
    )
  }
  if (!repo) throw new Error('missing repository name in swarm:// URL')

  const topic = params.get('topic')
  if (topic && !/^[0-9a-f]{64}$/i.test(topic)) {
    throw new Error('?topic= must be 64 hex characters')
  }

  return { mode: 'feed', owner, repo, topicOverride: topic ? topic.toLowerCase() : null, gateway }
}

function isEnsName(value) {
  return /^[a-z0-9-]+(\.[a-z0-9-]+)*\.eth$/i.test(value)
}

export function resolveSettings(remoteName) {
  const scoped = (key) => (remoteName ? gitConfig(`remote.${remoteName}.${key}`) : '')

  const api = scoped('swarmApi') || process.env.SWARM_API || process.env.BEE_API || DEFAULT_API
  const gateway = scoped('swarmGateway') || process.env.SWARM_GATEWAY || api

  return {
    api,
    gateway,
    // Writing needs both; reading needs neither. Missing values are reported at
    // push time, where the failure is actionable, not at startup.
    batch: scoped('swarmBatch') || process.env.SWARM_BATCH_ID || '',
    key: scoped('swarmKey') || process.env.SWARM_PRIVATE_KEY || '',
    minBatchTtlSeconds: Number(scoped('swarmMinBatchTtl') || process.env.SWARM_MIN_BATCH_TTL || 3600),
  }
}
