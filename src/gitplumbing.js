// Thin wrappers over git plumbing. The helper deliberately owns no packfile
// logic of its own — git already has all of it, and shelling out keeps the
// format compatible by construction.

import { execFileSync, spawn } from 'node:child_process'
import { createReadStream, createWriteStream } from 'node:fs'

function run(args, options = {}) {
  return execFileSync('git', args, { encoding: 'utf8', maxBuffer: 64 * 1024 * 1024, ...options })
}

export function revParse(ref) {
  try {
    return run(['rev-parse', '--verify', `${ref}^{object}`]).trim()
  } catch {
    return null
  }
}

export function hasObject(sha) {
  try {
    run(['cat-file', '-e', `${sha}^{object}`], { stdio: 'ignore' })
    return true
  } catch {
    return false
  }
}

/** True when `ancestor` is reachable from `descendant` — i.e. the update fast-forwards. */
export function isAncestor(ancestor, descendant) {
  try {
    run(['merge-base', '--is-ancestor', ancestor, descendant], { stdio: 'ignore' })
    return true
  } catch {
    return false
  }
}

export function symbolicHead() {
  try {
    return run(['symbolic-ref', 'HEAD']).trim()
  } catch {
    return 'refs/heads/main'
  }
}

/**
 * Write a packfile containing everything reachable from `tips` but not from
 * `excludes`. `git pack-objects --revs` reads the rev-list arguments from stdin,
 * so the delta is expressed the same way `git rev-list` would express it.
 */
export function packObjects(tips, excludes, outPath) {
  return new Promise((resolve, reject) => {
    const child = spawn('git', ['pack-objects', '--stdout', '--revs', '--delta-base-offset', '--quiet'], {
      stdio: ['pipe', 'pipe', 'pipe'],
    })

    let stderr = ''
    child.stderr.on('data', (d) => (stderr += d))

    const out = createWriteStream(outPath)
    child.stdout.pipe(out)

    // Wait for BOTH the child to exit and the file to finish writing. Resolving
    // on the stream alone reads child.exitCode before the process has exited and
    // rejects with an empty error — which only shows up once a repository is big
    // enough for the two to complete in a different order.
    let exitCode = null
    let streamClosed = false
    const settle = () => {
      if (exitCode === null || !streamClosed) return
      if (exitCode === 0) resolve(outPath)
      else reject(new Error(`git pack-objects exited ${exitCode}: ${stderr.trim() || '(no output)'}`))
    }

    child.on('error', reject)
    out.on('error', reject)
    child.on('close', (code) => { exitCode = code; settle() })
    out.on('close', () => { streamClosed = true; settle() })

    const spec = [...tips, ...excludes.map((sha) => `^${sha}`)].join('\n')
    child.stdin.end(spec + '\n')
  })
}

/**
 * Index a packfile into the local object store. `--fix-thin` completes bases the
 * pack omitted from objects already present, which is why packs must be indexed
 * oldest first.
 */
export function indexPack(packPath) {
  return new Promise((resolve, reject) => {
    const child = spawn('git', ['index-pack', '--fix-thin', '--stdin'], {
      stdio: ['pipe', 'pipe', 'pipe'],
    })

    let stderr = ''
    let stdout = ''
    child.stdout.on('data', (d) => (stdout += d))
    child.stderr.on('data', (d) => (stderr += d))

    child.on('error', reject)
    child.on('close', (code) => {
      if (code === 0) resolve(stdout.trim())
      else reject(new Error(`git index-pack failed: ${stderr.trim()}`))
    })

    createReadStream(packPath).pipe(child.stdin)
  })
}
