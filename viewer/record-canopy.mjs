// Record canopy — the Radicle forge UI — browsing a repository that was
// archived to Swarm, deleted, and restored.
//
//   node record-canopy.mjs <canopy-url> <rid> <out.gif>
//
// The point of the recording is that this is a normal forge: file tree,
// commits, issues, patches. Nothing about it is Swarm-specific. The repository
// it is showing only exists because it came back out of an archive.
//
// Drives real Chrome over the DevTools protocol and captures frames, so a
// broken page produces a broken recording rather than a convincing one.

import { execFile } from 'node:child_process'
import { mkdtempSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { promisify } from 'node:util'
import puppeteer from 'puppeteer-core'

const run = promisify(execFile)

const BASE = process.argv[2] || 'http://localhost:5173'
const RID = process.argv[3]
const OUT = process.argv[4] || 'canopy.gif'
const CHROME = process.env.CHROME || '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome'
const FPS = 10

if (!RID) {
  console.error('usage: node record-canopy.mjs <canopy-url> <rid> <out.gif>')
  process.exit(64)
}

const frames = mkdtempSync(join(tmpdir(), 'canopy-frames-'))
let frame = 0

const browser = await puppeteer.launch({
  executablePath: CHROME,
  headless: 'new',
  args: ['--no-sandbox', '--window-size=1280,880'],
})
const page = await browser.newPage()
await page.setViewport({ width: 1280, height: 880, deviceScaleFactor: 1 })

async function shoot(n = 1) {
  for (let i = 0; i < n; i++) {
    await page.screenshot({ path: join(frames, String(frame++).padStart(5, '0') + '.png') })
  }
}

// Hold on each view long enough to read it. Navigating by hash rather than
// clicking: the routes are the contract, and a moved button should not silently
// turn this into a recording of the same page four times.
async function visit(hash, holdSeconds) {
  await page.goto(`${BASE}/#/${hash}`, { waitUntil: 'networkidle2', timeout: 60000 })
  await new Promise((r) => setTimeout(r, 1500))
  await shoot(FPS * holdSeconds)
}

try {
  await visit(`rad:${RID}`, 4)             // code view, README rendered
  await visit(`rad:${RID}/commits`, 3)     // history that came out of the archive
  await visit(`rad:${RID}/issues`, 2)      // collaborative objects, stored as git
  await visit(`rad:${RID}/patches`, 2)
  await visit(`rad:${RID}`, 2)             // back where we started

  const body = await page.evaluate(() => document.body.innerText)
  if (!body.includes(RID)) {
    throw new Error('the page never showed the repository id; recording would be misleading')
  }

  await run('ffmpeg', [
    '-y', '-framerate', String(FPS), '-i', join(frames, '%05d.png'),
    '-vf', 'scale=960:-1:flags=lanczos,split[a][b];[a]palettegen[p];[b][p]paletteuse',
    '-loop', '0', OUT,
  ])
  console.log(`wrote ${OUT} from ${frame} frames`)
} finally {
  await browser.close()
  rmSync(frames, { recursive: true, force: true })
}
