import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

BarWidget {
  id: root
  moduleName: "saigkill.mastodon"

  // The access token and the client secret never enter this file at all:
  // mastodon_helper.py owns the 0600 state file and both secrets, so a
  // crash, a log line or a stray `ps` from another local process cannot
  // expose them. This file only ever sees the instance, the public client
  // id, and whether a token exists.
  readonly property string helperScript: Qt.resolvedUrl("mastodon_helper.py").toString().replace("file://", "")
  readonly property string oauthScript: Qt.resolvedUrl("oauth_server.py").toString().replace("file://", "")

  property var auth: Model.emptyAuth()
  readonly property bool authed: Model.isAuthed(auth)
  property string oauthClientId: ""
  property string pendingInstance: ""
  property bool pendingLoginSuccess: false
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
    loadProc.command = Model.loadCmd(root.helperScript)
    loadProc.running = true
  }

  function onLoadExited(exitCode) {
    var parsed = Model.parseJson(loadOut.text)
    var data = Model.decode(parsed)
    root.auth = data.auth
    if (root.pendingLoginSuccess) {
      root.pendingLoginSuccess = false
      if (panelLoader.item) panelLoader.item.onLoginSuccess()
    }
  }

  function clearAuth() {
    root.oauthClientId = ""
    root.pendingInstance = ""
    root.oauthPort = 0
    root.oauthPortAttempts = 0
    root.oauthPending = false
    root.oauthError = ""
    logoutProc.command = Model.logoutCmd(root.helperScript)
    logoutProc.running = true
  }

  function onLogoutExited(exitCode) {
    root.loadData()
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
    root.oauthPending = true
    root.oauthClientId = ""
    root.pendingInstance = instance
    root.oauthPort = Model.randomPort()
    root.oauthPortAttempts = 0
    // A previous, incomplete login attempt may have left a client id/secret
    // behind for a different instance. Sending an explicit empty clientId
    // makes the helper drop it before it is bound to a fresh registration.
    saveProc.command = Model.saveCmd(root.helperScript)
    saveProc.environment = ({
      MASTODON_AUTH_JSON: JSON.stringify({ auth: { instance: instance, clientId: "" } })
    })
    saveProc.running = true
  }

  function onSaveExited(exitCode) {
    if (exitCode !== 0) {
      root.failOAuth("Could not save instance")
      return
    }
    root.registerApp()
  }

  function registerApp() {
    var redirectUri = Model.callbackUri(root.oauthPort)
    registerAppProc.command = Model.registerAppCmd(root.helperScript, redirectUri)
    registerAppProc.running = true
  }

  function onRegisterAppExited(exitCode) {
    var parsed = Model.parseJson(registerAppOut.text)
    if (exitCode !== 0 || !parsed || !parsed.client_id) {
      root.failOAuth("Could not register app on " + root.pendingInstance)
      return
    }
    root.oauthClientId = String(parsed.client_id)
    root.startOAuthServer()
  }

  function startOAuthServer() {
    var redirectUri = Model.callbackUri(root.oauthPort)
    oauthProc.command = [root.oauthScript, String(root.oauthPort)]
    oauthProc.running = true
    var authUrl = root.pendingInstance
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

  // The authorization code is the one secret that has to travel from the
  // panel to the helper: it is passed through the environment
  // (MASTODON_OAUTH_CODE), not argv, because /proc/<pid>/environ is
  // readable only by the owning user while /proc/<pid>/cmdline is not.
  function exchangeToken(code) {
    var redirectUri = Model.callbackUri(root.oauthPort)
    exchangeTokenProc.command = Model.exchangeTokenCmd(root.helperScript, redirectUri)
    exchangeTokenProc.environment = ({ MASTODON_OAUTH_CODE: code })
    exchangeTokenProc.running = true
  }

  function onExchangeTokenExited(exitCode) {
    var parsed = Model.parseJson(exchangeTokenOut.text)
    if (exitCode !== 0 || !parsed || parsed.ok !== true) {
      root.failOAuth("Token exchange failed")
      return
    }
    root.oauthPending = false
    root.oauthError = ""
    // The token itself is never read back into the panel; loadData() only
    // ever learns whether one now exists.
    root.pendingLoginSuccess = true
    root.loadData()
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
    // U+EDC0 is the Nerd Font mapping for fa-mastodon. The plain Font
    // Awesome codepoint U+F4F6 is taken by oct-note in JetBrainsMono Nerd
    // Font, and the previous U+F466 rendered as oct-mute (a speaker).
    text: "\uEDC0"
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
      root.onLoadExited(exitCode)
    }
  }

  Process {
    id: saveProc
    onExited: function(exitCode) {
      root.onSaveExited(exitCode)
    }
  }

  Process {
    id: logoutProc
    onExited: function(exitCode) {
      root.onLogoutExited(exitCode)
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
