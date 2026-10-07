// Desktop notifications over the session bus, without notify-send: a child
// process would carry the camera name and event text in its argv, which any
// user on the machine can read from /proc while it waits for a click.
// Only what Notify and its two signals need of the D-Bus wire format.

import { createConnection } from 'node:net'

const NOTIFICATIONS = 'org.freedesktop.Notifications'
const NOTIFICATIONS_PATH = '/org/freedesktop/Notifications'
const ACTION_WAIT_MS = 10 * 60 * 1000

class Writer {
  constructor() { this.parts = []; this.pos = 0 }
  push(b) { this.parts.push(b); this.pos += b.length }
  align(n) { const pad = (n - (this.pos % n)) % n; if (pad) this.push(Buffer.alloc(pad)) }
  byte(v) { this.push(Buffer.from([v])) }
  u32(v) { this.align(4); const b = Buffer.alloc(4); b.writeUInt32LE(v); this.push(b) }
  i32(v) { this.align(4); const b = Buffer.alloc(4); b.writeInt32LE(v); this.push(b) }
  str(s) { const b = Buffer.from(String(s), 'utf8'); this.u32(b.length); this.push(b); this.byte(0) }
  sig(s) { const b = Buffer.from(s, 'latin1'); this.byte(b.length); this.push(b); this.byte(0) }
  // The length excludes the padding between it and the first element.
  array(elementAlign, write) {
    this.u32(0)
    const length = this.parts[this.parts.length - 1]
    this.align(elementAlign)
    const start = this.pos
    write()
    length.writeUInt32LE(this.pos - start)
  }
  buffer() { return Buffer.concat(this.parts) }
}

class Reader {
  constructor(b, le) { this.b = b; this.le = le; this.pos = 0 }
  align(n) { this.pos += (n - (this.pos % n)) % n }
  byte() { return this.b[this.pos++] }
  u32() {
    this.align(4)
    const v = this.le ? this.b.readUInt32LE(this.pos) : this.b.readUInt32BE(this.pos)
    this.pos += 4
    return v
  }
  str() { const n = this.u32(); const s = this.b.toString('utf8', this.pos, this.pos + n); this.pos += n + 1; return s }
  sig() { const n = this.byte(); const s = this.b.toString('latin1', this.pos, this.pos + n); this.pos += n + 1; return s }
}

function methodCall(serial, { dest, path, iface, member, sig = '' }, writeBody) {
  const body = new Writer()
  if (writeBody) writeBody(body)
  const bodyBuf = body.buffer()
  const h = new Writer()
  h.byte(0x6c); h.byte(1); h.byte(0); h.byte(1) // little endian, method call, no flags, v1
  h.u32(bodyBuf.length)
  h.u32(serial)
  const field = (code, type, write) => { h.align(8); h.byte(code); h.sig(type); write() }
  h.array(8, () => {
    field(1, 'o', () => h.str(path))
    field(2, 's', () => h.str(iface))
    field(3, 's', () => h.str(member))
    field(6, 's', () => h.str(dest))
    if (sig) field(8, 'g', () => h.sig(sig))
  })
  h.align(8)
  return Buffer.concat([h.buffer(), bodyBuf])
}

function parseMessage(msg) {
  const le = msg[0] === 0x6c
  const r = new Reader(msg, le)
  r.pos = 1
  const type = r.byte()
  r.pos = 12
  const end = 16 + r.u32()
  const fields = {}
  while (r.pos < end) {
    r.align(8)
    const code = r.byte()
    const sig = r.sig()
    fields[code] = sig === 'g' ? r.sig() : sig === 'o' || sig === 's' ? r.str() : r.u32()
  }
  r.align(8)
  return { type, fields, body: new Reader(msg.subarray(r.pos), le) }
}

function busPath() {
  const address = process.env.DBUS_SESSION_BUS_ADDRESS || ''
  for (const entry of address.split(';')) {
    const m = entry.match(/^unix:(?:.*,)?path=([^,]+)/)
    if (m) return decodeURIComponent(m[1])
  }
  return `${process.env.XDG_RUNTIME_DIR || `/run/user/${process.getuid()}`}/bus`
}

let bus = null // { socket, serial, pending }
let connecting = null
const waiting = new Map() // notification id -> { onAction, timer }

function forget(id) {
  const entry = waiting.get(id)
  if (!entry) return
  clearTimeout(entry.timer)
  waiting.delete(id)
}

