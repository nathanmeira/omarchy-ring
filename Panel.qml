import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import qs.Commons
import qs.Ui

// Display only: the omarchy-ring service talks to Ring and writes
// ~/.local/state/omarchy-ring; this watches those files and draws them.
Panel {
  id: root
  moduleName: "nnathan.ring"
  ipcTarget: "nnathan.ring"
  manageIpc: false

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property color track: Style.selectedFillFor(foreground, Color.accent)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  readonly property string home: Quickshell.env("HOME") || ""
  readonly property string stateDir: (Quickshell.env("XDG_STATE_HOME") || home + "/.local/state") + "/omarchy-ring"
  readonly property string configDir: (Quickshell.env("XDG_CONFIG_HOME") || home + "/.config") + "/omarchy-ring"

  readonly property int eventsPerCamera: Math.max(5, Number(setting("eventsPerCamera", 30)))

  property var ring: ({ status: {}, cameras: [], events: [] })
  property var ringConfig: ({ cameras: {} })
  property var seen: ({})

  FileView {
    path: root.stateDir + "/state.json"
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: root.ring = root.parseJson(text(), { status: {}, cameras: [], events: [] })
    onLoadFailed: root.ring = { status: {}, cameras: [], events: [] }
  }

  FileView {
    path: root.configDir + "/config.json"
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: root.ringConfig = root.parseJson(text(), { cameras: {} })
  }

  FileView {
    id: seenFile
    path: root.stateDir + "/seen.json"
    printErrors: false
    onLoaded: root.seen = root.parseJson(text(), {})
  }

  FileView {
    id: requestFile
    path: root.stateDir + "/request.json"
    printErrors: false
  }

  function sendRequest(action, cameraId) {
    requestFile.setText(JSON.stringify({ action: action, cameraId: cameraId, at: new Date().toISOString() }))
  }

  property var ringSettings: ({})

  FileView {
    id: settingsFile
    path: root.configDir + "/settings.json"
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: root.ringSettings = root.parseJson(text(), {})
  }

  function settingValue(key, fallback) {
    var v = ringSettings[key]
    return v === undefined || v === null ? fallback : v
  }

  function saveSetting(key, value) {
    var next = {}
    for (var k in ringSettings) next[k] = ringSettings[k]
    next[key] = value
    ringSettings = next
    settingsFile.setText(JSON.stringify(next, null, 2) + "\n")
  }

  readonly property string soundsDir: configDir + "/sounds"
  property var sounds: []

  Process {
    id: soundsProcess
    command: ["find", root.soundsDir, "-maxdepth", "1", "-type", "f", "-printf", "%f\n"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var names = String(text || "").split("\n").filter(function(n) {
          return /^[^\/'\\]+\.(ogg|oga|wav|flac|mp3|m4a|opus)$/i.test(n)
        })
        names.sort()
        root.sounds = names
      }
    }
  }

  function refreshSounds() { if (!soundsProcess.running) soundsProcess.running = true }

  readonly property string doorbellSound: {
    var chosen = String(settingValue("doorbellSound", ""))
    if (chosen === "none" || sounds.indexOf(chosen) >= 0) return chosen
    return sounds.length > 0 ? sounds[0] : "none"
  }

  function soundLabel(file) {
    var name = String(file).replace(/\.[^.]+$/, "").replace(/[-_]+/g, " ")
    return name.charAt(0).toUpperCase() + name.slice(1)
  }

    // No shell between us and the arguments, so file names stay literal.
  function runArgv(argv) {
    Quickshell.execDetached(["bash", "-lc", 'exec "$@"', "bash"].concat(argv))
  }

  function previewSound(file) {
    var path = soundsDir + "/" + file
    if (/\.(ogg|oga|wav|flac)$/i.test(file)) runArgv(["pw-play", path])
    else runArgv(["mpv", "--no-video", "--really-quiet", "--no-config", path])
  }

  property string serviceState: ""

  Process {
    id: serviceProcess
    command: ["systemctl", "--user", "is-active", "omarchy-ring"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.serviceState = String(text || "").trim()
    }
  }

  function refreshServiceState() { if (!serviceProcess.running) serviceProcess.running = true }

  Component.onCompleted: refreshSounds()

  function parseJson(content, fallback) {
    try {
      var parsed = JSON.parse(String(content || ""))
      return parsed && typeof parsed === "object" ? parsed : fallback
    } catch (e) {
      return fallback
    }
  }

  readonly property string statusState: ring.status ? String(ring.status.state || "") : ""
  readonly property string statusMessage: ring.status ? String(ring.status.message || "") : ""
  readonly property bool needsLogin: statusState === "login_needed"
  readonly property bool hasProblem: needsLogin || statusState === "error" || statusState === "no_access"

  function sameName(a, b) { return String(a || "").toLowerCase() === String(b || "").toLowerCase() }

  readonly property var cameras: {
    var list = []
    var known = ring.cameras || []
    for (var i = 0; i < known.length; i++) list.push(known[i])

    var configured = ringConfig.cameras || {}
    for (var name in configured) {
      if (!list.some(function(c) { return root.sameName(c.name, name) }))
        list.push({ id: 0, name: name, url: configured[name], snapshot: "" })
    }

    var events = ring.events || []
    for (var j = 0; j < events.length; j++) {
      var cameraName = events[j].camera
      if (!list.some(function(c) { return root.sameName(c.name, cameraName) }))
        list.push({ id: events[j].cameraId || 0, name: cameraName, url: "", snapshot: "" })
    }

    list.sort(function(a, b) { return String(a.name).localeCompare(String(b.name)) })
    return list
  }

  property string selectedCameraName: ""
  readonly property int cameraIndex: {
    for (var i = 0; i < cameras.length; i++)
      if (sameName(cameras[i].name, selectedCameraName)) return i
    return 0
  }
  readonly property var camera: cameras.length > 0 ? cameras[cameraIndex] : null

  function eventsFor(cam) {
    if (!cam) return []
    var all = ring.events || []
    var out = []
    for (var i = 0; i < all.length; i++)
      if (sameName(all[i].camera, cam.name)) out.push(all[i])
    out.sort(function(a, b) { return new Date(b.at).getTime() - new Date(a.at).getTime() })
    return out
  }

  readonly property var cameraEvents: eventsFor(camera).slice(0, eventsPerCamera)

  property int eventCursor: -1
  property bool cursorActive: false
  readonly property var focusedEvent: eventCursor >= 0 && eventCursor < cameraEvents.length ? cameraEvents[eventCursor] : null

  function cameraUrl(cam) {
    if (cam && String(cam.url || "") !== "") return cam.url
    var configured = ringConfig.cameras || {}
    for (var name in configured)
      if (cam && sameName(name, cam.name)) return configured[name]
    return loginUrl()
  }

  function loginUrl() {
    return String(ringConfig.loginUrl || "https://account.ring.com/account/dashboard")
  }

  property var seenAtOpen: ({})

  function seenMs(map, name) {
    var at = map ? map[String(name || "").toLowerCase()] : ""
    var ms = at ? new Date(at).getTime() : 0
    return isFinite(ms) ? ms : 0
  }

  function unreadCount(cam, map) {
    if (!cam) return 0
    var since = seenMs(map, cam.name)
    var list = eventsFor(cam)
    var count = 0
    for (var i = 0; i < list.length; i++)
      if (new Date(list[i].at).getTime() > since) count++
    return count
  }

  function isNew(event) {
    return !!event && new Date(event.at).getTime() > seenMs(seenAtOpen, event.camera)
  }

  readonly property int totalUnread: {
    var total = 0
    for (var i = 0; i < cameras.length; i++) total += unreadCount(cameras[i], seen)
    return total
  }

  function markAllSeen() {
    var now = new Date().toISOString()
    var next = {}
    for (var i = 0; i < cameras.length; i++) next[String(cameras[i].name).toLowerCase()] = now
    root.seen = next
    seenFile.setText(JSON.stringify(next, null, 2))
  }

  function firstUnreadCamera() {
    for (var i = 0; i < cameras.length; i++)
      if (unreadCount(cameras[i], seen) > 0) return cameras[i].name
    return ""
  }

  property double nowMs: Date.now()

  function glyph(codePoint) { return String.fromCodePoint(codePoint) }

  readonly property string barGlyph: glyph(0xF0869)       // md-doorbell_video

  function kindGlyph(kind) {
    var k = String(kind || "")
    if (k === "ding") return glyph(0xF009E)                // md-bell_ring
    if (k === "human") return glyph(0xF0004)               // md-account
    if (k === "on_demand") return glyph(0xF07AE)           // md-cctv
    return glyph(0xF0583)                                  // md-walk
  }

  function kindLabel(kind) {
    var k = String(kind || "")
    if (k === "ding") return "Doorbell"
    if (k === "human") return "Person"
    if (k === "on_demand") return "Live view"
    return "Motion"
  }

  function ago(iso) {
    var ms = root.nowMs - new Date(iso).getTime()
    if (!isFinite(ms)) return ""
    var minutes = Math.floor(ms / 60000)
    if (minutes < 1) return "just now"
    if (minutes < 60) return minutes + "m ago"
    var hours = Math.floor(minutes / 60)
    if (hours < 24) return hours + "h ago"
    return Math.floor(hours / 24) + "d ago"
  }

  function clockTime(iso) {
    var d = new Date(iso)
    if (isNaN(d.getTime())) return ""
    var today = new Date(root.nowMs)
    var time = String(d.getHours()).padStart(2, "0") + ":" + String(d.getMinutes()).padStart(2, "0")
    if (d.toDateString() === today.toDateString()) return time
    return ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"][d.getDay()] + " " + time
  }

  function heroMeta() {
    if (needsLogin) return "Login needed"
    if (statusState === "error") return "Can't reach Ring"
    if (statusState === "no_access") return "Waiting for camera access"
    if (statusState === "connecting") return "Connecting"
    var count = cameras.length + (cameras.length === 1 ? " camera" : " cameras")
    var latest = (ring.events || []).length > 0 ? ring.events[0] : null
    for (var i = 0; i < (ring.events || []).length; i++)
      if (new Date(ring.events[i].at) > new Date(latest.at)) latest = ring.events[i]
    return latest ? count + " · last " + kindLabel(latest.kind).toLowerCase() + " " + ago(latest.at) : count
  }

  readonly property var thumbEvent: {
    if (focusedEvent) return focusedEvent
    for (var i = 0; i < cameraEvents.length; i++)
      if (String(cameraEvents[i].snapshot || "") !== "") return cameraEvents[i]
    return null
  }

    // The camera snapshot reuses one file name, so its URL carries the capture
    // time to get past the image cache.
  readonly property bool thumbIsCamera: !(thumbEvent && String(thumbEvent.snapshot || "") !== "")
    && !focusedEvent && !!camera && String(camera.snapshot || "") !== ""

  readonly property string thumbSource: {
    var base = "file://" + stateDir + "/snapshots/"
    if (thumbEvent && String(thumbEvent.snapshot || "") !== "") return base + thumbEvent.snapshot
    if (thumbIsCamera) return base + camera.snapshot + "?t=" + encodeURIComponent(String(camera.snapshotAt || ""))
    return ""
  }

  readonly property string thumbCaption: {
    if (thumbEvent && String(thumbEvent.snapshot || "") !== "")
      return kindLabel(thumbEvent.kind) + " · " + clockTime(thumbEvent.at) + " · " + ago(thumbEvent.at)
    if (thumbIsCamera) return "Snapshot · " + clockTime(camera.snapshotAt) + " · " + ago(camera.snapshotAt)
    if (focusedEvent) return "No snapshot for this event"
    return ""
  }

  function batteryText(cam) {
    if (!cam) return ""
    var parts = []
    if (cam.offline) parts.push("Offline")
    if (cam.battery !== null && cam.battery !== undefined) parts.push("Battery " + cam.battery + "%")
    return parts.join(" · ")
  }

  readonly property var weekRows: {
    var rows = []
    var now = new Date(root.nowMs)
    for (var back = 6; back >= 0; back--) {
      var day = new Date(now.getFullYear(), now.getMonth(), now.getDate() - back)
      rows.push({ date: day, key: day.toDateString(), count: 0, today: back === 0 })
    }
    var list = eventsFor(camera)
    for (var i = 0; i < list.length; i++) {
      var key = new Date(list[i].at).toDateString()
      for (var r = 0; r < rows.length; r++) if (rows[r].key === key) rows[r].count++
    }
    return rows
  }

  readonly property int weekPeak: {
    var peak = 1
    for (var i = 0; i < weekRows.length; i++) peak = Math.max(peak, weekRows[i].count)
    return peak
  }

  readonly property int todayCount: weekRows.length > 0 ? weekRows[weekRows.length - 1].count : 0

  readonly property var live: ring.live || null
  property double liveNow: Date.now()
  property int liveTick: 0
  readonly property bool liveRunning: !!live && (live.state === "starting" || live.state === "streaming")
    && new Date(live.until).getTime() > liveNow
  readonly property bool liveHere: liveRunning && !!camera && Number(live.cameraId) === Number(camera.id) && Number(camera.id) > 0
  readonly property bool canWatchLive: !!camera && Number(camera.id) > 0 && statusState === "ok"

  Timer {
    interval: 333
    running: (root.opened || root.popupVisible) && root.liveRunning
    repeat: true
    onTriggered: {
      root.liveNow = Date.now()
      if (root.live.state === "streaming") root.liveTick++
    }
  }

  function toggleLive() {
    if (!canWatchLive) return
    liveNow = Date.now()
    if (liveHere) sendRequest("stop", camera.id)
    else sendRequest("live", camera.id)
  }

  function liveCaption() {
    if (!liveHere) return ""
    if (live.state === "starting") return "Connecting to " + camera.name + "…"
    var left = Math.max(0, Math.round((new Date(live.until).getTime() - liveNow) / 1000))
    return "● LIVE · " + left + "s left"
  }

  readonly property string liveError: !!live && live.state === "error" && !!camera
    && Number(live.cameraId) === Number(camera.id) ? String(live.message || "") : ""

  function clamp(v, lo, hi) { return Math.max(lo, Math.min(hi, v)) }
  function alpha(c, a) { return Qt.rgba(c.r, c.g, c.b, a) }

  function selectCamera(index) {
    if (cameras.length === 0) return
    var wrapped = ((index % cameras.length) + cameras.length) % cameras.length
    selectedCameraName = cameras[wrapped].name
    eventCursor = -1
  }

  function openUrl(url) {
    if (!/^https:\/\/[A-Za-z0-9.-]+\.ring\.com\/[A-Za-z0-9\/?&=._%-]*$/.test(String(url || ""))) return
    var browser = String(settingValue("browser", "default"))
    if (browser === "google-chrome-stable" || browser === "chromium") runArgv(["uwsm-app", "--", browser, String(url)])
    else runArgv(["omarchy-launch-browser", String(url)])
    root.close()
  }

  function openCamera() { openUrl(cameraUrl(camera)) }

  function startLogin() {
    if (root.bar) root.bar.run("omarchy-launch-floating-terminal-with-presentation omarchy-ring-login")
    root.close()
  }

  function moveCursor(dy) {
    cursorActive = true
    eventCursor = clamp(eventCursor + dy, -1, cameraEvents.length - 1)
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  property bool settingsOpen: false
  property bool logoutArmed: false

  function openSettings() {
    settingsOpen = true
    logoutArmed = false
    refreshSounds()
    refreshServiceState()
    if (panelFlick) panelFlick.contentY = 0
  }

  function closeSettings() {
    settingsOpen = false
    logoutArmed = false
    if (panelFlick) panelFlick.contentY = 0
  }

  Timer {
    id: logoutDisarm
    interval: 4000
    onTriggered: root.logoutArmed = false
  }

  function logout() {
    if (!logoutArmed) {
      logoutArmed = true
      logoutDisarm.restart()
      return
    }
    logoutArmed = false
    sendRequest("logout", 0)
  }

  readonly property var doorbellCamera: {
    for (var i = 0; i < cameras.length; i++) if (cameras[i].doorbell) return cameras[i]
    return camera
  }

  function testDoorbell() {
    if (!doorbellCamera || !(Number(doorbellCamera.id) > 0)) return
    sendRequest("test-doorbell", doorbellCamera.id)
    root.close()
  }

  function restartService() {
    runArgv(["systemctl", "--user", "restart", "omarchy-ring"])
    serviceState = "restarting"
    serviceRecheck.restart()
  }

  Timer {
    id: serviceRecheck
    interval: 3000
    onTriggered: root.refreshServiceState()
  }

    // Plugin hot-reload doesn't reliably swap in new code; a shell restart does.
  function reloadWidget() {
    root.close()
    runArgv(["omarchy", "restart", "shell"])
  }

  function viewLogs() {
    runArgv(["omarchy-launch-floating-terminal-with-presentation", "journalctl --user -u omarchy-ring -n 100 -f"])
    root.close()
  }

  property bool popupVisible: false
  property string popupCameraName: ""
  property double popupAt: 0

  readonly property var popupCamera: {
    for (var i = 0; i < cameras.length; i++)
      if (sameName(cameras[i].name, popupCameraName)) return cameras[i]
    return null
  }

  readonly property bool popupLive: liveRunning && !!popupCamera && Number(live.cameraId) === Number(popupCamera.id)

  readonly property string popupSnapshot: {
    if (!popupCamera) return ""
    var list = eventsFor(popupCamera)
    for (var i = 0; i < list.length; i++)
      if (String(list[i].snapshot || "") !== "") return "file://" + stateDir + "/snapshots/" + list[i].snapshot
    if (String(popupCamera.snapshot || "") !== "")
      return "file://" + stateDir + "/snapshots/" + popupCamera.snapshot + "?t=" + encodeURIComponent(String(popupCamera.snapshotAt || ""))
    return ""
  }

  function showDoorbell(name) {
    popupCameraName = String(name || "")
    popupAt = Date.now()
    liveNow = Date.now()
    popupVisible = true
  }

    // Closing the popup ends its live view, unless it's handing it to the panel.
  function hideDoorbell(keepLive) {
    popupVisible = false
    if (!keepLive && !opened) stopLiveIfRunning()
  }

  function stopLiveIfRunning() {
    if (liveRunning) sendRequest("stop", Number(live.cameraId))
  }

  property string pendingCamera: ""

  function showCamera(name) {
    pendingCamera = String(name || "")
    if (opened) {
      selectedCameraName = pendingCamera
      eventCursor = -1
      pendingCamera = ""
    } else {
      open()
    }
  }

  onOpenedChanged: if (opened) {
    nowMs = Date.now()
    liveNow = Date.now()
    seenAtOpen = seen
    var unread = pendingCamera !== "" ? pendingCamera : firstUnreadCamera()
    pendingCamera = ""
    if (unread !== "") selectedCameraName = unread
    eventCursor = -1
    cursorActive = false
    markAllSeen()
    if (panelFlick) panelFlick.contentY = 0
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  } else {
    seenAtOpen = seen
    settingsOpen = false
    logoutArmed = false
    if (!popupVisible) stopLiveIfRunning()
  }

  Timer {
    interval: 30000
    running: root.opened
    repeat: true
    onTriggered: root.nowMs = Date.now()
  }

  onRingChanged: if (opened) markAllSeen()

  IpcHandler {
    target: root.ipcTarget
    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    function next(): string { root.selectCamera(root.cameraIndex + 1); return "ok" }
    function showCamera(name: string): void { root.showCamera(name) }
    function doorbell(name: string): void { root.showDoorbell(name) }
    function debug(): string {
      return JSON.stringify({ status: root.statusState, cameras: root.cameras.length,
        events: (root.ring.events || []).length, updatedAt: root.ring.updatedAt || "" })
    }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.barGlyph
    active: root.totalUnread > 0 || root.hasProblem
    onPressed: function(buttonCode) {
      if (buttonCode === Qt.RightButton) root.openUrl(root.loginUrl())
      else if (buttonCode === Qt.MiddleButton) root.selectCamera(root.cameraIndex + 1)
      else root.toggle()
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(400))
    contentHeight: panel.fittedContentHeight(Math.max(column.implicitHeight, settingsColumn.implicitHeight), Style.space(680))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent

      onMoveRequested: function(dx, dy) {
        if (root.settingsOpen) {
          if (dx < 0) root.closeSettings()
          else if (dy !== 0)
            panelFlick.contentY = root.clamp(panelFlick.contentY + dy * Style.space(56), 0,
                                             Math.max(0, panelFlick.contentHeight - panelFlick.height))
          return
        }
        if (dx !== 0) {
          root.cursorActive = true
          root.selectCamera(root.cameraIndex + dx)
        }
        if (dy !== 0) root.moveCursor(dy)
      }
      onActivateRequested: if (!root.settingsOpen) (root.needsLogin ? root.startLogin() : root.openCamera())
      onCloseRequested: root.settingsOpen ? root.closeSettings() : root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(t) {
        if (root.settingsOpen) return
        if (t === "s" || t === "S") root.openSettings()
        else if (t === "o" || t === "O") root.openCamera()
        else if (t === "w" || t === "W") root.toggleLive()
        else if (t === "L") root.startLogin()
      }

      Flickable {
        id: panelFlick
        anchors.fill: parent
        contentWidth: width
        contentHeight: root.settingsOpen ? settingsColumn.implicitHeight : column.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.VerticalFlick
        interactive: contentHeight > height
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        Column {
          id: column
          visible: !root.settingsOpen
          width: panelFlick.width
          spacing: Style.space(12)

          PanelHero {
            width: parent.width
            title: "Ring"
            meta: root.heroMeta()
            detail: root.totalUnread > 0 ? root.totalUnread + " new" : ""
            foreground: root.foreground
            fontFamily: root.fontFamily

            trailingControl: Component {
              PanelActionButton {
                iconText: root.glyph(0xF0493)              // md-cog
                tooltipText: "Settings (s)"
                foreground: root.foreground
                fontFamily: root.fontFamily
                onClicked: root.openSettings()
              }
            }

            iconComponent: Component {
              Text {
                textFormat: Text.PlainText
                text: root.barGlyph
                color: root.hasProblem ? root.urgent : root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.display
              }
            }
          }

          BorderSurface {
            visible: root.hasProblem
            width: parent.width
            implicitHeight: problemColumn.implicitHeight + Style.spacing.xl * 2
            color: root.alpha(root.urgent, 0.10)
            borderSpec: Border.flat(root.alpha(root.urgent, 0.35), 1)
            radius: Style.cornerRadius

            Column {
              id: problemColumn
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              anchors.leftMargin: Style.space(12)
              anchors.rightMargin: Style.space(12)
              spacing: Style.spacing.lg

              Text {
                textFormat: Text.PlainText
                width: parent.width
                text: root.statusMessage !== "" ? root.statusMessage : "Ring needs attention."
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                wrapMode: Text.WordWrap
              }

              Button {
                visible: root.needsLogin || root.statusState === "no_access"
                text: root.needsLogin ? "Log in to Ring" : "Log in with another account"
                iconText: root.glyph(0xF0342)              // md-login
                bordered: true
                foreground: root.foreground
                fontFamily: root.fontFamily
                fontSize: Style.font.bodySmall
                onClicked: root.startLogin()
              }
            }
          }

          Row {
            id: cameraSwitch
            visible: root.cameras.length > 1
            width: parent.width
            spacing: Style.spacing.md

            readonly property real cellWidth: root.cameras.length > 0
              ? (width - spacing * (root.cameras.length - 1)) / root.cameras.length
              : 0

            Repeater {
              model: root.cameras

              Button {
                required property var modelData
                required property int index
                readonly property int unread: root.unreadCount(modelData, root.seenAtOpen)

                width: cameraSwitch.cellWidth
                text: modelData.name + (unread > 0 ? "  ·  " + unread : "")
                selected: index === root.cameraIndex
                hasCursor: root.cursorActive && index === root.cameraIndex && root.eventCursor < 0
                bordered: true
                foreground: root.foreground
                fontFamily: root.fontFamily
                fontSize: Style.font.bodySmall
                verticalPadding: Style.spacing.controlPaddingY
                onClicked: {
                  root.cursorActive = true
                  root.selectCamera(index)
                }
              }
            }
          }

          Text {
            visible: root.cameras.length === 0
            width: parent.width
            topPadding: Style.space(24)
            text: "No cameras yet.\nThey show up once omarchy-ring is logged in."
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.WordWrap
          }

          Item {
            id: thumb
            visible: !!root.camera
            width: parent.width
            height: Math.round(width * 9 / 16)

            Rectangle {
              id: thumbFrame
              anchors.fill: parent
              radius: Style.cornerRadius
              color: root.alpha(root.foreground, 0.05)
              clip: true

              Image {
                id: thumbImage
                anchors.fill: parent
                source: root.thumbSource
                fillMode: Image.PreserveAspectCrop
                asynchronous: true
                cache: true
                sourceSize.width: thumb.width * 2
                visible: status === Image.Ready && !liveLayer.showing
              }

              LiveFrame {
                id: liveLayer
                anchors.fill: parent
                active: root.liveHere
              }

              Column {
                anchors.centerIn: parent
                visible: thumbImage.status !== Image.Ready && !liveLayer.showing
                spacing: Style.spacing.md

                Text {
                  anchors.horizontalCenter: parent.horizontalCenter
                  textFormat: Text.PlainText
                  text: root.glyph(0xF11D1)                // md-image_off_outline
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.display
                }

                Text {
                  anchors.horizontalCenter: parent.horizontalCenter
                  textFormat: Text.PlainText
                  text: root.focusedEvent ? "No snapshot for this event" : "No snapshot yet"
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                }
              }

              Rectangle {
                visible: (thumbImage.status === Image.Ready && root.thumbCaption !== "") || root.liveHere
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.bottom: parent.bottom
                height: captionText.implicitHeight + Style.spacing.lg * 2
                color: root.alpha(Color.popups.background, 0.78)

                Text {
                  id: captionText
                  textFormat: Text.PlainText
                  anchors.left: parent.left
                  anchors.right: parent.right
                  anchors.verticalCenter: parent.verticalCenter
                  anchors.leftMargin: Style.space(10)
                  anchors.rightMargin: Style.space(10)
                  text: root.liveHere ? root.liveCaption() : root.thumbCaption
                  color: root.liveHere && root.live.state === "streaming" ? root.urgent : root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  font.bold: true
                  elide: Text.ElideRight
                }
              }
            }

            MouseArea {
              id: thumbMouse
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: root.openCamera()
            }

            PanelToolTip {
              visible: thumbMouse.containsMouse
              text: "Open " + (root.camera ? root.camera.name : "camera") + " in the browser"
              fontFamily: root.fontFamily
            }
          }

          Row {
            id: actionRow
            visible: !!root.camera
            width: parent.width
            spacing: Style.spacing.md

            Button {
              width: (actionRow.width - actionRow.spacing) / 2
              text: root.liveHere ? "Stop" : "Watch here"
              iconText: root.liveHere ? root.glyph(0xF04DB) : root.glyph(0xF07AE)   // md-stop / md-cctv
              enabled: root.canWatchLive
              opacity: enabled ? 1 : 0.5
              selected: root.liveHere
              bordered: true
              foreground: root.foreground
              fontFamily: root.fontFamily
              fontSize: Style.font.bodySmall
              tooltipText: root.canWatchLive ? "Stream " + root.camera.name + " in this panel (w)" : ""
              onClicked: root.toggleLive()
            }

            Button {
              width: (actionRow.width - actionRow.spacing) / 2
              text: "Open in Ring"
              iconText: root.glyph(0xF03CC)                // md-open_in_new
              bordered: true
              foreground: root.foreground
              fontFamily: root.fontFamily
              fontSize: Style.font.bodySmall
              tooltipText: "Open " + (root.camera ? root.camera.name : "the camera") + " in the browser (o)"
              onClicked: root.openCamera()
            }
          }

          Text {
            id: cameraInfo
            textFormat: Text.PlainText
            visible: text !== ""
            width: parent.width
            text: root.liveError !== "" ? root.liveError : root.batteryText(root.camera)
            color: root.liveError !== "" || (root.camera && root.camera.offline) ? root.urgent : root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
          }

          PanelSeparator {
            visible: !!root.camera
            foreground: root.foreground
          }

          Column {
            id: weekSection
            visible: !!root.camera
            width: parent.width
            spacing: Style.spacing.md

            Item {
              width: parent.width
              implicitHeight: weekHeader.implicitHeight

              PanelSectionHeader {
                id: weekHeader
                text: "LAST 7 DAYS"
                foreground: root.foreground
                fontFamily: root.fontFamily
              }

              Text {
                textFormat: Text.PlainText
                anchors.right: parent.right
                anchors.bottom: weekHeader.bottom
                text: root.todayCount + " today"
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                font.bold: true
              }
            }

            Repeater {
              model: root.weekRows

              DayRow {
                required property var modelData
                width: weekSection.width
                row: modelData
                ratio: modelData.count / root.weekPeak
              }
            }
          }

          PanelSeparator {
            visible: !!root.camera
            foreground: root.foreground
          }

          Column {
            id: eventsSection
            visible: !!root.camera
            width: parent.width
            spacing: Style.spacing.xs

            PanelSectionHeader {
              text: "RECENT EVENTS"
              foreground: root.foreground
              fontFamily: root.fontFamily
              bottomPadding: Style.spacing.sm
            }

            Text {
              visible: root.cameraEvents.length === 0
              width: parent.width
              topPadding: Style.space(8)
              bottomPadding: Style.space(8)
              text: "Nothing in the last week."
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              horizontalAlignment: Text.AlignHCenter
            }

            Repeater {
              id: eventRepeater
              model: root.cameraEvents

              EventRow {
                required property var modelData
                required property int index
                width: eventsSection.width
                event: modelData
                hasCursor: root.cursorActive && index === root.eventCursor
                fresh: root.isNew(modelData)
                onHoveredRow: {
                  root.cursorActive = true
                  root.eventCursor = index
                }
                onClicked: root.openCamera()
              }
            }
          }

          Text {
            textFormat: Text.PlainText
            visible: text !== ""
            width: parent.width
            topPadding: Style.space(2)
            text: {
              if (!root.ring.updatedAt) return "omarchy-ring is not running"
              return "h/l camera · j/k events · w watch · o open · s settings"
            }
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            horizontalAlignment: Text.AlignHCenter
            elide: Text.ElideRight
          }
        }

        SettingsView {
          id: settingsColumn
          visible: root.settingsOpen
          width: panelFlick.width
        }
      }
    }
  }

  component SettingsView: Column {
    spacing: Style.space(12)

    Item {
      width: parent.width
      implicitHeight: Math.max(backButton.implicitHeight, settingsTitle.implicitHeight)

      PanelActionButton {
        id: backButton
        anchors.left: parent.left
        anchors.verticalCenter: parent.verticalCenter
        iconText: root.glyph(0xF0141)                      // md-chevron_left
        tooltipText: "Back (Esc)"
        foreground: root.foreground
        fontFamily: root.fontFamily
        onClicked: root.closeSettings()
      }

      Text {
        id: settingsTitle
        textFormat: Text.PlainText
        anchors.left: backButton.right
        anchors.leftMargin: Style.space(8)
        anchors.verticalCenter: parent.verticalCenter
        text: "Settings"
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.title
        font.bold: true
      }
    }

    PanelSeparator { foreground: root.foreground }
    PanelSectionHeader { text: "DOORBELL SOUND"; foreground: root.foreground; fontFamily: root.fontFamily }

    Repeater {
      model: root.sounds.concat(["none"])

      Item {
        required property var modelData
        width: parent.width
        implicitHeight: soundButton.implicitHeight

        Button {
          id: soundButton
          anchors.left: parent.left
          anchors.right: previewButton.visible ? previewButton.left : parent.right
          anchors.rightMargin: previewButton.visible ? Style.spacing.md : 0
          leftAlign: true
          text: modelData === "none" ? "No sound" : root.soundLabel(modelData)
          iconText: root.doorbellSound === modelData ? root.glyph(0xF012C) : " "   // md-check
          selected: root.doorbellSound === modelData
          bordered: true
          foreground: root.foreground
          fontFamily: root.fontFamily
          fontSize: Style.font.bodySmall
          onClicked: root.saveSetting("doorbellSound", modelData)
        }

        PanelActionButton {
          id: previewButton
          visible: modelData !== "none"
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          size: soundButton.implicitHeight
          bordered: true
          iconText: root.glyph(0xF040A)                    // md-play
          tooltipText: "Play"
          foreground: root.foreground
          fontFamily: root.fontFamily
          onClicked: root.previewSound(modelData)
        }
      }
    }

    Text {
      textFormat: Text.PlainText
      width: parent.width
      text: "Add your own: drop an mp3/ogg/wav into ~/.config/omarchy-ring/sounds"
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      wrapMode: Text.WordWrap
    }

    PanelSeparator { foreground: root.foreground }
    PanelSectionHeader { text: "WHEN SOMEONE RINGS"; foreground: root.foreground; fontFamily: root.fontFamily }

    SettingToggle {
      width: parent.width
      label: "Popup with the camera"
      detail: "Replaces the notification and stays until you dismiss it. Never takes keyboard focus."
      checked: root.settingValue("doorbellPopup", true) !== false
      onToggled: root.saveSetting("doorbellPopup", !checked)
    }

    Column {
      width: parent.width
      spacing: Style.spacing.md

      Text {
        textFormat: Text.PlainText
        text: "Live view length"
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
      }

      ButtonGroup {
        width: parent.width
        options: [
          { value: "0", label: "Off" },
          { value: "15", label: "15s" },
          { value: "30", label: "30s" },
          { value: "60", label: "60s" }
        ]
        value: String(root.settingValue("doorbellLiveSeconds", 30))
        foreground: root.foreground
        fontFamily: root.fontFamily
        fontSize: Style.font.bodySmall
        focusable: false
        onChanged: function(value) { root.saveSetting("doorbellLiveSeconds", Number(value)) }
      }

      Text {
        textFormat: Text.PlainText
        width: parent.width
        text: "Streams the doorbell like opening live view in the app, so it uses battery."
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        wrapMode: Text.WordWrap
      }
    }

    Button {
      width: parent.width
      text: "Test the doorbell"
      iconText: root.glyph(0xF009E)                        // md-bell_ring
      enabled: root.statusState === "ok" && !!root.doorbellCamera && Number(root.doorbellCamera.id) > 0
      opacity: enabled ? 1 : 0.5
      bordered: true
      foreground: root.foreground
      fontFamily: root.fontFamily
      fontSize: Style.font.bodySmall
      tooltipText: "Sound, notification, popup and live view, without anyone ringing"
      onClicked: root.testDoorbell()
    }

    PanelSeparator { foreground: root.foreground }
    PanelSectionHeader { text: "OPEN CAMERAS IN"; foreground: root.foreground; fontFamily: root.fontFamily }

    ButtonGroup {
      width: parent.width
      options: [
        { value: "default", label: "Default" },
        { value: "google-chrome-stable", label: "Chrome" },
        { value: "chromium", label: "Chromium" }
      ]
      value: String(root.settingValue("browser", "default"))
      foreground: root.foreground
      fontFamily: root.fontFamily
      fontSize: Style.font.bodySmall
      focusable: false
      onChanged: function(value) { root.saveSetting("browser", value) }
    }

    PanelSeparator { foreground: root.foreground }
    PanelSectionHeader { text: "NOTIFICATIONS"; foreground: root.foreground; fontFamily: root.fontFamily }

    SettingToggle {
      width: parent.width
      label: "Motion notifications"
      detail: "Desktop notifications for motion. Doorbell presses always notify; events still land in the panel."
      checked: root.settingValue("motionNotifications", true) !== false
      onToggled: root.saveSetting("motionNotifications", !checked)
    }

    PanelSeparator { foreground: root.foreground }

    Item {
      width: parent.width
      implicitHeight: serviceHeader.implicitHeight

      PanelSectionHeader { id: serviceHeader; text: "SERVICE"; foreground: root.foreground; fontFamily: root.fontFamily }

      Text {
        textFormat: Text.PlainText
        anchors.right: parent.right
        anchors.bottom: serviceHeader.bottom
        text: root.serviceState === "active" ? "running"
          : root.serviceState === "" ? "" : root.serviceState
        color: root.serviceState === "active" ? root.dim : root.urgent
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        font.bold: true
      }
    }

    Grid {
      id: maintenance
      width: parent.width
      columns: 2
      columnSpacing: Style.spacing.md
      rowSpacing: Style.spacing.md
      readonly property real cell: (width - columnSpacing) / 2

      Button {
        width: maintenance.cell
        text: "Restart service"
        iconText: root.glyph(0xF0709)                      // md-restart
        bordered: true
        foreground: root.foreground
        fontFamily: root.fontFamily
        fontSize: Style.font.bodySmall
        tooltipText: "Reconnects to Ring"
        onClicked: root.restartService()
      }

      Button {
        width: maintenance.cell
        text: "Reload widget"
        iconText: root.glyph(0xF0453)                      // md-reload
        bordered: true
        foreground: root.foreground
        fontFamily: root.fontFamily
        fontSize: Style.font.bodySmall
        tooltipText: "Restarts the Omarchy shell; the bar blinks for a second"
        onClicked: root.reloadWidget()
      }

      Button {
        width: maintenance.cell
        text: "View logs"
        iconText: root.glyph(0xF09ED)                      // md-text_box_outline
        bordered: true
        foreground: root.foreground
        fontFamily: root.fontFamily
        fontSize: Style.font.bodySmall
        tooltipText: "Follow the service log in a terminal"
        onClicked: root.viewLogs()
      }
    }

    PanelSeparator { foreground: root.foreground }
    PanelSectionHeader { text: "RING ACCOUNT"; foreground: root.foreground; fontFamily: root.fontFamily }

    Text {
      textFormat: Text.PlainText
      width: parent.width
      text: root.needsLogin ? "Not logged in." : "Logged in. Ring lists this computer as “omarchy-ring” under Authorized Client Devices."
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      wrapMode: Text.WordWrap
    }

    Grid {
      id: accountButtons
      width: parent.width
      columns: 2
      columnSpacing: Style.spacing.md
      readonly property real cell: (width - columnSpacing) / 2

      Button {
        width: accountButtons.cell
        visible: !root.needsLogin
        text: root.logoutArmed ? "Click again" : "Log out"
        iconText: root.glyph(0xF0343)                      // md-logout
        bordered: true
        foreground: root.logoutArmed ? root.urgent : root.foreground
        fontFamily: root.fontFamily
        fontSize: Style.font.bodySmall
        tooltipText: "Erases the saved login on this computer"
        onClicked: root.logout()
      }

      Button {
        width: accountButtons.cell
        visible: root.needsLogin
        text: "Log in"
        iconText: root.glyph(0xF0342)                      // md-login
        bordered: true
        foreground: root.foreground
        fontFamily: root.fontFamily
        fontSize: Style.font.bodySmall
        onClicked: root.startLogin()
      }

      Button {
        width: accountButtons.cell
        text: "Ring devices"
        iconText: root.glyph(0xF03CC)                      // md-open_in_new
        bordered: true
        foreground: root.foreground
        fontFamily: root.fontFamily
        fontSize: Style.font.bodySmall
        tooltipText: "Ring's Control Center, to revoke this computer's access on Ring's side"
        onClicked: root.openUrl("https://account.ring.com/account/control-center")
      }
    }
  }

  component SettingToggle: Item {
    id: toggleRow
    property string label: ""
    property string detail: ""
    property bool checked: false
    signal toggled()

    implicitHeight: Math.max(toggleText.implicitHeight, toggleSwitch.implicitHeight)

    Column {
      id: toggleText
      anchors.left: parent.left
      anchors.right: toggleSwitch.left
      anchors.rightMargin: Style.space(12)
      anchors.verticalCenter: parent.verticalCenter
      spacing: Style.spacing.xs

      Text {
        textFormat: Text.PlainText
        width: parent.width
        text: toggleRow.label
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
        wrapMode: Text.WordWrap
      }

      Text {
        textFormat: Text.PlainText
        visible: text !== ""
        width: parent.width
        text: toggleRow.detail
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        wrapMode: Text.WordWrap
      }
    }

    ToggleSwitch {
      id: toggleSwitch
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      checked: toggleRow.checked
      foreground: root.foreground
      onToggled: toggleRow.toggled()
    }
  }

    // Two images take turns loading the next frame, so the picture never blanks
    // while one loads.
  component LiveFrame: Item {
    id: frame
    property bool active: false
    property int front: 0
    property bool hasFrame: false
    readonly property bool showing: active && hasFrame
    visible: showing

    Connections {
      target: root
      function onLiveTickChanged() {
        if (!frame.active || !root.live || root.live.state !== "streaming") return
        var url = "file://" + root.stateDir + "/live/" + root.live.file + "?f=" + root.liveTick
        if (frame.front === 0) frameB.source = url
        else frameA.source = url
      }
    }

    onActiveChanged: if (!active) {
      hasFrame = false
      frameA.source = ""
      frameB.source = ""
    }

    Image {
      id: frameA
      anchors.fill: parent
      fillMode: Image.PreserveAspectCrop
      asynchronous: true
      cache: false
      visible: frame.front === 0
      onStatusChanged: if (status === Image.Ready && String(source) !== "") { frame.front = 0; frame.hasFrame = true }
    }

    Image {
      id: frameB
      anchors.fill: parent
      fillMode: Image.PreserveAspectCrop
      asynchronous: true
      cache: false
      visible: frame.front === 1
      onStatusChanged: if (status === Image.Ready && String(source) !== "") { frame.front = 1; frame.hasFrame = true }
    }
  }

    // Doorbell popup: a separate layer-shell window with no keyboard focus, since
    // Omarchy panels always grab the keyboard.
  PanelWindow {
    id: doorbellPopup
    visible: root.popupVisible
    screen: button.QsWindow.window ? button.QsWindow.window.screen : null
    color: "transparent"
    anchors { top: true; right: true }
    margins { top: Style.gapsOut; right: Style.gapsOut }
    exclusionMode: ExclusionMode.Normal
    implicitWidth: Style.space(360)
    implicitHeight: popupCard.implicitHeight
    WlrLayershell.namespace: "omarchy-ring-doorbell"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.None

    BorderSurface {
      id: popupCard
      anchors.fill: parent
      implicitHeight: popupColumn.implicitHeight + Style.spacing.popupPadding * 2
      color: Color.popups.background
      borderSpec: Border.surfaceSpec("popups", "border", Color.popups.border, Math.max(1, Style.space(2)))
      radius: Style.cornerRadius

      Column {
        id: popupColumn
        anchors.fill: parent
        anchors.margins: Style.spacing.popupPadding
        spacing: Style.space(10)

        Item {
          width: parent.width
          implicitHeight: Math.max(popupTitle.implicitHeight, popupClose.implicitHeight)

          Text {
            id: popupTitle
            textFormat: Text.PlainText
            anchors.left: parent.left
            anchors.right: popupClose.left
            anchors.verticalCenter: parent.verticalCenter
            text: root.glyph(0xF009E) + "  Someone's at the " + root.popupCameraName
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            font.bold: true
            elide: Text.ElideRight
          }

          PanelActionButton {
            id: popupClose
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            iconText: root.glyph(0xF0156)                  // md-close
            tooltipText: "Dismiss"
            foreground: root.foreground
            fontFamily: root.fontFamily
            onClicked: root.hideDoorbell()
          }
        }

        Rectangle {
          width: parent.width
          height: Math.round(width * 9 / 16)
          radius: Style.cornerRadius
          color: root.alpha(root.foreground, 0.05)
          clip: true

          Image {
            anchors.fill: parent
            source: root.popupSnapshot
            fillMode: Image.PreserveAspectCrop
            asynchronous: true
            visible: status === Image.Ready && !popupLiveFrame.showing
          }

          LiveFrame {
            id: popupLiveFrame
            anchors.fill: parent
            active: root.popupLive
          }

          Rectangle {
            visible: root.popupLive
            anchors.left: parent.left
            anchors.bottom: parent.bottom
            anchors.margins: Style.space(8)
            width: popupLiveText.implicitWidth + Style.space(12)
            height: popupLiveText.implicitHeight + Style.space(6)
            radius: Style.cornerRadius
            color: root.alpha(Color.popups.background, 0.8)

            Text {
              id: popupLiveText
              textFormat: Text.PlainText
              anchors.centerIn: parent
              text: {
                if (!root.popupLive) return ""
                if (root.live.state === "starting") return "Connecting…"
                return "● LIVE · " + Math.max(0, Math.round((new Date(root.live.until).getTime() - root.liveNow) / 1000)) + "s"
              }
              color: root.live && root.live.state === "streaming" ? root.urgent : root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              font.bold: true
            }
          }

          MouseArea {
            anchors.fill: parent
            cursorShape: Qt.PointingHandCursor
            onClicked: {
              var name = root.popupCameraName
              root.hideDoorbell(true)
              root.showCamera(name)
            }
          }
        }

        Text {
          textFormat: Text.PlainText
          width: parent.width
          text: "Rang at " + root.clockTime(new Date(root.popupAt).toISOString()) + " · click the picture to open the panel"
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }
      }
    }
  }

  component DayRow: Item {
    id: dayRow
    property var row: null
    property real ratio: 0

    readonly property bool today: !!row && row.today

    implicitHeight: Math.max(dayLabel.implicitHeight, dayValue.implicitHeight) + Style.spacing.xs

    Text {
      id: dayLabel
      textFormat: Text.PlainText
      text: dayRow.today ? "Today" : (dayRow.row ? ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"][dayRow.row.date.getDay()] : "")
      color: dayRow.today ? root.foreground : root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      font.bold: dayRow.today
      anchors.left: parent.left
      anchors.verticalCenter: parent.verticalCenter
      width: Style.space(52)
    }

    Rectangle {
      anchors.left: dayLabel.right
      anchors.right: dayValue.left
      anchors.leftMargin: Style.space(8)
      anchors.rightMargin: Style.space(10)
      anchors.verticalCenter: parent.verticalCenter
      height: Math.max(Style.space(4), Math.round(Style.spacing.controlHeight * 0.14))
      radius: height / 2
      color: root.track

      Rectangle {
        anchors.left: parent.left
        anchors.verticalCenter: parent.verticalCenter
        height: parent.height
        radius: parent.radius
        width: parent.width * root.clamp(dayRow.ratio, 0, 1)
        color: dayRow.today ? root.foreground : root.alpha(root.foreground, 0.55)

        Behavior on width {
          NumberAnimation { duration: 160; easing.type: Easing.OutCubic }
        }
      }
    }

    Text {
      id: dayValue
      textFormat: Text.PlainText
      text: dayRow.row ? String(dayRow.row.count) : "0"
      color: dayRow.today ? root.foreground : root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      font.bold: true
      horizontalAlignment: Text.AlignRight
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      width: Style.space(28)
    }
  }

  component EventRow: Item {
    id: eventRow
    property var event: null
    property bool hasCursor: false
    property bool fresh: false

    signal clicked()
    signal hoveredRow()

    implicitHeight: Math.max(eventText.implicitHeight, eventTime.implicitHeight) + Style.spacing.lg * 2

    Rectangle {
      anchors.fill: parent
      radius: Style.cornerRadius
      color: eventRow.hasCursor || rowMouse.containsMouse
        ? Style.hoverFillFor(root.foreground, Color.accent)
        : "transparent"
    }

    Rectangle {
      id: freshDot
      visible: eventRow.fresh
      width: Style.space(6)
      height: width
      radius: width / 2
      color: Color.accent
      anchors.left: parent.left
      anchors.leftMargin: Style.space(2)
      anchors.verticalCenter: parent.verticalCenter
    }

    Text {
      id: eventGlyph
      textFormat: Text.PlainText
      text: root.kindGlyph(eventRow.event ? eventRow.event.kind : "")
      color: eventRow.event && eventRow.event.kind === "ding" ? Color.accent : root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.body
      anchors.left: parent.left
      anchors.leftMargin: Style.space(14)
      anchors.verticalCenter: parent.verticalCenter
      width: Style.space(18)
    }

    Text {
      id: eventText
      textFormat: Text.PlainText
      text: eventRow.event ? eventRow.event.text : ""
      color: eventRow.fresh ? root.foreground : Qt.darker(root.foreground, 1.15)
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
      font.bold: eventRow.fresh
      elide: Text.ElideRight
      anchors.left: eventGlyph.right
      anchors.leftMargin: Style.space(6)
      anchors.right: snapMark.left
      anchors.rightMargin: Style.space(6)
      anchors.verticalCenter: parent.verticalCenter
    }

    Text {
      id: snapMark
      textFormat: Text.PlainText
      readonly property bool hasSnapshot: !!eventRow.event && String(eventRow.event.snapshot || "") !== ""
      text: hasSnapshot ? root.glyph(0xF07AE) : ""         // md-cctv
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      anchors.right: eventTime.left
      anchors.rightMargin: hasSnapshot ? Style.space(6) : 0
      anchors.verticalCenter: parent.verticalCenter
    }

    Text {
      id: eventTime
      textFormat: Text.PlainText
      text: eventRow.event ? root.clockTime(eventRow.event.at) : ""
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      font.bold: true
      anchors.right: parent.right
      anchors.rightMargin: Style.space(8)
      anchors.verticalCenter: parent.verticalCenter
    }

    MouseArea {
      id: rowMouse
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onContainsMouseChanged: if (containsMouse) eventRow.hoveredRow()
      onClicked: eventRow.clicked()
    }

    PanelToolTip {
      visible: rowMouse.containsMouse
      text: eventRow.event ? root.kindLabel(eventRow.event.kind) + " · " + root.ago(eventRow.event.at) + " · click to open the camera" : ""
      fontFamily: root.fontFamily
    }
  }
}
