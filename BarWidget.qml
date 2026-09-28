import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

BarWidget {
  id: root
  moduleName: "saigkill.mastodon"

  // State must NOT live inside the plugin directory: Quickshell watches that
  // folder and reloads the plugin on any write, which destroys an open panel
  // mid-login.
  readonly property string dataDir: Quickshell.env("HOME")
    + "/.local/state/omarchy-mastodon"
  readonly property string dataFile: dataDir + "/auth.json"
  readonly property string oauthScript: Qt.resolvedUrl("oauth_server.py").toString().replace("file://", "")

  property var auth: Model.emptyAuth()
  readonly property bool authed: Model.isAuthed(auth)
  property string oauthClientId: ""
  property string oauthClientSecret: ""
  property int oauthPort: 0
  property int oauthPortAttempts: 0
  property bool oauthPending: false
  property string oauthError: ""

  readonly property string tooltipText: authed
    ? "Mastodon: " + Model.normalizeInstance(auth.instance)
    : "Mastodon: not logged in"

  readonly property color stateColor: authed
    ? (bar ? bar.barForeground : Color.foreground)
    : Color.urgent

  function loadData() {
    loadProc.command = ["sh", "-c", 'cat "$1" 2>/dev/null || true', "sh", root.dataFile]
    loadProc.running = true
  }

  function applyData(text) {
    var parsed = null
    try { parsed = JSON.parse(String(text || "")) } catch (error) { parsed = null }
    var data = Model.decode(parsed)
    root.auth = data.auth
  }

  function saveData() {
    var json = JSON.stringify({ auth: root.auth })
    saveProc.command = ["sh", "-c",
      'mkdir -p "$(dirname "$2")" && umask 077 && printf %s "$1" > "$2"',
      "sh", json, root.dataFile]
    saveProc.running = true
  }

  function clearAuth() {
    root.auth = Model.emptyAuth()
    root.oauthClientId = ""
    root.oauthClientSecret = ""
    root.oauthPort = 0
    root.oauthPortAttempts = 0
    root.oauthPending = false
    root.oauthError = ""
    root.saveData()
  }

  // `property var` holds a JS object; mutating it in place would not notify
  // bindings (authed, Panel.auth), so always replace the object.
  function patchAuth(fields) {
    var next = {}
    for (var key in root.auth) next[key] = root.auth[key]
    for (var name in fields) next[name] = fields[name]
    root.auth = next
  }

  function failOAuth(message) {
    root.oauthPending = false
    root.oauthError = message
  }


  function startOAuth() {
    var instance = Model.normalizeInstance(panelLoader.item ? panelLoader.item.loginInstance : "")
    if (instance === "") {
      root.failOAuth("Please enter an instance")
      return
    }
    root.oauthError = ""
    root.patchAuth({ instance: instance })
    root.oauthPending = true
    root.oauthClientId = ""
    root.oauthClientSecret = ""
    root.oauthPort = Model.randomPort()
    root.oauthPortAttempts = 0
    root.saveData()
    root.registerApp()
  }

  function registerApp() {
    registerAppProc.command = Model.registerAppCmd(
      root.auth.instance, Model.callbackUri(root.oauthPort))
    registerAppProc.running = true
  }

  function onRegisterAppExited(exitCode) {
    var raw = registerAppOut.text
    var parsed = Model.parseJson(raw)
    if (!parsed || !parsed.client_id || !parsed.client_secret) {
      root.failOAuth("Could not register app on " + root.auth.instance)
      return
    }
    root.oauthClientId = String(parsed.client_id)
    root.oauthClientSecret = String(parsed.client_secret)
    root.patchAuth({ clientId: root.oauthClientId, clientSecret: root.oauthClientSecret })
    root.saveData()
    root.startOAuthServer()
  }

  function startOAuthServer() {
    var redirectUri = Model.callbackUri(root.oauthPort)
    oauthProc.command = [root.oauthScript, String(root.oauthPort)]
    oauthProc.running = true
    var authUrl = root.auth.instance
      + "/oauth/authorize?response_type=code"
      + "&client_id=" + encodeURIComponent(root.oauthClientId)
      + "&redirect_uri=" + encodeURIComponent(redirectUri)
      + "&scope=" + encodeURIComponent(Model.APP_SCOPES)
    Qt.openUrlExternally(authUrl)
  }

  function onOAuthServerExited(exitCode) {
    var text = oauthOut.text.trim()
    if (text.indexOf("OAUTH_ERROR:") === 0) {
      var reason = text.replace("OAUTH_ERROR:", "").trim()
      if (reason === "port_unavailable:" + root.oauthPort && root.oauthPortAttempts < 3) {
        root.oauthPortAttempts++
        root.oauthPort = Model.randomPort()
        root.registerApp()
        return
      }
      root.failOAuth(reason === "access_denied" ? "Login was cancelled" : "Login failed")
      return
    }
    if (exitCode !== 0 || text === "") {
      root.failOAuth("Login failed")
      return
    }
    root.exchangeToken(text)
  }

  function exchangeToken(code) {
    exchangeTokenProc.command = Model.exchangeTokenCmd(
      root.auth.instance, root.oauthClientId, root.oauthClientSecret,
      code, Model.callbackUri(root.oauthPort))
    exchangeTokenProc.running = true
  }

  function onExchangeTokenExited(exitCode) {
    var raw = exchangeTokenOut.text
    var parsed = Model.parseJson(raw)
    if (!parsed || !parsed.access_token) {
      root.failOAuth("Token exchange failed")
      return
    }
    root.patchAuth({ accessToken: String(parsed.access_token) })
    root.oauthPending = false
    root.oauthError = ""
    root.saveData()
    if (panelLoader.item) panelLoader.item.onLoginSuccess()
  }

  readonly property bool opened: panelLoader.item ? panelLoader.item.opened === true : false
  readonly property bool popoutSwitchClosing: panelLoader.item ? panelLoader.item.popoutSwitchClosing === true : false

  function open() { if (panelLoader.item) panelLoader.item.open() }
  function close() { if (panelLoader.item) panelLoader.item.close() }
  function toggle() { if (panelLoader.item) panelLoader.item.toggle() }
  function closeForPopoutSwitch() { if (panelLoader.item) panelLoader.item.closeForPopoutSwitch() }

  function injectPanel() {
    var target = panelLoader.item
    if (!target) return
    if ("bar" in target) target.bar = root.bar
    if ("settings" in target) target.settings = root.settings
    if ("anchorItem" in target) target.anchorItem = button
    if ("hostWidget" in target) target.hostWidget = root
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onBarChanged: injectPanel()
  onSettingsChanged: injectPanel()
  Component.onCompleted: {
    loadData()
  }

  Loader {
    id: panelLoader
    active: true
    source: Qt.resolvedUrl("Panel.qml")
    visible: false
    onLoaded: {
      root.injectPanel()
      Qt.callLater(root.injectPanel)
    }
  }

  IpcHandler {
    target: "saigkill.mastodon"
    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: "\uf466"
    slotSize: Style.bar.statusSlot
    fontSize: Style.font.caption
    active: false
    enabled: true
    foreground: root.stateColor
    tooltipText: root.tooltipText

    onPressed: function(mouseButton) {
      if (mouseButton === Qt.LeftButton) root.toggle()
    }
  }

  Process {
    id: loadProc
    stdout: StdioCollector {
      id: loadOut
      waitForEnd: true
    }
    onExited: function(exitCode) {
      root.applyData(loadOut.text)
    }
  }

  Process {
    id: saveProc
    onExited: function(exitCode) {
      if (exitCode !== 0) console.warn("saigkill.mastodon: failed to save auth file")
    }
  }

  Process {
    id: registerAppProc
    stdout: StdioCollector {
      id: registerAppOut
      waitForEnd: true
    }
    onExited: function(exitCode) {
      root.onRegisterAppExited(exitCode)
    }
  }

  Process {
    id: oauthProc
    stdout: StdioCollector {
      id: oauthOut
      waitForEnd: true
    }
    onExited: function(exitCode) {
      root.onOAuthServerExited(exitCode)
    }
  }

  Process {
    id: exchangeTokenProc
    stdout: StdioCollector {
      id: exchangeTokenOut
      waitForEnd: true
    }
    onExited: function(exitCode) {
      root.onExchangeTokenExited(exitCode)
    }
  }
}
