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
 * swarm://<owner>/<repo>[?topic=<hex>]   canonical, read and write
 * swarm://bzz/<feed-manifest-ref>        read-only, resolvable through a gateway
 */
export function parseUrl(raw) {
  const url = String(raw || '')
  const m = url.match(/^swarm:\/\/(.+)$/i)
  if (!m) throw new Error(`not a swarm:// URL: ${url}`)

  const [pathPart, queryPart] = m[1].split('?')
  const query = new URLSearchParams(queryPart || '')
  const segments = pathPart.split('/').filter(Boolean)

  if (segments[0] === 'bzz') {
    if (!/^[0-9a-f]{64}$/i.test(segments[1] || '')) {
      throw new Error('swarm://bzz/<ref> needs a 64-hex feed manifest reference')
    }
    return { mode: 'manifest', feedManifest: segments[1].toLowerCase() }
  }

  const owner = (segments[0] || '').replace(/^0x/i, '').toLowerCase()
  const repo = segments.slice(1).join('/')
  if (!/^[0-9a-f]{40}$/.test(owner)) {
    throw new Error(`expected swarm://<owner-address>/<repo>, got: ${url}`)
  }
  if (!repo) throw new Error('missing repository name in swarm:// URL')

  const topic = query.get('topic')
  if (topic && !/^[0-9a-f]{64}$/i.test(topic)) {
    throw new Error('?topic= must be 64 hex characters')
  }

  return { mode: 'feed', owner, repo, topicOverride: topic ? topic.toLowerCase() : null }
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
