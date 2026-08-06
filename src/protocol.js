// The git remote-helper protocol: Git writes commands on our stdin, we answer
// on stdout. See gitremote-helpers(7). Nothing but protocol responses may go to
// stdout — diagnostics belong on stderr.

import { mkdtempSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { createInterface } from 'node:readline'

import { parseUrl, resolveSettings } from './config.js'
import * as git from './gitplumbing.js'
import * as m from './manifest.js'
import { Swarm, topicFor } from './swarm.js'

const CAPABILITIES = ['fetch', 'push', 'option']

export async function run(argv, { stdin = process.stdin, stdout = process.stdout } = {}) {
  const remoteName = argv[0]
  const url = argv[1] || argv[0]

  const target = parseUrl(url)
  const base = resolveSettings(remoteName && remoteName !== url ? remoteName : null)
  // A gateway named in the URL wins: it is the most specific statement of intent.
  const settings = target.gateway ? { ...base, gateway: target.gateway } : base
  const swarm = new Swarm(settings)

  const topic = target.mode === 'feed'
    ? (target.topicOverride ? target.topicOverride : topicFor(target.repo))
    : null

  const state = {
    target, settings, swarm, topic,
    manifest: null,
    manifestRef: null,
    feedNextIndex: null,
    options: {},
  }

  const out = (line = '') => stdout.write(line + '\n')
  const rl = createInterface({ input: stdin, terminal: false })

  let batch = null // accumulates fetch/push command batches
  for await (const raw of rl) {
    const line = raw.replace(/\r$/, '')

    if (batch) {
      if (line === '') {
        const commands = batch.commands
        const kind = batch.kind
        batch = null
        if (kind === 'fetch') await doFetch(state, commands, out)
        else await doPush(state, commands, out)
        continue
      }
      batch.commands.push(line)
      continue
    }

    if (line === '') continue

    const [command, ...rest] = line.split(' ')
    switch (command) {
      case 'capabilities':
        for (const c of CAPABILITIES) out(c)
        out()
        break

      case 'list':
        await doList(state, out)
        break

      case 'option':
        state.options[rest[0]] = rest.slice(1).join(' ')
        out(rest[0] === 'verbosity' || rest[0] === 'progress' || rest[0] === 'cloning' ? 'ok' : 'unsupported')
        break

      case 'fetch':
        batch = { kind: 'fetch', commands: [line] }
        break

      case 'push':
        batch = { kind: 'push', commands: [line] }
        break

      default:
        // Unknown commands terminate the conversation, per the protocol.
        return
    }
  }
}

// --- shared state ----------------------------------------------------------

async function loadManifest(state, { required = true } = {}) {
  if (state.manifest) return state.manifest

  try {
    if (state.target.mode === 'manifest') {
      state.manifestRef = state.target.feedManifest
    } else {
      const feed = await state.swarm.feedState(state.target.owner, state.topic)
      state.manifestRef = feed.ref
      state.feedNextIndex = feed.nextIndex
    }
    state.manifest = m.validate(await state.swarm.downloadJson(state.manifestRef))
  } catch (err) {
    if (required) throw err
    // An empty repository is not an error on push — it is the first push.
    state.manifest = m.emptyManifest(state.target.repo || '')
    state.manifestRef = null
    state.feedNextIndex = 0n
    process.stderr.write(`swarm: no existing repository at this address (${err.message})\n`)
  }
  return state.manifest
}

// --- commands --------------------------------------------------------------

async function doList(state, out) {
  const manifest = await loadManifest(state, { required: false })
  for (const line of m.listLines(manifest)) out(line)
  out()
}

async function doFetch(state, commands, out) {
  const manifest = await loadManifest(state)
  const dir = mkdtempSync(join(tmpdir(), 'swarm-git-'))

  try {
    // Oldest first: a thin pack completes its bases from what earlier packs left
    // behind, so order is load-bearing, not cosmetic.
    for (const [i, pack] of manifest.packs.entries()) {
      const wanted = pack.tips?.length ? pack.tips.some((sha) => !git.hasObject(sha)) : true
      if (!wanted) continue

      process.stderr.write(`swarm: downloading pack ${i + 1}/${manifest.packs.length} (${pack.size ?? '?'} bytes)\n`)
      const data = await state.swarm.downloadBytes(pack.ref)
      const path = join(dir, `${i}.pack`)
      writeFileSync(path, data)
      await git.indexPack(path)
    }
    out()
  } finally {
    rmSync(dir, { recursive: true, force: true })
  }
  void commands
}

async function doPush(state, commands, out) {
  const { swarm, settings } = state

  try {
    swarm.requireWritable()
    await swarm.checkNode()
    await swarm.checkBatch()
  } catch (err) {
    for (const c of commands) out(`error ${destOf(c)} ${firstLine(err.message)}`)
    process.stderr.write(`swarm: ${err.message}\n`)
    out()
    return
  }

  const base = await loadManifest(state, { required: false })
  const baseRef = state.manifestRef

  const refUpdates = {}
  const newTips = []
  const results = []

  for (const command of commands) {
    const spec = command.slice('push '.length)
    const forced = spec.startsWith('+')
    const [src, dst] = (forced ? spec.slice(1) : spec).split(':')

    if (!src) {
      refUpdates[dst] = null // deletion: `push :refs/heads/x`
      results.push(`ok ${dst}`)
      continue
    }

    const sha = git.revParse(src)
    if (!sha) {
      results.push(`error ${dst} no such ref locally`)
      continue
    }

    const existing = base.refs[dst]
    if (existing && !forced && !git.isAncestor(existing, sha)) {
      results.push(`error ${dst} non-fast-forward`)
      continue
    }

    refUpdates[dst] = sha
    newTips.push(sha)
    results.push(`ok ${dst}`)
  }

  const accepted = Object.keys(refUpdates).length > 0
  const hasNewObjects = newTips.length > 0

  if (!accepted) {
    for (const r of results) out(r)
    out()
    return
  }

  const dir = mkdtempSync(join(tmpdir(), 'swarm-git-'))
  try {
    let pack = null

    if (hasNewObjects) {
      // Everything reachable from the new tips that the remote does not already
      // have. Excluding the remote's known tips is what makes a push incremental.
      const excludes = Object.values(base.refs).filter((sha) => git.hasObject(sha))
      const packPath = join(dir, 'push.pack')
      await git.packObjects(newTips, excludes, packPath)

      const { readFileSync, statSync } = await import('node:fs')
      const size = statSync(packPath).size
      const data = readFileSync(packPath)
      process.stderr.write(`swarm: uploading ${size} bytes of new objects\n`)

      const ref = await swarm.uploadFile(data, 'pack', 'application/x-git-packfile')
      pack = { ref, size, batch: settings.batch, tips: newTips, base: excludes }
    }

    // Lost-update check: if the feed moved while we were packing, someone else
    // published. A feed has one writer, so this does not make concurrency safe —
    // it makes it loud instead of silently clobbering.
    if (state.target.mode === 'feed' && baseRef) {
      const current = await swarm.feedManifestRef(state.target.owner, state.topic).catch(() => null)
      if (current && current !== baseRef) {
        for (const r of results) out(r.startsWith('ok') ? `error ${r.slice(3)} stale feed, fetch and retry` : r)
        out()
        return
      }
    }

    const next = m.advance(base, { refUpdates, pack, parentRef: baseRef })
    const manifestRef = await swarm.uploadFile(
      Buffer.from(JSON.stringify(next, null, 2)),
      'manifest.json',
      'application/json',
    )
    await swarm.updateFeed(state.topic, manifestRef, state.feedNextIndex)
    const feedManifest = await swarm.ensureFeedManifest(state.topic, state.target.owner)

    state.manifest = next
    state.manifestRef = manifestRef
    // Keep the index in step so a second push in the same process does not reuse
    // an index and get silently dropped.
    if (state.feedNextIndex !== null) state.feedNextIndex = BigInt(state.feedNextIndex) + 1n
    process.stderr.write(`swarm: manifest ${manifestRef}\nswarm: feed manifest ${feedManifest}\n`)

    for (const r of results) out(r)
    out()
  } catch (err) {
    for (const c of commands) out(`error ${destOf(c)} ${firstLine(err.message)}`)
    process.stderr.write(`swarm: ${err.stack || err.message}\n`)
    out()
  } finally {
    rmSync(dir, { recursive: true, force: true })
  }
}

function destOf(command) {
  const spec = command.slice(command.indexOf(' ') + 1).replace(/^\+/, '')
  return spec.split(':')[1] || spec
}

function firstLine(text) {
  return String(text).split('\n')[0]
}
