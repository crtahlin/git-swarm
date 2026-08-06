// The viewer UI. Renders a swarm-git repository entirely in the browser.

import { marked } from 'marked'
import {
  commitLog, gatewayFromLocation, listTree, loadRepository, parseTarget, readFile, resolveManifest,
} from './repo.js'

const $ = (id) => document.getElementById(id)
const el = (tag, className, text) => {
  const node = document.createElement(tag)
  if (className) node.className = className
  if (text !== undefined) node.textContent = text
  return node
}

if (new URLSearchParams(location.search).has('debug')) globalThis.__fslog = []

const state = { repo: null, manifest: null, gateway: null, headOid: null, path: [] }

function status(message, kind = 'info') {
  const box = $('status')
  box.className = `status ${kind}`
  box.textContent = message
  box.hidden = false
}

function hideStatus() {
  $('status').hidden = true
}

// --- boot -------------------------------------------------------------------

async function boot() {
  const target = parseTarget(location.hash)
  if (!target) return showLanding()

  state.gateway = gatewayFromLocation()
  $('app').hidden = false
  $('landing').hidden = true

  try {
    status('resolving feed…')
    const { manifest, manifestRef } = await resolveManifest(state.gateway, target)
    state.manifest = manifest

    status('loading repository…')
    state.repo = await loadRepository(state.gateway, manifest, (m) => status(m))

    state.headOid = manifest.refs[manifest.head] || Object.values(manifest.refs)[0]
    hideStatus()
    renderHeader(manifest, manifestRef)
    await Promise.all([renderCommits(), renderTree([])])
  } catch (err) {
    const debug = new URLSearchParams(location.search).has('debug')
    const trace = debug ? `${err.stack || ''}\n\nfs calls:\n${(globalThis.__fslog || []).join('\n')}` : ''
    status(debug ? `${err.message}\n\n${trace}` : err.message, 'error')
    console.error(err)
  }
}

function showLanding() {
  $('landing').hidden = false
  $('app').hidden = true
}

// --- header -----------------------------------------------------------------

