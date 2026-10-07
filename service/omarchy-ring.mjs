// omarchy-ring service: receives Ring events and writes them to
// ~/.local/state/omarchy-ring (state.json, snapshots/, live/), which the bar
// widget draws. The widget asks for things by writing request.json there.

import { RingApi } from 'ring-client-api'
import { enableDebug, useLogger } from 'ring-client-api/util'
import { spawn } from 'node:child_process'
import {
  existsSync, mkdirSync, readFileSync, readdirSync, renameSync, statSync,
  unlinkSync, writeFileSync,
} from 'node:fs'
import { homedir } from 'node:os'
import { join } from 'node:path'
import { notify } from './notify.mjs'

const home = homedir()
const configDir = join(process.env.XDG_CONFIG_HOME || join(home, '.config'), 'omarchy-ring')
const stateDir = join(process.env.XDG_STATE_HOME || join(home, '.local', 'state'), 'omarchy-ring')
const snapshotDir = join(stateDir, 'snapshots')
const tokenPath = join(configDir, 'refresh-token')
const statePath = join(stateDir, 'state.json')
const liveDir = join(stateDir, 'live')
const requestPath = join(stateDir, 'request.json')
const soundsDir = join(configDir, 'sounds')
const settingsPath = join(configDir, 'settings.json')

mkdirSync(snapshotDir, { recursive: true })
mkdirSync(liveDir, { recursive: true })

const config = loadConfig()

function loadConfig() {
  const defaults = { cameras: {}, loginUrl: 'https://account.ring.com/account/dashboard', keepDays: 7, maxEvents: 200, desktopNotifications: true,
    doorbellSound: '', doorbellPopup: true, doorbellLiveSeconds: 30,
    motionNotifications: true,
    liveSeconds: 30 }
  try {
    return { ...defaults, ...JSON.parse(readFileSync(join(configDir, 'config.json'), 'utf8')) }
  } catch (e) {
    if (e.code !== 'ENOENT') log('Ignoring unreadable config.json:', e.message)
    return defaults
  }
}

function settings() {
  try {
    return { ...config, ...JSON.parse(readFileSync(settingsPath, 'utf8')) }
  } catch {
    return config
  }
}

function log(...args) {
  console.log(new Date().toISOString(), ...args)
}

// The library logs through the silent `debug` package by default, which hides
// real errors. Route them to the journal, minus the "UNKNOWN MESSAGE" noise
// that every live view produces.
let skipUnknownBody = false
useLogger({
  logInfo: (...m) => { if (process.env.OMARCHY_RING_DEBUG) log('[ring]', ...m) },
  logError: (...m) => {
    if (m[0] === 'UNKNOWN MESSAGE') { skipUnknownBody = true; return }
    if (skipUnknownBody) { skipUnknownBody = false; if (m[0]?.method) return }
    log('[ring error]', ...m.map((x) => x?.stack || x?.message || x))
  },
})
if (process.env.OMARCHY_RING_DEBUG) enableDebug()

let state = readState()

function readState() {
  try {
    const parsed = JSON.parse(readFileSync(statePath, 'utf8'))
    const events = (parsed.events || []).map((e) => (e.kind === 'button_press' ? { ...e, kind: 'ding' } : e))
    return { version: 1, status: {}, cameras: [], ...parsed, events, live: null }
  } catch {
    return { version: 1, status: {}, cameras: [], events: [] }
  }
}

let writeTimer = null

function scheduleWrite() {
  if (writeTimer) return
  writeTimer = setTimeout(() => {
    writeTimer = null
    writeState()
  }, 150)
}

// Temp file + rename, so the widget never reads half a file.
function writeState() {
  prune()
  state.updatedAt = new Date().toISOString()
  writeFileSync(statePath + '.tmp', JSON.stringify(state, null, 2))
  renameSync(statePath + '.tmp', statePath)
}

