// Everything that talks to Swarm. Reads go through the gateway endpoint (which
// may be the local node); writes always go through the local node, because a
// public gateway can neither hold a postage batch nor sign a feed update.

import { Bee, EthAddress, PrivateKey, Topic } from '@ethersphere/bee-js'
import { TOPIC_PREFIX } from './config.js'

export function topicFor(repo) {
  return Topic.fromString(TOPIC_PREFIX + repo)
}

export class Swarm {
  constructor(settings) {
    this.settings = settings
    this.read = new Bee(settings.gateway)
    this.write = new Bee(settings.api)
  }

  // ---- reading -------------------------------------------------------------

  /** Latest manifest reference from the feed. Needs /feeds, so a local node. */
  async feedManifestRef(owner, topic) {
    const bee = new Bee(this.settings.api)
    const reader = bee.makeFeedReader(topic, new EthAddress(owner))
    const result = await reader.downloadReference()
    return result.reference.toHex()
  }

  async downloadBytes(reference) {
    const file = await this.read.downloadFile(reference)
    return Buffer.from(file.data.toUint8Array())
  }

  async downloadJson(reference) {
    return JSON.parse((await this.downloadBytes(reference)).toString('utf8'))
  }

  // ---- writing -------------------------------------------------------------

  requireWritable() {
    if (!this.settings.batch) {
      throw new Error(
        'no postage batch configured — pushing needs one.\n' +
          '  git config remote.<name>.swarmBatch <batch-id>   (or set SWARM_BATCH_ID)',
      )
    }
    if (!this.settings.key) {
      throw new Error(
        'no feed signing key configured — pushing needs one.\n' +
          '  git config remote.<name>.swarmKey <hex-private-key>   (or set SWARM_PRIVATE_KEY)',
      )
    }
  }

  /**
   * A Bee node with no peers accepts a deferred file upload instantly and then
   * hangs forever on the feed write, because a feed update has to reach the
   * network. Checking first turns a silent multi-minute hang into an immediate,
   * actionable error — this cost a debugging session to learn.
   */
  async checkNode() {
    const res = await fetch(`${this.settings.api}/topology`, { signal: AbortSignal.timeout(10_000) })
      .catch((err) => {
        throw new Error(`no Bee node at ${this.settings.api}: ${err.message}`)
      })
    const topology = await res.json()

    if (Number(topology.connected ?? 0) === 0) {
      throw new Error(
        `Bee node at ${this.settings.api} has 0 connected peers (network: ${topology.networkAvailability}).\n` +
          '  Uploads would be accepted locally and never reach Swarm, and the feed write would hang.\n' +
          '  Check the node is online and connected, then retry.',
      )
    }
    return topology
  }

  /**
   * Refuse to push onto a batch that cannot carry the data, and say how to fix
   * it. Swarm storage is rented: a silent failure here means the repository
   * quietly stops being retrievable later.
   */
  async checkBatch() {
    const { batch, api, minBatchTtlSeconds } = this.settings
    let info
    try {
      info = await this.write.getPostageBatch(batch)
    } catch (err) {
      throw new Error(`postage batch ${batch.slice(0, 8)}… is not usable on ${api}: ${err.message}`)
    }

    if (!info.usable) throw new Error(`postage batch ${batch.slice(0, 8)}… is not usable yet`)

    const ttl = Number(info.duration?.toSeconds?.() ?? info.batchTTL ?? 0)
    if (ttl > 0 && ttl < minBatchTtlSeconds) {
      throw new Error(
        `postage batch ${batch.slice(0, 8)}… expires in ${Math.round(ttl / 60)} minutes.\n` +
          `  Top it up:  curl -sX PATCH ${api}/stamps/topup/${batch}/<amount>`,
      )
    }

    const used = Number(info.utilization ?? 0)
    const capacity = 2 ** (Number(info.depth) - Number(info.bucketDepth ?? 16))
    const ratio = capacity > 0 ? used / capacity : 0
    if (ratio >= 0.9) {
      const next = Number(info.depth) + 1
      throw new Error(
        `postage batch ${batch.slice(0, 8)}… is ${Math.round(ratio * 100)}% full (depth ${info.depth}).\n` +
          `  Enlarge it:  curl -sX PATCH ${api}/stamps/dilute/${batch}/${next}\n` +
          `  Dilution halves the TTL, so top up as well:\n` +
          `               curl -sX PATCH ${api}/stamps/topup/${batch}/<amount>`,
      )
    }

    return { ttl, ratio }
  }

  async uploadFile(data, name, contentType) {
    const result = await this.write.uploadFile(this.settings.batch, data, name, { contentType })
    return result.reference.toHex()
  }

  async updateFeed(topic, manifestRef) {
    const bee = new Bee(this.settings.api, { signer: new PrivateKey(this.settings.key) })
    const writer = bee.makeFeedWriter(topic, new PrivateKey(this.settings.key))
    await writer.uploadReference(this.settings.batch, manifestRef)
  }

  /**
   * The bzz address that wraps (owner, topic). Public gateways do not serve
   * /feeds, so this is the only way a gateway-only reader can follow the feed.
   * Creating it is idempotent — the same owner and topic always yield the same
   * reference — so it is safe to call on every push.
   */
  async ensureFeedManifest(topic, owner) {
    const ref = await this.write.createFeedManifest(this.settings.batch, topic, new EthAddress(owner))
    return ref.toHex()
  }
}
