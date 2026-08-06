// Build the viewer into viewer/dist.
//
// Two files, both relative-path-free: a page published to Swarm is served from
// /bzz/<hash>/, and absolute paths would resolve to the gateway root instead of
// the page. That is the classic way an SPA breaks on a content-addressed host.

import { build } from 'esbuild'
import { copyFileSync, mkdirSync, rmSync } from 'node:fs'

rmSync('dist', { recursive: true, force: true })
mkdirSync('dist', { recursive: true })

await build({
  entryPoints: ['src/app.js'],
  bundle: true,
  minify: true,
  format: 'iife',
  target: ['es2020'],
  outfile: 'dist/app.js',
  define: {
    'process.env.NODE_ENV': '"production"',
    global: 'globalThis',
    // Which repository this build opens when no fragment is given. Any deployment
    // can bake its own; the landing form is still one click away.
    __DEFAULT_TARGET__: JSON.stringify(process.env.VIEWER_DEFAULT_TARGET || ''),
  },
  mainFields: ['module', 'main'],
  inject: ['./src/node-shims.js'],
  logLevel: 'info',
})

copyFileSync('src/index.html', 'dist/index.html')
console.log('viewer built into dist/')