function setStatus(kind, message = '') {
  state.status = { state: kind, message, at: new Date().toISOString() }
  scheduleWrite()
}

function prune() {
  const cutoff = Date.now() - config.keepDays * 24 * 3600 * 1000
  state.events = state.events
    .filter((e) => new Date(e.at).getTime() >= cutoff)
    .sort((a, b) => new Date(b.at) - new Date(a.at))
    .slice(0, config.maxEvents)

  const keep = new Set()
  for (const e of state.events) if (e.snapshot) keep.add(e.snapshot)
  for (const c of state.cameras) if (c.snapshot) keep.add(c.snapshot)
  for (const file of readdirSync(snapshotDir)) {
    if (!keep.has(file)) {
      try { unlinkSync(join(snapshotDir, file)) } catch {}
    }
  }
}

function cameraUrl(name, locationId, deviceId) {
  for (const [configured, url] of Object.entries(config.cameras || {})) {
    if (configured.toLowerCase() === String(name).toLowerCase()) return url
  }
  if (locationId && deviceId)
    return `https://account.ring.com/account/dashboard?l=${locationId}&lv_d=${deviceId}`
  return config.loginUrl
}

function upsertCamera(camera) {
  const entry = {
    id: camera.id,
    name: camera.name,
    url: cameraUrl(camera.name, camera.data.location_id, camera.id),
    battery: camera.batteryLevel,
    offline: camera.isOffline,
    kind: String(camera.deviceType || ''),
    doorbell: !!camera.isDoorbot,
  }
  const existing = state.cameras.find((c) => c.id === entry.id)
  if (existing) Object.assign(existing, entry)
  else state.cameras.push({ ...entry, snapshot: '', snapshotAt: '' })
  scheduleWrite()
}

const KIND_TEXT = {
  ding: 'Someone is at your',
  motion: 'There is motion at your',
  human: 'There is a person at your',
  other_motion: 'There is motion at your',
  on_demand: 'Live view started on',
}

function eventText(kind, cameraName) {
  return `${KIND_TEXT[kind] || 'Event at your'} ${cameraName}`
}

function addEvent(event) {
  if (state.events.some((e) => e.id === event.id)) return false
  state.events.push(event)
  scheduleWrite()
  return true
}

function safeFileName(id) {
  return String(id).replace(/[^A-Za-z0-9_-]/g, '_') + '.jpg'
}

function saveSnapshot(eventId, cameraId, buffer) {
  const file = safeFileName(eventId)
  writeFileSync(join(snapshotDir, file), buffer)
  const event = state.events.find((e) => e.id === eventId)
  if (event) event.snapshot = file
  const camera = state.cameras.find((c) => c.id === cameraId)
  if (camera) {
    camera.snapshot = file
    camera.snapshotAt = new Date().toISOString()
  }
  scheduleWrite()
  return file
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms))

// The event image is uploaded a moment after the push arrives, so retry.
async function fetchSnapshot(camera, uuid) {
  if (uuid) {
    for (const wait of [1500, 3000, 6000]) {
      await sleep(wait)
      try {
        const buffer = await camera.getSnapshotByUuid(uuid)
        if (buffer && buffer.length > 0) return buffer
      } catch {}
    }
  }
  try {
    return await camera.getSnapshot()
  } catch (e) {
    log(`No snapshot for ${camera.name}: ${e.message}`)
    return null
  }
}

