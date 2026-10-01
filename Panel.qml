import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

Panel {
  id: root
  moduleName: "saigkill.mastodon"
  ipcTarget: "saigkill.mastodon"
  manageIpc: false

  property var anchorItem: null
  property var hostWidget: null

  readonly property var auth: hostWidget ? hostWidget.auth : Model.emptyAuth()
  readonly property bool authed: hostWidget ? hostWidget.authed : false
  readonly property string instance: auth.instance || ""
  // mastodon_helper.py owns the access token; it never travels back into
  // the panel, so there is no accessToken property here to leak.
  readonly property string helperScript: hostWidget ? hostWidget.helperScript
    : Qt.resolvedUrl("mastodon_helper.py").toString().replace("file://", "")

  property string loginInstance: ""
  readonly property bool loggingIn: hostWidget ? hostWidget.oauthPending : false
  readonly property string loginError: hostWidget ? hostWidget.oauthError : ""

  property int currentTab: 0
  property var homeTimeline: []
  property var localTimeline: []
  property var mentions: []
  property var currentUser: null
  property var relationships: ({})

  property bool homeHasMore: true
  property bool localHasMore: true
  property bool mentionsHasMore: true
  property bool loadingMore: false
  readonly property bool hasMore: currentTab === 0 ? homeHasMore
    : (currentTab === 1 ? localHasMore : mentionsHasMore)
  readonly property bool feedEmpty: currentTab === 0 ? homeTimeline.length === 0
    : (currentTab === 1 ? localTimeline.length === 0 : mentions.length === 0)

  property string composerText: ""
  property string replyToId: ""
  property string replyToUser: ""
  property bool posting: false
  property string postError: ""

  // Images attached to the composer. Each entry is
  // { path, name, id, previewUrl, failed, description }: the file itself is
  // uploaded to the instance the moment it is attached, and the thumbnail shown
  // here is the preview the instance made of it, so the panel never reads a
  // local image. description is the confirmed alt text; "" is both "none given"
  // and "cleared again".
  property var media: []
  // Paths picked but not uploaded yet. One Quickshell.Io.Process runs one
  // command at a time, so a multi-file selection is uploaded one after the
  // other from this queue.
  property var mediaQueue: []
  property bool pickingMedia: false
  property bool uploadingMedia: false
  property string uploadingPath: ""
  // The alt text being edited (path of the image) and the text in the field.
  // altPath is "" when no image is being described, which also hides the editor.
  property string altPath: ""
  property string altDraft: ""
  property string altError: ""
  property bool savingAlt: false
  property string altSavingPath: ""
  property string altSavingText: ""
  readonly property bool busyWithMedia: root.pickingMedia || root.uploadingMedia
    || root.mediaQueue.length > 0 || root.savingAlt
  readonly property int mediaCount: Model.pendingMediaIds(root.media).length
  readonly property bool canPost: root.composerText.trim() !== "" || root.mediaCount > 0

  // How many images the instance accepts per status, read from the same
  // instance answer as the character limit.
  property int maxMediaAttachments: Model.MAX_MEDIA_PER_STATUS

  // The character limit the instance enforces, read from the instance itself
  // because 500 is only Mastodon's default. Until the answer arrives (and for
  // an instance that reports none) the default is used, so the composer is
  // never briefly unlimited.
  property int maxCharacters: Model.DEFAULT_MAX_CHARACTERS
  // The limit for one image's alt text, read from the instance like the other
  // two. It is a limit per attachment, so it does not shrink the composer text.
  property int mediaDescriptionLimit: Model.DEFAULT_MEDIA_DESCRIPTION_LIMIT
  property bool instanceConfigLoaded: false
  readonly property int composerLength: root.composerText.length

  // The composer text lives on the panel, the field is kept in step through
  // this one function. A `text: root.composerText` binding would be the
  // obvious way to do it, but cutting an over-long text is an imperative write
  // and an imperative write to a bound property drops the binding for good —
  // clearing the composer after posting would then silently stop working. The
  // binding cannot be put back from inside a signal handler either, so the
  // field is not bound and everything goes through here.
  function setComposerText(value) {
    root.composerText = value
    if (composerInput && composerInput.text !== value) composerInput.text = value
  }

  // ------------------------------------------------------------ images

  // Opens the desktop file chooser and queues whatever comes back. The panel
  // closes for the duration: it is an Overlay layer window, so the chooser, a
  // normal client window, would open underneath it and the user would see
  // nothing. This object stays alive while the window is hidden, so the text,
  // the reply target and the images already attached all survive.
  function attachImages() {
    if (root.busyWithMedia || !root.authed) return
    root.pickingMedia = true
    root.postError = ""
    root.close()
    pickMediaProc.command = Model.pickMediaCmd()
    pickMediaProc.running = true
  }

  function onPickMediaExited(exitCode) {
    root.pickingMedia = false
    // omarchy-file-select exits 1 when the chooser was closed without a
    // selection and 2 when it never opened; neither is worth reporting. It
    // prints one already-decoded path per line.
    var lines = String(pickMediaOut.text || "").split("\n")
    var picked = []
    for (var i = 0; i < lines.length; i++) {
      var path = lines[i].trim()
      if (path === "") continue
      if (root.media.length + root.mediaQueue.length + picked.length
          >= root.maxMediaAttachments) {
        root.postError = "At most " + root.maxMediaAttachments + " images per post"
        break
      }
      picked.push(path)
    }
    // Assigned rather than pushed into: an in-place mutation of a var array
    // does not notify, and busyWithMedia is bound to the queue's length.
    root.mediaQueue = root.mediaQueue.concat(picked)
    root.open()
    root.startNextUpload()
    Qt.callLater(root.focusComposer)
  }

  function startNextUpload() {
    if (root.uploadingMedia || root.mediaQueue.length === 0) return
    var path = root.mediaQueue[0]
    root.mediaQueue = root.mediaQueue.slice(1)
    root.uploadingPath = path
    root.uploadingMedia = true
    // The entry appears immediately, before the upload has a preview to show,
    // so the composer reflects what was picked right away.
    root.media = root.media.concat([{
      path: path,
      name: Model.baseName(path),
      id: "",
      previewUrl: "",
      failed: false,
      description: "",
    }])
    uploadMediaProc.command = Model.uploadMediaCmd(root.helperScript)
    uploadMediaProc.environment = ({ MASTODON_UPLOAD_PATH: path })
    uploadMediaProc.running = true
  }

  function onUploadMediaExited(exitCode) {
    root.uploadingMedia = false
    var path = root.uploadingPath
    root.uploadingPath = ""
    var parsed = Model.parseJson(uploadMediaOut.text)
    var id = parsed && parsed.id ? String(parsed.id) : ""
    // The instance answers with a preview_url that is always there, while the
    // full-size url is still null for a moment (the v2 endpoint processes the
    // file in the background). Only http(s) is ever loaded into an Image.
    var preview = id === "" ? ""
      : Model.safeHttpUrl(parsed.preview_url || parsed.url)
    if (id === "") root.postError = "Upload failed: " + Model.baseName(path)
    root.setMediaResult(path, id, preview)
    root.startNextUpload()
  }

  function setMediaResult(path, id, previewUrl) {
    var next = []
    for (var i = 0; i < root.media.length; i++) {
      var entry = root.media[i]
      if (entry.path === path) {
        // description is carried over: the user may have typed one while the
        // upload was still running.
        entry = { path: entry.path, name: entry.name, id: id,
          previewUrl: previewUrl, failed: id === "",
          description: entry.description || "" }
      }
      next.push(entry)
    }
    root.media = next
  }

  function removeMedia(entry) {
    if (root.altPath === entry.path) root.altPath = ""
    var next = []
    for (var i = 0; i < root.media.length; i++) {
      if (root.media[i].path !== entry.path) next.push(root.media[i])
    }
    root.media = next
  }

  // ------------------------------------------------------------ alt texts

  // Which image is being given an alt text, and the text being typed. The alt
  // text belongs to the attachment, and Mastodon only accepts it while that
  // attachment is not yet part of a posted status — so it is sent with its own
  // request the moment it is saved, and afterwards travels with the media id
  // into the status. The panel only has to remember what was confirmed.
  function openAltText(entry) {
    if (root.savingAlt || entry.id === "") return
    root.altPath = entry.path
    root.altDraft = entry.description || ""
    root.altError = ""
    root.altField.text = root.altDraft
    Qt.callLater(function () { altField.forceActiveFocus() })
  }

  function closeAltText() {
    root.altPath = ""
    root.altDraft = ""
    root.altError = ""
  }

  function saveAltText() {
    if (root.savingAlt || root.altPath === "") return
    var target = null
    for (var i = 0; i < root.media.length; i++) {
      if (root.media[i].path === root.altPath) target = root.media[i]
    }
    if (target === null || target.id === "") { root.closeAltText(); return }
    root.altError = ""
    root.savingAlt = true
    root.altSavingPath = target.path
    root.altSavingText = root.altDraft
    describeProc.command = Model.describeMediaCmd(
      root.helperScript, target.id, root.altDraft)
    describeProc.running = true
  }

  function onDescribeExited(exitCode) {
    var path = root.altSavingPath
    var text = root.altSavingText
    root.savingAlt = false
    root.altSavingPath = ""
    root.altSavingText = ""
    if (exitCode !== 0) {
      // The text stays in the field so it is not lost; the instance refuses a
      // PUT once the attachment is part of a status, and that is the case
      // worth a word of explanation rather than a bare failure.
      root.altError = "Alt text not saved"
      return
    }
    var next = []
    for (var i = 0; i < root.media.length; i++) {
      var entry = root.media[i]
      if (entry.path === path) {
        entry = { path: entry.path, name: entry.name, id: entry.id,
          previewUrl: entry.previewUrl, failed: entry.failed,
          description: text }
      }
      next.push(entry)
    }
    root.media = next
    root.closeAltText()
  }

  property string feedError: ""
  property bool loadingFeed: false

  readonly property color contentForeground: bar ? bar.barForeground : Color.foreground
  readonly property string contentFontFamily: bar ? bar.fontFamily : Style.font.family

  function switchPanel(direction) {
    if (root.bar && typeof root.bar.switchPanelFrom === "function")
      return root.bar.switchPanelFrom(root.hostWidget || root, direction)
    return false
  }

  function onLoginSuccess() {
    root.loadCurrentUser()
    root.loadInstanceConfig()
    root.loadTimelines()
  }

  function loadCurrentUser() {
    if (!root.authed) return
    var cmd = Model.verifyCredentialsCmd(root.helperScript)
    verifyProc.command = cmd
    verifyProc.running = true
  }

  function onVerifyExited(exitCode) {
    var parsed = Model.parseJson(verifyOut.text)
    if (parsed) root.currentUser = parsed
  }

  // Fetched once per instance, not once per panel open: a composer limit is
  // not something that changes while a panel is open, and every extra call is
  // a process the instance has to answer.
  function loadInstanceConfig() {
    if (root.instanceConfigLoaded || !root.authed) return
    var cmd = Model.instanceConfigCmd(root.helperScript)
    instanceProc.command = cmd
    instanceProc.running = true
  }

  function onInstanceConfigExited(exitCode) {
    // A failed request is simply not marked as loaded, so the next panel open
    // tries again rather than leaving a limit the user cannot compose under.
    if (exitCode !== 0) return
    var parsed = Model.parseJson(instanceConfigOut.text)
    if (!parsed || typeof parsed !== "object") return
    root.maxCharacters = Model.parseMaxCharacters(parsed)
    root.maxMediaAttachments = Model.parseMaxMediaAttachments(parsed)
    root.mediaDescriptionLimit = Model.parseMediaDescriptionLimit(parsed)
    root.instanceConfigLoaded = true
  }

  // The panel object outlives the login that populated it, and a shell restart
  // rebuilds it empty, so an empty feed is filled on the first open. A feed that
  // already has entries is left alone to avoid a request on every open.
  onOpenedChanged: {
    if (!root.opened || !root.authed) return
    root.loadInstanceConfig()
    if (root.loadingFeed || !root.feedEmpty) return
    root.loadCurrentUser()
    root.loadTimelines()
  }

  function loadTimelines() {
    if (!root.authed) return
    root.loadingFeed = true
    root.feedError = ""
    var homeCmd = Model.homeTimelineCmd(root.helperScript)
    homeProc.command = homeCmd
    homeProc.running = true
  }

  function onHomeExited(exitCode) {
    var parsed = Model.parseJson(homeOut.text)
    if (Array.isArray(parsed)) {
      root.homeTimeline = parsed
      root.homeHasMore = parsed.length >= Model.PAGE_SIZE
      root.loadRelationships(parsed)
    } else {
      root.feedError = "Failed to load home timeline"
    }
    root.loadLocal()
  }

  function loadLocal() {
    var localCmd = Model.localTimelineCmd(root.helperScript)
    localProc.command = localCmd
    localProc.running = true
  }

  function onLocalExited(exitCode) {
    var parsed = Model.parseJson(localOut.text)
    if (Array.isArray(parsed)) {
      root.localTimeline = parsed
      root.localHasMore = parsed.length >= Model.PAGE_SIZE
      root.loadRelationships(parsed)
    }
    root.loadMentions()
  }

  function loadMentions() {
    var mentionsCmd = Model.mentionsCmd(root.helperScript)
    mentionsProc.command = mentionsCmd
    mentionsProc.running = true
  }

  function onMentionsExited(exitCode) {
    var parsed = Model.parseJson(mentionsOut.text)
    if (Array.isArray(parsed)) {
      root.mentions = parsed
      root.mentionsHasMore = parsed.length >= Model.PAGE_SIZE
    }
    root.loadingFeed = false
  }

  // Called from the Flickable whenever it moves. Reaching the tail of the list
  // pulls the next older page in; the guard in loadMore keeps a fast scroll
  // from queueing several requests at once.
  function maybeLoadMore() {
    if (!root.authed || root.loadingFeed || root.loadingMore) return
    if (!root.hasMore || root.feedEmpty) return
    var remaining = scroll.contentHeight - (scroll.contentY + scroll.height)
    if (remaining > Style.space(320)) return
    root.loadMore()
  }

  function loadMore() {
    if (!root.authed || root.loadingMore || !root.hasMore) return
    root.loadingMore = true
    if (root.currentTab === 0) {
      moreHomeProc.command = Model.homeTimelineCmd(
        root.helperScript, Model.oldestId(root.homeTimeline))
      moreHomeProc.running = true
    } else if (root.currentTab === 1) {
      moreLocalProc.command = Model.localTimelineCmd(
        root.helperScript, Model.oldestId(root.localTimeline))
      moreLocalProc.running = true
    } else {
      moreMentionsProc.command = Model.mentionsCmd(
        root.helperScript, Model.oldestId(root.mentions))
      moreMentionsProc.running = true
    }
  }

  // Shared tail handler for all three paged feeds. curl runs with -f, so a
  // transient HTTP error arrives as unparsable output. Treating that as
  // "end of feed" would truncate the timeline for the rest of the session, so
  // only a genuine short page is allowed to clear the hasMore flag.
  function finishPaging(parsed, listProperty, moreProperty, withRelationships) {
    if (Array.isArray(parsed)) {
      root.feedError = ""
      if (parsed.length > 0) {
        root[listProperty] = Model.appendUnique(root[listProperty], parsed)
        if (withRelationships) root.loadRelationships(parsed)
      }
      if (parsed.length < Model.PAGE_SIZE) root[moreProperty] = false
    } else {
      root.feedError = "Could not load older posts"
    }
    root.loadingMore = false
  }

  function onMoreHomeExited(exitCode) {
    root.finishPaging(Model.parseJson(moreHomeOut.text), "homeTimeline", "homeHasMore", true)
  }

  function onMoreLocalExited(exitCode) {
    root.finishPaging(Model.parseJson(moreLocalOut.text), "localTimeline", "localHasMore", true)
  }

  function onMoreMentionsExited(exitCode) {
    root.finishPaging(Model.parseJson(moreMentionsOut.text), "mentions", "mentionsHasMore", false)
  }

  function loadRelationships(statuses) {
    var ids = []
    for (var i = 0; i < statuses.length; i++) {
      // The Follow button targets the original author (statusDelegate.status,
      // which unwraps a boost's .reblog), so relationships must be looked up
      // for that same account rather than the outer status's account.
      var id = Model.displayStatus(statuses[i]).account.id
      if (ids.indexOf(id) === -1) ids.push(id)
    }
    if (ids.length === 0) return
    var relCmd = Model.relationshipCmd(root.helperScript, ids[0])
    relProc.command = relCmd
    relProc.running = true
  }

  function onRelExited(exitCode) {
    var parsed = Model.parseJson(relOut.text)
    if (Array.isArray(parsed) && parsed.length > 0) {
      var rel = parsed[0]
      var next = {}
      for (var key in root.relationships) next[key] = root.relationships[key]
      next[rel.id] = rel
      root.relationships = next
    }
  }

  function isFollowing(accountId) {
    var rel = root.relationships[accountId]
    return rel && rel.following === true
  }

  function postStatus() {
    var text = root.composerText.trim()
    var ids = Model.pendingMediaIds(root.media)
    // A post with neither text nor an accepted image is not a post: the
    // instance answers 422 for it. Waiting for pending uploads keeps a half
    // attached image from being left behind on the instance.
    if (root.posting || root.busyWithMedia) return
    if (text === "" && ids.length === 0) return
    root.posting = true
    root.postError = ""
    var cmd = Model.postStatusCmd(root.helperScript, text, root.replyToId || null,
      root.maxCharacters, ids)
    postProc.command = cmd
    postProc.running = true
  }

  function onPostExited(exitCode) {
    root.posting = false
    var parsed = Model.parseJson(postOut.text)
    if (parsed && parsed.id) {
      root.setComposerText("")
      root.replyToId = ""
      root.replyToUser = ""
      root.media = []
      root.closeAltText()
      root.loadTimelines()
    } else {
      // The images stay attached, so pressing Post again reuses the uploads
      // instead of sending them a second time.
      root.postError = "Failed to post"
    }
  }

  function toggleReblog(status) {
    var cmd = status.reblogged
      ? Model.unreblogCmd(root.helperScript, status.id)
      : Model.reblogCmd(root.helperScript, status.id)
    actionProc.command = cmd
    actionProc.running = true
  }

  function toggleFavourite(status) {
    var cmd = status.favourited
      ? Model.unfavouriteCmd(root.helperScript, status.id)
      : Model.favouriteCmd(root.helperScript, status.id)
    actionProc.command = cmd
    actionProc.running = true
  }

  function toggleBookmark(status) {
    var cmd = status.bookmarked
      ? Model.unbookmarkCmd(root.helperScript, status.id)
      : Model.bookmarkCmd(root.helperScript, status.id)
    actionProc.command = cmd
    actionProc.running = true
  }

  function toggleFollow(account) {
    var cmd = root.isFollowing(account.id)
      ? Model.unfollowCmd(root.helperScript, account.id)
      : Model.followCmd(root.helperScript, account.id)
    actionProc.command = cmd
    actionProc.running = true
  }

  function onActionExited(exitCode) {
    root.loadTimelines()
  }

  function startReply(status) {
    root.replyToId = status.id
    root.replyToUser = Model.accountHandle(status.account)
    root.setComposerText("")
    Qt.callLater(root.focusComposer)
  }

  // The composer is a single field at the top of the panel, so a reply target
  // further down the feed has to scroll back to it and take the keyboard.
  function focusComposer() {
    scroll.positionViewAtBeginning()
    if (composerInput) composerInput.forceActiveFocus()
  }

  function cancelReply() {
    root.replyToId = ""
    root.replyToUser = ""
    root.setComposerText("")
    if (keyCatcher) keyCatcher.forceActiveFocus()
  }

  function logout() {
    if (root.hostWidget) root.hostWidget.clearAuth()
    root.currentUser = null
    root.homeTimeline = []
    root.localTimeline = []
    root.mentions = []
    root.relationships = {}
    root.setComposerText("")
    root.replyToId = ""
    root.replyToUser = ""
    root.media = []
    root.mediaQueue = []
    root.uploadingPath = ""
    root.closeAltText()
    root.savingAlt = false
    root.altSavingPath = ""
    root.altSavingText = ""
    // The next login can be a different instance with a different limit.
    root.maxCharacters = Model.DEFAULT_MAX_CHARACTERS
    // The next login can be a different instance with a different limit.
    root.maxMediaAttachments = Model.MAX_MEDIA_PER_STATUS
    root.mediaDescriptionLimit = Model.DEFAULT_MEDIA_DESCRIPTION_LIMIT
    root.instanceConfigLoaded = false
  }

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.hostWidget || root
    bar: root.bar
    open: root.opened
    centerOnBar: true
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(520))
    contentHeight: panel.fittedContentHeight(Style.space(700), Style.space(700))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      // Keys.priority is BeforeItem, so without this the catcher's j/k/h/l,
      // space and x handling would eat the user's typing inside an editor.
      blocked: composerInput.activeFocus || instanceField.activeFocus
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }


      Item {
        id: fixedTop
        anchors.top: parent.top
        anchors.left: parent.left
        anchors.right: parent.right
        // The children are chained with anchors and summed explicitly. The
        // Column's implicitHeight collapsed to 0 here, which left the feed
        // filling the whole panel on top of the composer.
        height: headerItem.height + loginRect.height + tabsRect.height
          + composerRect.height + Style.space(8) * 3

        Item {
          id: headerItem
          anchors.top: parent.top
          anchors.left: parent.left
          anchors.right: parent.right
          height: headerRow.height

          Row {
            id: headerRow
            spacing: Style.space(8)

            PanelSectionHeader {
              anchors.verticalCenter: parent.verticalCenter
              foreground: root.contentForeground
              fontFamily: root.contentFontFamily
              text: "MASTODON"
            }

            PanelActionButton {
              iconText: "\uf021"
              tooltipText: "Reload"
              foreground: root.contentForeground
              fontFamily: root.contentFontFamily
              onClicked: root.loadTimelines()
            }

            PanelActionButton {
              iconText: "\uf08b"
              tooltipText: "Logout"
              foreground: root.contentForeground
              fontFamily: root.contentFontFamily
              onClicked: root.logout()
            }
          }
        }

        Rectangle {
          id: loginRect
          visible: !root.authed
          anchors.top: headerItem.bottom
          anchors.topMargin: Style.space(8)
          anchors.left: parent.left
          anchors.right: parent.right
          height: visible ? loginColumn.implicitHeight + Style.space(16) : 0
          radius: Style.cornerRadius
          color: Style.controlFill(false, false, root.contentForeground, Color.accent)

          Column {
            id: loginColumn
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.leftMargin: Style.space(12)
            anchors.rightMargin: Style.space(12)
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(8)

            Text {
              width: parent.width
              text: "Login with Mastodon"
              color: root.contentForeground
              font.family: root.contentFontFamily
              font.pixelSize: Style.font.body
              font.bold: true
            }

            TextField {
              id: instanceField
              width: parent.width
              foreground: root.contentForeground
              text: root.loginInstance
              placeholderText: "Instance (e.g. mastodon.social)"
              onTextEdited: root.loginInstance = text
              Keys.onEscapePressed: function(event) {
                keyCatcher.forceActiveFocus()
                event.accepted = true
              }
            }

            Text {
              width: parent.width
              visible: root.loginError !== ""
              text: root.loginError
              color: Color.urgent
              font.family: root.contentFontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
            }

            Button {
              text: root.loggingIn ? "Logging in..." : "Login"
              bordered: true
              focusable: true
              enabled: !root.loggingIn && root.loginInstance.trim() !== ""
              foreground: root.contentForeground
              fontFamily: root.contentFontFamily
              onClicked: {
                if (root.hostWidget) root.hostWidget.startOAuth()
              }
            }
          }
        }

        Rectangle {
          id: tabsRect
          visible: root.authed
          anchors.top: loginRect.bottom
          anchors.topMargin: Style.space(8)
          anchors.left: parent.left
          anchors.right: parent.right
          height: visible ? tabRow.implicitHeight + Style.space(12) : 0
          radius: Style.cornerRadius
          color: Style.controlFill(false, false, root.contentForeground, Color.accent)

          Row {
            id: tabRow
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.leftMargin: Style.space(8)
            anchors.rightMargin: Style.space(8)
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(4)

            Repeater {
              model: ["Home", "Local", "Mentions"]

              Button {
                required property string modelData
                required property int index
                text: modelData
                bordered: root.currentTab === index
                focusable: true
                foreground: root.contentForeground
                fontFamily: root.contentFontFamily
                onClicked: root.currentTab = index
              }
            }
          }
        }

        Rectangle {
          id: composerRect
          visible: root.authed
          anchors.top: tabsRect.bottom
          anchors.topMargin: Style.space(8)
          anchors.left: parent.left
          anchors.right: parent.right
          height: visible ? composerColumn.implicitHeight + Style.space(12) : 0
          radius: Style.cornerRadius
          color: Style.controlFill(false, false, root.contentForeground, Color.accent)

          Column {
            id: composerColumn
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.leftMargin: Style.space(12)
            anchors.rightMargin: Style.space(12)
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(6)

            Text {
              width: parent.width
              visible: root.replyToUser !== ""
              text: "Replying to " + root.replyToUser
              color: Qt.darker(root.contentForeground, 1.5)
              font.family: root.contentFontFamily
              font.pixelSize: Style.font.caption
              elide: Text.ElideRight
            }

            Rectangle {
              width: parent.width
              height: Style.space(70)
              radius: Style.cornerRadius
              color: Style.controlFill(false, false, root.contentForeground, Color.accent)

              Text {
                anchors.left: parent.left
                anchors.leftMargin: Style.space(10)
                anchors.right: parent.right
                anchors.rightMargin: Style.space(10)
                anchors.top: parent.top
                anchors.topMargin: Style.space(8)
                visible: root.composerText === ""
                text: root.replyToUser !== "" ? "Write a reply..." : "What's on your mind?"
                color: Qt.darker(root.contentForeground, 1.6)
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.body
                wrapMode: Text.WordWrap
              }

              // The box is a fixed 70px tall, so a long status has more
              // lines than fit. A TextEdit on its own cannot be scrolled in
              // Qt 6: it has contentHeight but no contentY, so everything
              // below the last visible line is simply cut off. The
              // ScrollView is what turns those lines into a scroll range,
              // the same way the monitor and audio panels scroll theirs.
              ScrollView {
                id: composerScroll
                anchors.fill: parent
                anchors.margins: Style.space(8)
                clip: true
                // The themed Rectangle underneath draws the box, a default
                // background would paint over it and over the placeholder.
                background: Item {}
                ScrollBar.horizontal.policy: ScrollBar.AlwaysOff
                ScrollBar.vertical.policy: composerInput.implicitHeight > composerScroll.height
                  ? ScrollBar.AsNeeded : ScrollBar.AlwaysOff
                Binding {
                  target: composerScroll.contentItem
                  property: "interactive"
                  // An interactive flickable would swallow the drag that
                  // selects text as soon as there is something to scroll.
                  value: composerInput.implicitHeight > composerScroll.height
                }

                TextArea {
                  id: composerInput
                  width: composerScroll.availableWidth
                  height: Math.max(implicitHeight, composerScroll.availableHeight)
                  // TextArea is a TextEdit that reports its wrapped height as
                  // implicitHeight, and that number is what the ScrollView
                  // turns into a scroll range. A plain TextEdit has no usable
                  // implicit size, so nothing would scroll.
                  background: Item {}
                  padding: 0
                  color: root.contentForeground
                  font.family: root.contentFontFamily
                  font.pixelSize: Style.font.body
                  wrapMode: TextEdit.Wrap
                  selectByMouse: true
                  onTextEdited: {
                    // The instance answers a status longer than its limit with a
                    // 422, so the overflow is cut here and never reaches the
                    // post. TextEdit has no maxLength of its own (only
                    // TextInput has one, and the composer has to wrap), so
                    // typing, pasting and drag and drop are all clamped by hand.
                    var limited = Model.limitText(text, root.maxCharacters)
                    if (limited !== text) {
                      var cursor = cursorPosition
                      text = limited
                      cursorPosition = Math.min(cursor, limited.length)
                    }
                    root.setComposerText(limited)
                  }
                  Keys.onEscapePressed: function(event) {
                    if (root.replyToId !== "") root.cancelReply()
                    keyCatcher.forceActiveFocus()
                    event.accepted = true
                  }
                }
              }
            }

            // The attached images, shown with the preview the instance made of
            // them. An upload that failed keeps its slot and shows a warning
            // instead of vanishing, so it is obvious which file has to be
            // picked again; it carries no id, so it is left out of the post.
            Flow {
              width: parent.width
              visible: root.media.length > 0
              // Explicit height, 0 when hidden: an invisible item still
              // reports an implicitHeight to the Column, which would leave an
              // empty gap above the buttons.
              height: visible ? implicitHeight : 0
              spacing: Style.space(6)

              Repeater {
                model: root.media

                Rectangle {
                  id: mediaThumb
                  required property var modelData
                  width: Style.space(56)
                  height: Style.space(56)
                  radius: Style.cornerRadius
                  color: Style.controlFill(false, false, root.contentForeground, Color.accent)
                  clip: true

                  Image {
                    anchors.fill: parent
                    visible: modelData.previewUrl !== ""
                    source: modelData.previewUrl
                    fillMode: Image.PreserveAspectCrop
                    asynchronous: true
                    smooth: true
                    cache: true
                  }

                  Text {
                    anchors.centerIn: parent
                    visible: modelData.previewUrl === ""
                    text: "!"
                    color: Color.urgent
                    font.family: root.contentFontFamily
                    font.pixelSize: Style.font.body
                  }

                  // Sized down from the default 22 so that it does not cover a
                  // third of the thumbnail it sits on.
                  PanelActionButton {
                    anchors.top: parent.top
                    anchors.right: parent.right
                    size: Style.space(18)
                    fontSize: Style.font.body
                    iconText: ""
                    tooltipText: "Remove image"
                    hoverColor: Color.urgent
                    foreground: root.contentForeground
                    fontFamily: root.contentFontFamily
                    onClicked: root.removeMedia(mediaThumb.modelData)
                  }

                  // The alt text is the one thing about an image a screen
                  // reader cannot see, so the thumbnail itself carries it: the
                  // badge says whether one is there, and clicking the thumbnail
                  // opens the editor. No badge on a failed upload, since there
                  // is no attachment on the instance to describe.
                  Rectangle {
                    anchors.bottom: parent.bottom
                    anchors.left: parent.left
                    anchors.margins: 1
                    width: altBadge.implicitWidth + Style.space(4)
                    height: altBadge.implicitHeight + Style.space(2)
                    radius: Style.cornerRadius
                    visible: modelData.id !== ""
                    color: Qt.rgba(0, 0, 0, 0.55)

                    Text {
                      id: altBadge
                      anchors.centerIn: parent
                      text: (modelData.description || "") !== "" ? "ALT" : "+ALT"
                      color: (modelData.description || "") !== ""
                        ? Color.accent
                        : root.contentForeground
                      font.family: root.contentFontFamily
                      font.pixelSize: Style.font.caption - 2
                      font.capitalization: Font.AllUppercase
                    }
                  }

                  MouseArea {
                    anchors.fill: parent
                    anchors.rightMargin: Style.space(18)
                    // Under the remove button, so that button still wins.
                    enabled: modelData.id !== "" && !root.savingAlt
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.openAltText(mediaThumb.modelData)
                  }

                  Rectangle {
                    id: altRing
                    anchors.fill: parent
                    radius: Style.cornerRadius
                    color: "transparent"
                    border.width: Style.space(2)
                    border.color: Color.accent
                    visible: root.altPath === mediaThumb.modelData.path
                  }
                }
              }
            }

            // The alt text editor. One line, for one image, opened by clicking
            // that image's thumbnail.
            Rectangle {
              id: altEditor
              width: parent.width
              visible: root.altPath !== ""
              height: visible ? implicitHeight : 0
              implicitHeight: altEditorColumn.implicitHeight + Style.space(8)
              radius: Style.cornerRadius
              color: Style.controlFill(false, false, root.contentForeground, Color.accent)

              Column {
                id: altEditorColumn
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.top: parent.top
                anchors.margins: Style.space(4)
                spacing: Style.space(4)

                Row {
                  width: parent.width
                  spacing: Style.space(4)

                  Text {
                    width: parent.width - altCounter.width - Style.space(4)
                    text: "Alt text"
                    elide: Text.ElideRight
                    color: Qt.darker(root.contentForeground, 1.5)
                    font.family: root.contentFontFamily
                    font.pixelSize: Style.font.caption
                  }

                  Text {
                    id: altCounter
                    text: root.altDraft.length + "/" + root.mediaDescriptionLimit
                    color: root.altDraft.length >= root.mediaDescriptionLimit
                      ? Color.urgent
                      : Qt.darker(root.contentForeground, 1.7)
                    font.family: root.contentFontFamily
                    font.pixelSize: Style.font.caption
                  }
                }

                Row {
                  width: parent.width
                  spacing: Style.space(4)

                  TextField {
                    id: altField
                    width: parent.width - altSave.width - altDiscard.width
                      - Style.space(8)
                    height: implicitHeight
                    text: ""
                    color: root.contentForeground
                    font.family: root.contentFontFamily
                    font.pixelSize: Style.font.body
                    placeholderText: "Describe this image"
                    background: Item {}
                    padding: 0
                    onTextChanged: {
                      // Same clamp as the composer text: an over-long
                      // description is refused by the instance with a 422.
                      var limited = Model.limitText(text, root.mediaDescriptionLimit)
                      if (limited !== text) {
                        var cursor = cursorPosition
                        text = limited
                        cursorPosition = Math.min(cursor, limited.length)
                      }
                      root.altDraft = limited
                    }
                    Keys.onEscapePressed: function(event) {
                      root.closeAltText()
                      keyCatcher.forceActiveFocus()
                    }
                    Keys.onReturnPressed: function(event) {
                      event.accepted = true
                      root.saveAltText()
                    }
                    Keys.onEnterPressed: function(event) {
                      event.accepted = true
                      root.saveAltText()
                    }
                  }

                  Button {
                    id: altSave
                    text: root.savingAlt ? "..." : "Save"
                    bordered: true
                    focusable: true
                    enabled: !root.savingAlt && root.altPath !== ""
                    foreground: root.contentForeground
                    fontFamily: root.contentFontFamily
                    onClicked: root.saveAltText()
                  }

                  Button {
                    id: altDiscard
                    text: "Cancel"
                    bordered: true
                    focusable: true
                    enabled: !root.savingAlt
                    foreground: root.contentForeground
                    fontFamily: root.contentFontFamily
                    onClicked: {
                      root.closeAltText()
                      keyCatcher.forceActiveFocus()
                    }
                  }
                }

                Text {
                  width: parent.width
                  visible: root.altError !== ""
                  text: root.altError
                  color: Color.urgent
                  wrapMode: Text.WordWrap
                  font.family: root.contentFontFamily
                  font.pixelSize: Style.font.caption
                }
              }
            }

            // Buttons from the left, the counter against the right edge. A Row
            // cannot do this on its own: the free space in a Row is only known
            // after the last child has been placed, so the counter would have
            // to be anchored inside the positioner.
            Item {
              id: composerActions
              width: parent.width
              height: Math.max(buttonRow.implicitHeight, composerCounter.height)

              Row {
                id: buttonRow
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
                spacing: Style.space(8)

                Button {
                  text: root.posting ? "Posting..." : "Post"
                  bordered: true
                  focusable: true
                  enabled: !root.posting && !root.busyWithMedia && root.canPost
                  foreground: root.contentForeground
                  fontFamily: root.contentFontFamily
                  onClicked: root.postStatus()
                }

                Button {
                  text: root.busyWithMedia ? "Adding..." : "Image"
                  bordered: true
                  focusable: true
                  enabled: !root.busyWithMedia
                  foreground: root.contentForeground
                  fontFamily: root.contentFontFamily
                  onClicked: root.attachImages()
                }

                Button {
                  visible: root.replyToId !== ""
                  text: "Cancel"
                  foreground: root.contentForeground
                  fontFamily: root.contentFontFamily
                  onClicked: root.cancelReply()
                }

                Text {
                  anchors.verticalCenter: parent.verticalCenter
                  visible: root.postError !== ""
                  text: root.postError
                  color: Color.urgent
                  font.family: root.contentFontFamily
                  font.pixelSize: Style.font.caption
                }
              }

              Text {
                id: composerCounter
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                text: root.composerLength + "/" + root.maxCharacters
                color: root.composerLength >= root.maxCharacters
                  ? Color.urgent
                  : Qt.darker(root.contentForeground, 1.7)
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.caption
              }
            }
          }
        }
      }

      Flickable {
        id: scroll
        anchors.top: fixedTop.bottom
        anchors.topMargin: Style.space(8)
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        clip: true
        contentWidth: width
        contentHeight: contentColumn.implicitHeight
        boundsBehavior: Flickable.StopAtBounds
        onContentYChanged: root.maybeLoadMore()
        interactive: contentHeight > height

        Column {
          id: contentColumn
          width: scroll.width
          spacing: Style.space(8)

          Text {
            visible: root.authed && root.loadingFeed
            width: parent.width
            text: "Loading..."
            color: Qt.darker(root.contentForeground, 1.5)
            font.family: root.contentFontFamily
            font.pixelSize: Style.font.caption
          }

          Text {
            visible: root.authed && !root.loadingFeed && root.feedError !== ""
            width: parent.width
            text: root.feedError
            color: Color.urgent
            font.family: root.contentFontFamily
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
          }

          Repeater {
            visible: root.authed && !root.loadingFeed && !root.feedEmpty
            model: root.currentTab === 0 ? root.homeTimeline : (root.currentTab === 1 ? root.localTimeline : root.mentions)

            Item {
              id: statusDelegate
              required property var modelData
              // A boost wraps the original post in .reblog; the outer status
              // carries no content or media_attachments of its own, so every
              // read below goes through the unwrapped status instead of
              // modelData directly. Without this, boosted posts rendered
              // blank text and no images.
              readonly property var status: Model.displayStatus(modelData)
              readonly property var reblogger: Model.reblogger(modelData)
              // Single source of truth: the grid, the column count and the
              // alt text all read this one list. Deriving them from separate
              // statusMedia() calls let the grid end up populated while the
              // card believed it had no media, which collapsed the card to the
              // text height and let the image spill past the card and the
              // window edge.
              readonly property var media: Model.statusMedia(statusDelegate.status)
              readonly property int mediaCount: media.length
              // A link-share post (the common RSS-bot pattern) carries no
              // media_attachments of its own; the only image is Mastodon's
              // cached OpenGraph preview of the linked page, in status.card.
              // Only looked up when there is no real attachment, since an
              // actual upload always takes priority over the link preview.
              readonly property var linkCard: mediaCount === 0 ? Model.statusCard(statusDelegate.status) : null
              readonly property bool sensitive: statusDelegate.status.sensitive === true
              readonly property bool mediaVisible: mediaCount > 0 && (!sensitive || mediaRevealed)
              readonly property bool cardVisible: linkCard !== null && (!sensitive || mediaRevealed)
              property bool mediaRevealed: false
              width: parent.width
              height: statusCard.implicitHeight
              implicitHeight: statusCard.implicitHeight

              Rectangle {
                id: statusCard
                width: parent.width
                height: statusColumn.implicitHeight + Style.space(12)
                implicitHeight: statusColumn.implicitHeight + Style.space(12)
                radius: Style.cornerRadius
                color: Style.controlFill(false, false, root.contentForeground, Color.accent)

                Column {
                  id: statusColumn
                  anchors.left: parent.left
                  anchors.right: parent.right
                  anchors.leftMargin: Style.space(10)
                  anchors.rightMargin: Style.space(10)
                  anchors.topMargin: Style.space(6)
                  anchors.bottomMargin: Style.space(6)
                  spacing: Style.space(4)

                  Text {
                    width: parent.width
                    visible: statusDelegate.reblogger !== null
                    // visible: false does not skip evaluating text in QML, so
                    // this has to guard the null case itself instead of
                    // relying on visibility — accountDisplayName(null) throws
                    // and that broke the implicitHeight of every card below,
                    // which is why images went missing on unrelated posts.
                    text: statusDelegate.reblogger !== null
                      ? ("\uf079 " + Model.accountDisplayName(statusDelegate.reblogger) + " boosted")
                      : ""
                    color: Qt.darker(root.contentForeground, 1.5)
                    font.family: root.contentFontFamily
                    font.pixelSize: Style.font.caption
                    elide: Text.ElideRight
                  }

                  Row {
                    width: parent.width
                    spacing: Style.space(6)

                    Text {
                      text: Model.accountDisplayName(statusDelegate.status.account)
                      color: root.contentForeground
                      font.family: root.contentFontFamily
                      font.pixelSize: Style.font.bodySmall
                      font.bold: true
                      elide: Text.ElideRight
                    }

                    Text {
                      anchors.verticalCenter: parent.verticalCenter
                      text: Model.accountHandle(statusDelegate.status.account)
                      color: Qt.darker(root.contentForeground, 1.5)
                      font.family: root.contentFontFamily
                      font.pixelSize: Style.font.caption
                      elide: Text.ElideRight
                    }

                    Text {
                      anchors.verticalCenter: parent.verticalCenter
                      text: Model.formatTime(statusDelegate.status.created_at)
                      color: Qt.darker(root.contentForeground, 1.7)
                      font.family: root.contentFontFamily
                      font.pixelSize: Style.font.caption
                    }

                    Item { width: Style.space(4) }

                    Button {
                      visible: !root.isFollowing(statusDelegate.status.account?.id)
                      text: "Follow"
                      bordered: true
                      focusable: true
                      foreground: root.contentForeground
                      fontFamily: root.contentFontFamily
                      onClicked: root.toggleFollow(statusDelegate.status.account)
                    }
                  }

                  // RichText ignores the item's color property and falls back
                  // to black, which is unreadable on the bar, so both colours
                  // are inlined by statusRichText instead.
                  Text {
                    width: parent.width
                    textFormat: Text.RichText
                    text: Model.statusRichText(
                      statusDelegate.status,
                      String(root.contentForeground),
                      String(Color.accent))
                    color: root.contentForeground
                    font.family: root.contentFontFamily
                    font.pixelSize: Style.font.body
                    wrapMode: Text.WordWrap
                    onLinkActivated: function(url) {
                      if (Model.safeHttpUrl(url) !== "") Qt.openUrlExternally(url)
                    }
                  }

                  Button {
                    visible: statusDelegate.sensitive && !statusDelegate.mediaRevealed
                      && (statusDelegate.mediaCount > 0 || statusDelegate.linkCard !== null)
                    text: "Show media"
                    bordered: true
                    focusable: true
                    foreground: root.contentForeground
                    fontFamily: root.contentFontFamily
                    onClicked: statusDelegate.mediaRevealed = true
                  }

                  Grid {
                    id: mediaGrid
                    width: parent.width
                    visible: statusDelegate.mediaVisible
                    columns: statusDelegate.mediaCount > 1 ? 2 : 1
                    spacing: Style.space(4)

                    readonly property real cellWidth: (width - spacing * (columns - 1)) / columns
                    readonly property real cellHeight: columns > 1 ? Style.space(96) : Style.space(150)
                    readonly property int rows: Math.ceil(statusDelegate.mediaCount / columns)
                    // Explicit rather than implicit: an invisible item adds
                    // nothing to the parent Column's implicitHeight, so relying
                    // on the positioner's own size is what let the image escape
                    // the card whenever the visible binding was momentarily
                    // false while the media was already there.
                    height: rows > 0 ? rows * cellHeight + (rows - 1) * spacing : 0

                    Repeater {
                      model: statusDelegate.media

                      Rectangle {
                        required property var modelData
                        width: mediaGrid.cellWidth
                        height: mediaGrid.cellHeight
                        radius: Style.cornerRadius
                        color: Style.controlFill(false, false, root.contentForeground, Color.accent)
                        clip: true

                        Image {
                          anchors.fill: parent
                          source: modelData.url
                          fillMode: Image.PreserveAspectCrop
                          asynchronous: true
                          smooth: true
                          cache: true
                        }

                        MouseArea {
                          anchors.fill: parent
                          hoverEnabled: true
                          cursorShape: Qt.PointingHandCursor
                          onClicked: Qt.openUrlExternally(modelData.fullUrl)
                        }
                      }
                    }
                  }

                  Rectangle {
                    id: linkCardRect
                    width: parent.width
                    visible: statusDelegate.cardVisible
                    // Explicit height, 0 when hidden: same reasoning as the
                    // media grid above — an invisible item with no height
                    // still reports one to the Column, which pushes every
                    // card below it down by an empty gap.
                    height: statusDelegate.cardVisible ? Style.space(150) : 0
                    radius: Style.cornerRadius
                    color: Style.controlFill(false, false, root.contentForeground, Color.accent)
                    clip: true

                    Image {
                      anchors.fill: parent
                      source: statusDelegate.cardVisible ? statusDelegate.linkCard.image : ""
                      fillMode: Image.PreserveAspectCrop
                      asynchronous: true
                      smooth: true
                      cache: true
                    }

                    MouseArea {
                      anchors.fill: parent
                      hoverEnabled: true
                      cursorShape: Qt.PointingHandCursor
                      onClicked: {
                        var url = statusDelegate.linkCard ? statusDelegate.linkCard.url : ""
                        if (url !== "") Qt.openUrlExternally(url)
                      }
                    }
                  }

                  Text {
                    width: parent.width
                    readonly property string altText: {
                      var parts = []
                      for (var i = 0; i < statusDelegate.media.length; i++) {
                        if (statusDelegate.media[i].description !== "")
                          parts.push(statusDelegate.media[i].description)
                      }
                      return parts.join("  ·  ")
                    }
                    text: altText
                    visible: statusDelegate.mediaVisible && altText !== ""
                    color: Qt.darker(root.contentForeground, 1.7)
                    font.family: root.contentFontFamily
                    font.pixelSize: Style.font.caption
                    wrapMode: Text.WordWrap
                  }

                  Row {
                    spacing: Style.space(4)

                    PanelActionButton {
                      iconText: "\uf112"
                      tooltipText: "Reply"
                      foreground: root.contentForeground
                      fontFamily: root.contentFontFamily
                      onClicked: root.startReply(statusDelegate.status)
                    }

                    PanelActionButton {
                      iconText: "\uf079"
                      tooltipText: statusDelegate.status.reblogged ? "Unreblog" : "Reblog"
                      foreground: statusDelegate.status.reblogged ? Color.accent : root.contentForeground
                      fontFamily: root.contentFontFamily
                      onClicked: root.toggleReblog(statusDelegate.status)
                    }

                    PanelActionButton {
                      iconText: "\uf004"
                      tooltipText: statusDelegate.status.favourited ? "Unfavourite" : "Favourite"
                      foreground: statusDelegate.status.favourited ? Color.accent : root.contentForeground
                      fontFamily: root.contentFontFamily
                      onClicked: root.toggleFavourite(statusDelegate.status)
                    }

                    PanelActionButton {
                      iconText: "\uf02e"
                      tooltipText: statusDelegate.status.bookmarked ? "Unbookmark" : "Bookmark"
                      foreground: statusDelegate.status.bookmarked ? Color.accent : root.contentForeground
                      fontFamily: root.contentFontFamily
                      onClicked: root.toggleBookmark(statusDelegate.status)
                    }
                  }
                }
              }
            }
          }

          Text {
            width: parent.width
            visible: root.authed && !root.loadingFeed && root.feedEmpty && root.feedError === ""
            // An empty Local tab is normal on instances that throttle the
            // public timeline, so say which tab is empty instead of leaving a
            // blank panel.
            text: root.currentTab === 0 ? "No posts in your home timeline"
              : (root.currentTab === 1 ? "No public posts on this instance"
                : "No mentions")
            color: Qt.darker(root.contentForeground, 1.7)
            font.family: root.contentFontFamily
            font.pixelSize: Style.font.caption
            horizontalAlignment: Text.AlignHCenter
          }

          Text {
            width: parent.width
            visible: root.authed && !root.loadingFeed && !root.feedEmpty
            text: root.feedError !== "" ? root.feedError
              : (root.loadingMore ? "Loading older posts…"
                : (root.hasMore ? "Scroll for more" : "No older posts"))
            color: Qt.darker(root.contentForeground, 1.7)
            font.family: root.contentFontFamily
            font.pixelSize: Style.font.caption
            horizontalAlignment: Text.AlignHCenter
          }
        }
      }
    }
  }

  Process {
    id: verifyProc
    stdout: StdioCollector {
      id: verifyOut
      waitForEnd: true
    }
    onExited: function(exitCode) {
      root.onVerifyExited(exitCode)
    }
  }

  Process {
    id: instanceProc
    stdout: StdioCollector {
      id: instanceConfigOut
      waitForEnd: true
    }
    onExited: function(exitCode) {
      root.onInstanceConfigExited(exitCode)
    }
  }

  Process {
    id: homeProc
    stdout: StdioCollector {
      id: homeOut
      waitForEnd: true
    }
    onExited: function(exitCode) {
      root.onHomeExited(exitCode)
    }
  }

  Process {
    id: localProc
    stdout: StdioCollector {
      id: localOut
      waitForEnd: true
    }
    onExited: function(exitCode) {
      root.onLocalExited(exitCode)
    }
  }

  Process {
    id: mentionsProc
    stdout: StdioCollector {
      id: mentionsOut
      waitForEnd: true
    }
    onExited: function(exitCode) {
      root.onMentionsExited(exitCode)
    }
  }

  Process {
    id: moreHomeProc
    stdout: StdioCollector {
      id: moreHomeOut
      waitForEnd: true
    }
    onExited: function(exitCode) {
      root.onMoreHomeExited(exitCode)
    }
  }

  Process {
    id: moreLocalProc
    stdout: StdioCollector {
      id: moreLocalOut
      waitForEnd: true
    }
    onExited: function(exitCode) {
      root.onMoreLocalExited(exitCode)
    }
  }

  Process {
    id: moreMentionsProc
    stdout: StdioCollector {
      id: moreMentionsOut
      waitForEnd: true
    }
    onExited: function(exitCode) {
      root.onMoreMentionsExited(exitCode)
    }
  }

  Process {
    id: relProc
    stdout: StdioCollector {
      id: relOut
      waitForEnd: true
    }
    onExited: function(exitCode) {
      root.onRelExited(exitCode)
    }
  }

  Process {
    id: pickMediaProc
    stdout: StdioCollector {
      id: pickMediaOut
      waitForEnd: true
    }
    onExited: function(exitCode) {
      root.onPickMediaExited(exitCode)
    }
  }

  Process {
    id: uploadMediaProc
    stdout: StdioCollector {
      id: uploadMediaOut
      waitForEnd: true
    }
    onExited: function(exitCode) {
      root.onUploadMediaExited(exitCode)
    }
  }

  // Its own process, rather than a second upload channel: an alt text is a
  // form field on an attachment, not a file, so it needs no path in the
  // environment and nothing is read from the reply but the exit code.
  Process {
    id: describeProc
    onExited: function(exitCode) {
      root.onDescribeExited(exitCode)
    }
  }

  Process {
    id: postProc
    stdout: StdioCollector {
      id: postOut
      waitForEnd: true
    }
    onExited: function(exitCode) {
      root.onPostExited(exitCode)
    }
  }

  Process {
    id: actionProc
    onExited: function(exitCode) {
      root.onActionExited(exitCode)
    }
  }
}
