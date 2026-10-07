// One-time Ring login. Saves the refresh token for the service; the token is
// never printed because it opens the account.

import { RingRestClient } from 'ring-client-api/rest-client'
import { createInterface } from 'node:readline'
import { writeFileSync, renameSync, mkdirSync } from 'node:fs'
import { homedir } from 'node:os'
import { join } from 'node:path'

const configDir = join(process.env.XDG_CONFIG_HOME || join(homedir(), '.config'), 'omarchy-ring')
const tokenPath = join(configDir, 'refresh-token')

function ask(question, { hidden = false } = {}) {
  return new Promise((resolve) => {
    const rl = createInterface({ input: process.stdin, output: process.stdout, terminal: true })
    if (hidden) {
      rl._writeToOutput = (text) => {
        if (text.startsWith(question)) rl.output.write(question)
      }
    }
    rl.question(question, (answer) => {
      rl.close()
      if (hidden) process.stdout.write('\n')
      resolve(answer.trim())
    })
  })
}

console.log('Ring login for omarchy-ring. Use the account that owns the cameras: Ring currently\n' +
  "doesn't show cameras to Shared Users through this API (dgreif/ring#1808).\n")

const email = await ask('Email: ')
const password = await ask('Password: ', { hidden: true })
const client = new RingRestClient({ email, password, controlCenterDisplayName: 'omarchy-ring' })

async function withCode() {
  const code = await ask('2FA code: ')
  try {
    return await client.getAuth(code)
  } catch {
    console.log('That code did not work. Try again.')
    return withCode()
  }
}

let auth
try {
  auth = await client.getCurrentAuth()
} catch (e) {
  if (!client.promptFor2fa) {
    console.error('Login failed:', e?.message || e)
    process.exit(1)
  }
  console.log(client.promptFor2fa)
  auth = await withCode()
}

mkdirSync(configDir, { recursive: true, mode: 0o700 })
writeFileSync(tokenPath + '.tmp', auth.refresh_token, { mode: 0o600 })
renameSync(tokenPath + '.tmp', tokenPath)

console.log(`\nLogged in. Token saved to ${tokenPath} (readable only by you).`)
console.log('The omarchy-ring service picks it up within a few seconds.')
process.exit(0)