function renderHeader(manifest, manifestRef) {
  $('repo-name').textContent = manifest.repo || 'repository'
  $('repo-head').textContent = manifest.head || ''

  const meta = $('repo-meta')
  meta.replaceChildren()

  const totalBytes = manifest.packs.reduce((sum, p) => sum + (p.size || 0), 0)
  const facts = [
    [`${Object.keys(manifest.refs).length} refs`, null],
    [`${manifest.packs.length} packs`, null],
    [formatBytes(totalBytes), null],
    ['manifest', manifestRef],
  ]

  for (const [label, value] of facts) {
    const chip = el('span', 'chip')
    chip.append(el('span', 'chip-label', label))
    if (value) chip.append(el('code', 'chip-value', `${value.slice(0, 10)}…`))
    meta.append(chip)
  }

  const refs = $('refs')
  refs.replaceChildren()
  for (const [name, oid] of Object.entries(manifest.refs)) {
    const row = el('button', 'ref')
    row.append(el('span', 'ref-name', name.replace(/^refs\/(heads|tags)\//, '')))
    row.append(el('code', 'ref-oid', oid.slice(0, 8)))
    row.onclick = async () => {
      state.headOid = oid
      state.path = []
      await Promise.all([renderCommits(name), renderTree([])])
    }
    refs.append(row)
  }

  // Git-native issue trackers keep their data in refs, so they arrive with the
  // repository rather than living in somebody's database.
  const issueRefs = Object.keys(manifest.refs).filter((r) => /^refs\/(bugs|cobs)\//.test(r))
  if (issueRefs.length) {
    $('issues-note').textContent = `${issueRefs.length} issue refs present (refs/bugs or refs/cobs) — not yet rendered`
    $('issues-note').hidden = false
  }
}

// --- commits ----------------------------------------------------------------

async function renderCommits(ref) {
  const list = $('commits')
  list.replaceChildren()

  const commits = await commitLog(state.repo, ref || state.manifest.head || 'HEAD', 50)
  for (const entry of commits) {
    const item = el('li', 'commit')
    const subject = entry.commit.message.split('\n')[0]
    item.append(el('div', 'commit-subject', subject))

    const line = el('div', 'commit-meta')
    line.append(el('code', 'commit-oid', entry.oid.slice(0, 8)))
    line.append(el('span', 'commit-author', entry.commit.author.name))
    line.append(el('span', 'commit-date', new Date(entry.commit.author.timestamp * 1000).toISOString().slice(0, 10)))
    item.append(line)
    list.append(item)
  }
  $('commit-count').textContent = String(commits.length)
}

// --- tree and files ---------------------------------------------------------

async function renderTree(path) {
  state.path = path
  const box = $('tree')
  box.replaceChildren()
  $('file').hidden = true
  $('tree-panel').hidden = false

  renderBreadcrumb(path)

  const entries = await listTree(state.repo, state.headOid, path.join('/'))
  const sorted = [...entries].sort((a, b) =>
    a.type === b.type ? a.path.localeCompare(b.path) : a.type === 'tree' ? -1 : 1)

  for (const entry of sorted) {
    const row = el('button', `entry entry-${entry.type}`)
    row.append(el('span', 'entry-icon', entry.type === 'tree' ? '›' : ''))
    row.append(el('span', 'entry-name', entry.path))
    row.onclick = () =>
      entry.type === 'tree' ? renderTree([...path, entry.path]) : openFile([...path, entry.path])
    box.append(row)
  }

  const readme = sorted.find((e) => e.type === 'blob' && /^readme\.md$/i.test(e.path))
  if (readme && path.length === 0) await openFile([readme.path], { keepTree: true })
}

function renderBreadcrumb(path) {
  const crumbs = $('breadcrumb')
  crumbs.replaceChildren()

  const root = el('button', 'crumb', state.manifest.repo || 'root')
  root.onclick = () => renderTree([])
  crumbs.append(root)

  path.forEach((segment, i) => {
    crumbs.append(el('span', 'crumb-sep', '/'))
    const crumb = el('button', 'crumb', segment)
    crumb.onclick = () => renderTree(path.slice(0, i + 1))
    crumbs.append(crumb)
  })
}

async function openFile(path, { keepTree = false } = {}) {
  const filepath = path.join('/')
  const blob = await readFile(state.repo, state.headOid, filepath)
  const text = new TextDecoder().decode(blob)

  const panel = $('file')
  panel.hidden = false
  if (!keepTree) $('tree-panel').hidden = true

  $('file-name').textContent = filepath
  const body = $('file-body')
  body.replaceChildren()

  if (/\.md$/i.test(filepath)) {
    const rendered = el('div', 'markdown')
    rendered.innerHTML = marked.parse(text)
    body.append(rendered)
  } else if (looksBinary(blob)) {
    body.append(el('p', 'muted', `binary file, ${formatBytes(blob.length)}`))
  } else {
    body.append(el('pre', 'code', text))
  }

  if (!keepTree) {
    const back = el('button', 'back', '← back to files')
    back.onclick = () => renderTree(path.slice(0, -1))
    body.prepend(back)
  }
}

// --- helpers ----------------------------------------------------------------

function looksBinary(bytes) {
  const sample = bytes.subarray(0, 1024)
  for (const byte of sample) if (byte === 0) return true
  return false
}

function formatBytes(n) {
  if (n < 1024) return `${n} B`
  if (n < 1024 * 1024) return `${(n / 1024).toFixed(1)} kB`
  return `${(n / 1024 / 1024).toFixed(1)} MB`
}

$('open-form').addEventListener('submit', (event) => {
  event.preventDefault()
  const value = $('open-input').value.trim()
  if (!value) return
  location.hash = /^[0-9a-f]{64}$/i.test(value) ? `#bzz/${value}` : `#${value.replace(/^#/, '')}`
  boot()
})

window.addEventListener('hashchange', boot)
boot()
