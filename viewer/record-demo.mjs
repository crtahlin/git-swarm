// Record a demo of the viewer browsing a repository stored on Swarm.
//
//   node record-demo.mjs <url> <out.mp4>
//
// Drives a real Chrome over the DevTools protocol, captures frames while the
// page is used the way a person would use it, and assembles them with ffmpeg.
// Everything it records is the live page reading real data from Swarm — there is
// no scripted mock, so a broken build produces a broken video rather than a
// convincing one.

import { execFile } from 'node:child_process'
import { mkdtempSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { promisify } from 'node:util'
import puppeteer from 'puppeteer-core'

const run = promisify(execFile)

const URL_ = process.argv[2] || 'http://localhost:1633/bzz/09a5c8924336625cad2dc0be13c0dd74f8b5d1d33fb9ba5b057340893188a19c/'
const OUT = process.argv[3] || 'demo.mp4'
const CHROME = process.env.CHROME || '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome'
const FPS = 12

const frames = mkdtempSync(join(tmpdir(), 'swarm-git-frames-'))
let frame = 0

const browser = await puppeteer.launch({
  executablePath: CHROME,
  headless: 'new',
  args: ['--no-sandbox', '--disable-gpu', '--force-device-scale-factor=1'],
  defaultViewport: { width: 1280, height: 800 },
})

const page = await browser.newPage()

// Capture continuously in the background so the video shows real timing —
// including how long Swarm actually takes to serve the packfiles.
let recording = true
const capture = (async () => {
  while (recording) {
    const shot = await page.screenshot({ type: 'png' }).catch(() => null)
    if (shot) writeFileSync(join(frames, `f${String(frame++).padStart(5, '0')}.png`), shot)
    await new Promise((r) => setTimeout(r, 1000 / FPS))
  }
})()

const hold = (ms) => new Promise((r) => setTimeout(r, ms))

// Click by visible text, the way a viewer would be used.
async function clickText(selector, text) {
  const handle = await page.evaluateHandle(
    (sel, want) => [...document.querySelectorAll(sel)].find((el) => el.textContent.trim() === want),
    selector, text,
  )
  const element = handle.asElement()
  if (!element) throw new Error(`nothing matching ${selector} with text "${text}"`)
  await element.click()
}

try {
  console.log('recording', URL_)
  await page.goto(URL_, { waitUntil: 'domcontentloaded' })

  // The repository loads: feed → manifest → packfiles → rendered.
  await page.waitForSelector('#repo-name', { timeout: 120000 })
  await page.waitForFunction(() => document.querySelector('#repo-name')?.textContent?.trim(), { timeout: 120000 })
  await hold(2500)

  await page.evaluate(() => window.scrollTo({ top: 420, behavior: 'smooth' }))
  await hold(2200)
  await page.evaluate(() => window.scrollTo({ top: 0, behavior: 'smooth' }))
  await hold(1200)

  await clickText('.entry-name', 'docs')            // into a directory
  await hold(2200)
  await clickText('.entry-name', 'addressing.md')   // open a file, rendered as markdown
  await hold(3200)
  await page.evaluate(() => window.scrollTo({ top: 700, behavior: 'smooth' }))
  await hold(2600)

  await page.goto(URL_, { waitUntil: 'domcontentloaded' })  // back to the repository root
  await page.waitForSelector('#repo-name', { timeout: 120000 })
  await hold(2000)
} finally {
  recording = false
  await capture
  await browser.close()
}

console.log(`captured ${frame} frames, encoding…`)
await run('ffmpeg', [
  '-y', '-framerate', String(FPS), '-i', join(frames, 'f%05d.png'),
  '-vf', 'scale=1280:-2:flags=lanczos,format=yuv420p',
  '-c:v', 'libx264', '-preset', 'slow', '-crf', '26', '-movflags', '+faststart',
  OUT,
])
rmSync(frames, { recursive: true, force: true })
console.log('wrote', OUT)
