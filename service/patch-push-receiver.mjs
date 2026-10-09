// Makes @eneris/push-receiver 4.3.0 verify mtalk.google.com's certificate.
// Upstream builds a bare tls.TLSSocket and calls .connect() on it, which skips
// certificate and hostname checks, then sends the GCM login token. tls.connect()
// verifies by default and holds writes until the handshake has passed.
// No upstream release fixes this yet (4.4.0 has the same code).
//
// install.sh runs this after `npm ci`; the service refuses to start unpatched.
// Usage: node patch-push-receiver.mjs <node_modules dir>

import { createHash } from 'node:crypto'
import { readFileSync, renameSync, writeFileSync } from 'node:fs'
import { join } from 'node:path'

const file = join(process.argv[2] || 'node_modules', '@eneris', 'push-receiver', 'dist', 'client.js')
const upstreamSha256 = '617db74b25dbc3f3e43f4c8302e5ea953252d4ef70c5ddcd3ed2335d476070d0'

const edits = [
  [
    "        this.#socket = new tls_1.default.TLSSocket(null);\n",
    "        this.#socket = tls_1.default.connect({ host: HOST, port: PORT, servername: HOST });\n",
  ],
  [
    "        this.#socket.on('connect', () => this.#handleSocketConnect());\n",
    "        this.#socket.on('secureConnect', () => this.#handleSocketConnect());\n",
  ],
  [
    "        this.#socket.connect({ host: HOST, port: PORT });\n",
    "",
  ],
]

export function isPatched(source) {
  return !source.includes('TLSSocket(null)') && source.includes('servername: HOST')
}

const source = readFileSync(file, 'utf8')
if (isPatched(source)) process.exit(0)

const sha = createHash('sha256').update(source).digest('hex')
if (sha !== upstreamSha256) {
  console.error(`patch-push-receiver: ${file} is not the reviewed 4.3.0 build (sha256 ${sha})`)
  process.exit(1)
}

let next = source
for (const [from, to] of edits) {
  if (next.split(from).length !== 2) {
    console.error(`patch-push-receiver: expected exactly one match for ${JSON.stringify(from.trim())}`)
    process.exit(1)
  }
  next = next.replace(from, to)
}
if (!isPatched(next)) process.exit(1)

writeFileSync(file + '.tmp', next)
renameSync(file + '.tmp', file)