async function handleNotification(camera, notification) {
  const ding = notification?.data?.event?.ding || {}
  const id = String(ding.id || notification?.analytics?.server_correlation_id || Date.now())
  // Ring has sent doorbell presses as both "ding" and "button_press".
  const category = String(notification?.android_config?.category || '')
  const isDoorbell = category === 'com.ring.pn.live-event.ding' || ['ding', 'button_press'].includes(ding.subtype)
  const kind = isDoorbell ? 'ding'
    : String(ding.detection_type === 'human' ? 'human' : ding.subtype || 'motion')
  const at = ding.created_at
    ? new Date(ding.created_at).toISOString()
    : new Date(notification?.analytics?.triggered_at || Date.now()).toISOString()
  const text = String(notification?.android_config?.body || eventText(kind, camera.name))

  const event = { id, cameraId: camera.id, camera: camera.name, kind, text, at, snapshot: '' }
  if (!addEvent(event)) return
  log(`Event ${kind} on ${camera.name}: ${text}`)

  const url = cameraUrl(camera.name, camera.data.location_id, camera.id)
  const current = settings()
  if (kind === 'ding' ? !current.doorbellPopup : current.motionNotifications) notifyDesktop(camera.name, text, url, kind === 'ding')
  if (kind === 'ding') onDoorbell(camera)

  const buffer = await fetchSnapshot(camera, notification?.img?.snapshot_uuid)
  if (buffer) saveSnapshot(id, camera.id, buffer)
}

async function currentSnapshot(camera) {
  try {
    const buffer = await camera.getSnapshot()
    if (!buffer || buffer.length === 0) return
    const file = safeFileName('cam-' + camera.id)
    writeFileSync(join(snapshotDir, file), buffer)
    const entry = state.cameras.find((c) => c.id === camera.id)
    if (entry) {
      entry.snapshot = file
      entry.snapshotAt = new Date().toISOString()
    }
    scheduleWrite()
  } catch (e) {
    log(`No current snapshot for ${camera.name}: ${e.message}`)
  }
}

async function backfill(camera) {
  try {
    const { events } = await camera.getEvents({ limit: 20 })
    for (const e of events || []) {
      addEvent({
        id: String(e.ding_id_str || e.ding_id),
        cameraId: camera.id,
        camera: camera.name,
        kind: String(e.kind || 'motion'),
        text: eventText(String(e.kind || 'motion'), camera.name),
        at: new Date(e.created_at).toISOString(),
        snapshot: '',
      })
    }
  } catch (e) {
    log(`Could not load history for ${camera.name}: ${e.message}`)
  }
}

function notifyDesktop(title, body, url, urgent = false) {
  if (!config.desktopNotifications) return
  notify({
    appName: 'Ring', icon: 'camera-web', summary: title, body,
    urgency: urgent ? 2 : 1,
    actions: [['default', 'Open camera']],
    onAction: (key) => { if (key === 'default') openUrl(url) },
  }).catch((e) => log('Desktop notification failed:', e.message))
}

const BROWSERS = ['google-chrome-stable', 'chromium']

function browserCommand(url) {
  const browser = String(settings().browser || 'default')
  return BROWSERS.includes(browser) ? ['uwsm-app', '--', browser, url] : ['omarchy-launch-browser', url]
}

function openUrl(url) {
  if (!/^https:\/\/[A-Za-z0-9.-]+\.ring\.com\/[A-Za-z0-9/?&=._%-]*$/.test(url)) {
    log('Refusing to open unexpected URL:', url)
    return
  }
  spawn('systemd-run', ['--user', '--quiet', '--collect', ...browserCommand(url)], { stdio: 'ignore' })
    .on('error', (e) => log('Could not open browser:', e.message))
}

// Sound, browser and widget calls run in their own unit, outside the
// service's sandbox.
function runInSession(args) {
  spawn('systemd-run', ['--user', '--quiet', '--collect', ...args], { stdio: 'ignore' })
    .on('error', (e) => log(`Could not run ${args[0]}:`, e.message))
}

