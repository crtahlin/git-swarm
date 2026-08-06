// A minimal in-memory filesystem, just large enough for isomorphic-git.
//
// Written by hand rather than pulled in: memfs drags Node built-ins (buffer,
// path, stream, events) into a browser bundle, and IndexedDB-backed filesystems
// stall in some contexts and need storage permissions a viewer should not
// require. Nothing here persists — the repository is rebuilt on every load.

function fsError(code, path) {
  const err = new Error(`${code}: ${path}`)
  err.code = code
  err.path = path
  return err
}

class Stats {
  constructor(kind, size) {
    this.type = kind
    this.mode = kind === 'dir' ? 0o040755 : 0o100644
    this.size = size
    this.ino = 0
    this.mtimeMs = 0
    this.ctimeMs = 0
    this.uid = 1
    this.gid = 1
    this.dev = 1
  }
  isDirectory() { return this.type === 'dir' }
  isFile() { return this.type === 'file' }
  isSymbolicLink() { return false }
}

const norm = (p) => String(p).replace(/\/+/g, '/').replace(/\/$/, '') || '/'
const parentOf = (p) => norm(p).split('/').slice(0, -1).join('/') || '/'

export function createMemFs() {
  // path -> Uint8Array for files, null for directories
  const nodes = new Map([['/', null]])

  const exists = (p) => nodes.has(norm(p))
  const isDir = (p) => nodes.get(norm(p)) === null

  const promises = {
    async readFile(path, options) {
      const p = norm(path)
      if (globalThis.__fslog) globalThis.__fslog.push(`readFile ${p} ${nodes.has(p) ? 'hit' : 'MISS'}`)
      if (!nodes.has(p)) throw fsError('ENOENT', p)
      if (isDir(p)) throw fsError('EISDIR', p)
      const data = nodes.get(p)
      const encoding = typeof options === 'string' ? options : options?.encoding
      return encoding ? new TextDecoder().decode(data) : data
    },

    async writeFile(path, data) {
      const p = norm(path)
      if (!exists(parentOf(p))) throw fsError('ENOENT', parentOf(p))
      const bytes = typeof data === 'string' ? new TextEncoder().encode(data) : new Uint8Array(data)
      nodes.set(p, bytes)
    },

    async unlink(path) {
      const p = norm(path)
      if (!nodes.has(p)) throw fsError('ENOENT', p)
      nodes.delete(p)
    },

    async readdir(path) {
      const p = norm(path)
      if (!nodes.has(p)) throw fsError('ENOENT', p)
      if (!isDir(p)) throw fsError('ENOTDIR', p)
      const prefix = p === '/' ? '/' : p + '/'
      const names = new Set()
      for (const key of nodes.keys()) {
        if (key === p || !key.startsWith(prefix)) continue
        names.add(key.slice(prefix.length).split('/')[0])
      }
      return [...names].sort()
    },

    async mkdir(path, options) {
      const p = norm(path)
      if (nodes.has(p)) throw fsError('EEXIST', p)
      if (!exists(parentOf(p))) {
        if (!options?.recursive) throw fsError('ENOENT', parentOf(p))
        await promises.mkdir(parentOf(p), options)
      }
      nodes.set(p, null)
    },

    async rmdir(path) {
      const p = norm(path)
      if (!nodes.has(p)) throw fsError('ENOENT', p)
      nodes.delete(p)
    },

    async stat(path) {
      const p = norm(path)
      if (!nodes.has(p)) throw fsError('ENOENT', p)
      const value = nodes.get(p)
      return new Stats(value === null ? 'dir' : 'file', value === null ? 0 : value.length)
    },

    async lstat(path) { return promises.stat(path) },

    async readlink(path) { throw fsError('EINVAL', norm(path)) },
    async symlink() { throw fsError('ENOTSUP', 'symlink') },
    async chmod() {},
  }

  return { promises }
}