function onMessage(msg) {
  const { type, fields, body } = parseMessage(msg)
  if (type === 2 || type === 3) {
    const call = bus?.pending.get(fields[5])
    if (!call) return
    bus.pending.delete(fields[5])
    if (type === 2) call.resolve(body)
    else call.reject(new Error(`${fields[4] || 'D-Bus error'}${fields[8]?.startsWith('s') ? ': ' + body.str() : ''}`))
  } else if (type === 4 && fields[2] === NOTIFICATIONS) {
    const id = body.u32()
    if (fields[3] === 'ActionInvoked') {
      const entry = waiting.get(id)
      const key = body.str()
      forget(id)
      entry?.onAction(key)
    } else if (fields[3] === 'NotificationClosed') {
      forget(id)
    }
  }
}

function call(spec, writeBody) {
  const serial = ++bus.serial
  return new Promise((resolve, reject) => {
    bus.pending.set(serial, { resolve, reject })
    bus.socket.write(methodCall(serial, spec, writeBody))
  })
}

function connect() {
  if (bus) return Promise.resolve()
  if (connecting) return connecting
  connecting = new Promise((resolve, reject) => {
    const socket = createConnection(busPath())
    let buffer = Buffer.alloc(0)
    let authed = false
    const fail = (e) => {
      socket.destroy()
      reject(e)
    }
    socket.on('connect', () => {
      const uid = Buffer.from(String(process.getuid())).toString('hex')
      socket.write(`\0AUTH EXTERNAL ${uid}\r\n`)
    })
    socket.on('data', (chunk) => {
      buffer = Buffer.concat([buffer, chunk])
      if (!authed) {
        const eol = buffer.indexOf('\r\n')
        if (eol < 0) return
        const line = buffer.toString('latin1', 0, eol)
        buffer = buffer.subarray(eol + 2)
        if (!line.startsWith('OK ')) return fail(new Error(`session bus refused us: ${line}`))
        authed = true
        socket.write('BEGIN\r\n')
        bus = { socket, serial: 0, pending: new Map() }
        const dbus = { dest: 'org.freedesktop.DBus', path: '/org/freedesktop/DBus', iface: 'org.freedesktop.DBus' }
        call({ ...dbus, member: 'Hello' })
          .then(() => call({ ...dbus, member: 'AddMatch', sig: 's' }, (w) => w.str(
            `type='signal',sender='${NOTIFICATIONS}',path='${NOTIFICATIONS_PATH}',interface='${NOTIFICATIONS}'`)))
          .then(resolve, fail)
      }
      while (buffer.length >= 16) {
        const le = buffer[0] === 0x6c
        const bodyLength = le ? buffer.readUInt32LE(4) : buffer.readUInt32BE(4)
        const fieldsLength = le ? buffer.readUInt32LE(12) : buffer.readUInt32BE(12)
        const total = Math.ceil((16 + fieldsLength) / 8) * 8 + bodyLength
        if (buffer.length < total) return
        const msg = buffer.subarray(0, total)
        buffer = buffer.subarray(total)
        try { onMessage(msg) } catch {}
      }
    })
    socket.on('error', fail)
    socket.on('close', () => {
      if (bus?.socket === socket) {
        for (const p of bus.pending.values()) p.reject(new Error('session bus closed'))
        bus = null
      }
      for (const id of [...waiting.keys()]) forget(id)
      reject(new Error('session bus closed'))
    })
  }).finally(() => { connecting = null })
  return connecting
}

// Shows a notification; onAction(key) runs if one of its actions is clicked
// within ten minutes.
export async function notify({ appName, icon = '', summary, body = '', actions = [], urgency = 1, onAction }) {
  await connect()
  const reply = await call(
    { dest: NOTIFICATIONS, path: NOTIFICATIONS_PATH, iface: NOTIFICATIONS, member: 'Notify', sig: 'susssasa{sv}i' },
    (w) => {
      w.str(appName); w.u32(0); w.str(icon); w.str(summary); w.str(body)
      w.array(4, () => { for (const [key, label] of actions) { w.str(key); w.str(label) } })
      w.array(8, () => { w.align(8); w.str('urgency'); w.sig('y'); w.byte(urgency) })
      w.i32(-1)
    })
  const id = reply.u32()
  if (onAction && actions.length > 0) {
    forget(id)
    waiting.set(id, { onAction, timer: setTimeout(() => forget(id), ACTION_WAIT_MS).unref() })
  }
  return id
}