const SOUND_FILE = /^[^/'\\]+\.(ogg|oga|wav|flac|mp3|m4a|opus)$/i

function doorbellSoundPath() {
  let files = []
  try { files = readdirSync(soundsDir).filter((f) => SOUND_FILE.test(f)).sort() } catch {}
  const chosen = String(settings().doorbellSound || '')
  if (chosen === 'none') return ''
  if (files.includes(chosen)) return join(soundsDir, chosen)
  return files.length > 0 ? join(soundsDir, files[0]) : ''
}

function playDoorbellSound() {
  const path = doorbellSoundPath()
  if (!path) return
  if (/\.(ogg|oga|wav|flac)$/i.test(path)) runInSession(['pw-play', path])
  else runInSession(['mpv', '--no-video', '--really-quiet', '--no-config', path])
}

// Only the camera id goes on the command line; the widget looks up the name.
function showDoorbellPopup(cameraId) {
  runInSession(['omarchy-shell', 'nnathan.ring', 'doorbell', String(Number(cameraId) || 0)])
}

function onDoorbell(camera) {
  const current = settings()
  playDoorbellSound()
  if (current.doorbellPopup) showDoorbellPopup(camera.id)
  if (Number(current.doorbellLiveSeconds) > 0) {
    startLive(camera, Number(current.doorbellLiveSeconds)).catch((e) => log('Live view failed:', e.message))
  }
}

let live = null   // { camera, session, until, timer }
let ringApi = null

function setLive(fields) {
  state.live = fields ? { ...(state.live || {}), ...fields } : null
  scheduleWrite()
}

async function startLive(camera, seconds) {
  const until = Date.now() + seconds * 1000
  if (live && live.camera.id === camera.id) {
    live.until = Math.max(live.until, until)
    clearTimeout(live.timer)
    live.timer = setTimeout(stopLive, live.until - Date.now())
    setLive({ until: new Date(live.until).toISOString() })
    return
  }
  if (live) stopLive()

  const file = camera.id + '.jpg'
  const current = { camera, session: null, until, timer: null }
  live = current
  setLive({ cameraId: camera.id, camera: camera.name, file, state: 'starting', frames: 0,
    startedAt: new Date().toISOString(), until: new Date(until).toISOString(), message: '' })
  log(`Live view of ${camera.name} for ${seconds}s.`)
  current.timer = setTimeout(stopLive, seconds * 1000)

  let pending = Buffer.alloc(0)
  let frames = 0
  const target = join(liveDir, file)
  const onData = (chunk) => {
    pending = Buffer.concat([pending, chunk])
    for (;;) {
      const start = pending.indexOf(Buffer.from([0xff, 0xd8]))
      if (start < 0) { pending = Buffer.alloc(0); return }
      const end = pending.indexOf(Buffer.from([0xff, 0xd9]), start + 2)
      if (end < 0) { pending = pending.subarray(start); return }
      const frame = pending.subarray(start, end + 2)
      pending = pending.subarray(end + 2)
      if (live !== current) return
      writeFileSync(target + '.tmp', frame)
      renameSync(target + '.tmp', target)
      frames++
      if (frames === 1 || frames % 15 === 0) setLive({ state: 'streaming', frames, frameAt: new Date().toISOString() })
    }
  }

  try {
    const session = await camera.streamVideo({
      // Ring sends up to 1440p30. ffmpeg's default thread-per-core decoding
      // holds ~270 MB of buffers; two threads keep up at about half.
      input: ['-threads', '2'],
      audio: ['-an'],
      video: ['-vf', 'fps=3,scale=960:-2', '-c:v', 'mjpeg', '-q:v', '5'],
      output: ['-f', 'image2pipe', 'pipe:1'],
      stdoutCallback: onData,
    })
    if (live !== current) { session.stop(); return }
    current.session = session
    session.onCallEnded.subscribe(() => {
      if (live === current) stopLive('ended')
    })
  } catch (e) {
    if (live === current) {
      clearTimeout(current.timer)
      live = null
      setLive({ state: 'error', message: 'Could not start the live view: ' + e.message })
    }
    throw e
  }
}

function stopLive(reason = 'done') {
  const current = live
  if (!current) return
  live = null
  clearTimeout(current.timer)
  try { current.session?.stop() } catch {}
  setLive({ state: 'ended', endedAt: new Date().toISOString() })
  log(`Live view of ${current.camera.name} stopped (${reason}).`)
  setTimeout(reapFfmpeg, 3000)
}

// ring-client-api stops ffmpeg by pausing its output and sending SIGTERM;
// ffmpeg then blocks on the full pipe and never exits, buffering video in
// memory. Kill any of ours still running once no live view is active.
function reapFfmpeg() {
  if (live) return
  for (const entry of readdirSync('/proc')) {
    if (!/^\d+$/.test(entry)) continue
    let stat
    try { stat = readFileSync(`/proc/${entry}/stat`, 'utf8') } catch { continue }
    const comm = stat.slice(stat.indexOf('(') + 1, stat.lastIndexOf(')'))
    const ppid = Number(stat.slice(stat.lastIndexOf(')') + 2).split(' ')[1])
    if (comm === 'ffmpeg' && ppid === process.pid) {
      try {
        process.kill(Number(entry), 'SIGKILL')
        log(`Killed leftover ffmpeg ${entry}.`)
      } catch {}
    }
  }
}
setInterval(reapFfmpeg, 60000)

function logout() {
  log('Logging out.')
  stopLive('logging out')
  try { unlinkSync(tokenPath) } catch {}
  try { ringApi?.disconnect() } catch {}
  setStatus('login_needed', 'Logged out. Log in to Ring to start watching your cameras again.')
  writeState()
  waitForNewToken()
}

function testDoorbell(camera) {
  log(`Doorbell test on ${camera.name}.`)
  if (!settings().doorbellPopup)
    notifyDesktop(camera.name, `Doorbell test on your ${camera.name}`, cameraUrl(camera.name, camera.data.location_id, camera.id), true)
  onDoorbell(camera)
}

function watchRequests(cameras) {
  let lastAt = ''
  try { lastAt = JSON.parse(readFileSync(requestPath, 'utf8')).at || '' } catch {}
  setInterval(() => {
    let request
    try { request = JSON.parse(readFileSync(requestPath, 'utf8')) } catch { return }
    if (!request || !request.at || request.at === lastAt) return
    lastAt = request.at
    if (Date.now() - new Date(request.at).getTime() > 15000) return
    if (request.action === 'stop') return stopLive('stopped from panel')
    if (request.action === 'logout') return logout()
    const camera = cameras.find((c) => c.id === Number(request.cameraId))
    if (!camera) return log(`Request ${request.action} for unknown camera`, request.cameraId)
    if (request.action === 'live') {
      startLive(camera, Number(settings().liveSeconds) || 30).catch((e) => log('Live view failed:', e.message))
    }
    if (request.action === 'test-doorbell') testDoorbell(camera)
  }, 1000)
}

function readToken() {
  try {
    return readFileSync(tokenPath, 'utf8').trim()
  } catch {
    return ''
  }
}

function saveToken(token) {
  writeFileSync(tokenPath + '.tmp', token, { mode: 0o600 })
  renameSync(tokenPath + '.tmp', tokenPath)
}

function tokenMtime() {
  try { return statSync(tokenPath).mtimeMs } catch { return 0 }
}

async function waitForNewToken(timeoutMs = Infinity) {
  const seen = tokenMtime()
  const deadline = Date.now() + timeoutMs
  while (Date.now() < deadline) {
    await sleep(5000)
    if (tokenMtime() !== seen && readToken() !== '') {
      log('New token found, restarting.')
      process.exit(75)
    }
  }
  process.exit(1)
}

async function simulate(cameraName, kind = 'motion') {
  const camera = state.cameras.find((c) => c.name.toLowerCase() === String(cameraName).toLowerCase())
  const name = camera ? camera.name : cameraName
  const event = {
    id: 'sim-' + Date.now(),
    cameraId: camera ? camera.id : 0,
    camera: name,
    kind,
    text: eventText(kind, name),
    at: new Date().toISOString(),
    snapshot: '',
    simulated: true,
  }
  addEvent(event)
  writeState()
  notifyDesktop(name, event.text, camera ? camera.url : cameraUrl(name), kind === 'ding')
  if (kind === 'ding') {
    playDoorbellSound()
    if (settings().doorbellPopup) showDoorbellPopup(camera ? camera.id : 0)
  }
  log(`Simulated ${kind} on ${name}. Click the notification within 15s to test opening the camera.`)
  setTimeout(() => process.exit(0), 15000)
}

async function main() {
  if (!existsSync(tokenPath) || readToken() === '') {
    setStatus('login_needed', 'Run omarchy-ring-login in a terminal to connect your Ring account.')
    writeState()
    log('No refresh token yet. Waiting for omarchy-ring-login.')
    return waitForNewToken()
  }

  setStatus('connecting', 'Connecting to Ring…')

  const api = ringApi = new RingApi({
    refreshToken: readToken(),
    controlCenterDisplayName: 'omarchy-ring',
    cameraStatusPollingSeconds: 300,
    avoidSnapshotBatteryDrain: true,
    ffmpegPath: '/usr/bin/ffmpeg',
  })

  // Ring rotates the token on use, and push credentials are stored inside it.
  // Missing a save means logging in again.
  api.onRefreshTokenUpdated.subscribe(({ newRefreshToken }) => {
    try {
      saveToken(newRefreshToken)
    } catch (e) {
      log('Could not save refreshed token:', e.message)
    }
  })

  let cameras
  try {
    cameras = await api.getCameras()
  } catch (e) {
    const message = String(e?.message || e)
    // Typically a Shared User: see dgreif/ring#1808.
    if (/does not have any associated locations/i.test(message)) {
      setStatus('no_access', 'Logged in, but this Ring account has no cameras. Shared Users currently can\'t see cameras through this API; log in with the account that owns them.')
      writeState()
      log('No locations on this account yet. Checking again in 2 minutes.')
      api.disconnect()
      return waitForNewToken(120000)
    }
    if (/refresh token is not valid|failed to fetch oauth token|2fa/i.test(message)) {
      setStatus('login_needed', 'Ring login expired. Run omarchy-ring-login in a terminal.')
      writeState()
      log('Login needed:', message)
      api.disconnect()
      return waitForNewToken()
    }
    setStatus('error', 'Could not reach Ring. Retrying shortly.')
    writeState()
    log('Startup failed:', message)
    process.exit(1)
  }

  const ids = new Set(cameras.map((c) => c.id))
  state.cameras = state.cameras.filter((c) => ids.has(c.id))

  for (const camera of cameras) {
    upsertCamera(camera)
    camera.onData.subscribe(() => upsertCamera(camera))
    camera.onNewNotification.subscribe((n) => {
      handleNotification(camera, n).catch((e) => log('Event handling failed:', e.message))
    })
  }

  watchRequests(cameras)
  log(`Watching ${cameras.map((c) => `${c.name} (${c.deviceType}${c.isDoorbot ? ', doorbell' : ''})`).join(', ') || 'no cameras'}.`)
  setStatus('ok')

  for (const camera of cameras) await backfill(camera)
  for (const camera of cameras) await currentSnapshot(camera)
  scheduleWrite()

  const shutdown = () => {
    log('Stopping.')
    stopLive('shutting down')
    api.disconnect()
    if (writeTimer) { clearTimeout(writeTimer); writeState() }
    process.exit(0)
  }
  process.on('SIGTERM', shutdown)
  process.on('SIGINT', shutdown)
}

const args = process.argv.slice(2)
if (args[0] === '--simulate') {
  simulate(args[1] || 'Front Door', args[2] || 'motion')
} else {
  main().catch((e) => {
    log('Fatal:', e?.stack || e)
    process.exit(1)
  })
}
