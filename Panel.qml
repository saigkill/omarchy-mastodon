import QtQuick
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
  readonly property string accessToken: auth.accessToken || ""

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
    root.loadTimelines()
  }

  function loadCurrentUser() {
    if (!root.authed) return
    var cmd = Model.verifyCredentialsCmd(root.instance, root.accessToken)
    verifyProc.command = cmd
    verifyProc.running = true
  }

  function onVerifyExited(exitCode) {
    var parsed = Model.parseJson(verifyOut.text)
    if (parsed) root.currentUser = parsed
  }

  // The panel object outlives the login that populated it, and a shell restart
  // rebuilds it empty, so an empty feed is filled on the first open. A feed that
  // already has entries is left alone to avoid a request on every open.
  onOpenedChanged: {
    if (!root.opened || !root.authed) return
    if (root.loadingFeed || !root.feedEmpty) return
    root.loadCurrentUser()
    root.loadTimelines()
  }

  function loadTimelines() {
    if (!root.authed) return
    root.loadingFeed = true
    root.feedError = ""
    var homeCmd = Model.homeTimelineCmd(root.instance, root.accessToken)
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
    var localCmd = Model.localTimelineCmd(root.instance, root.accessToken)
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
    var mentionsCmd = Model.mentionsCmd(root.instance, root.accessToken)
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
        root.instance, root.accessToken, Model.oldestId(root.homeTimeline))
      moreHomeProc.running = true
    } else if (root.currentTab === 1) {
      moreLocalProc.command = Model.localTimelineCmd(
        root.instance, root.accessToken, Model.oldestId(root.localTimeline))
      moreLocalProc.running = true
    } else {
      moreMentionsProc.command = Model.mentionsCmd(
        root.instance, root.accessToken, Model.oldestId(root.mentions))
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
      var id = statuses[i].account.id
      if (ids.indexOf(id) === -1) ids.push(id)
    }
    if (ids.length === 0) return
    var relCmd = Model.relationshipCmd(root.instance, root.accessToken, ids[0])
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
    if (text === "" || root.posting) return
    root.posting = true
    root.postError = ""
    var cmd = Model.postStatusCmd(root.instance, root.accessToken, text, root.replyToId || null)
    postProc.command = cmd
    postProc.running = true
  }

  function onPostExited(exitCode) {
    root.posting = false
    var parsed = Model.parseJson(postOut.text)
    if (parsed && parsed.id) {
      root.composerText = ""
      root.replyToId = ""
      root.replyToUser = ""
      root.loadTimelines()
    } else {
      root.postError = "Failed to post"
    }
  }

  function toggleReblog(status) {
    var cmd = status.reblogged
      ? Model.unreblogCmd(root.instance, root.accessToken, status.id)
      : Model.reblogCmd(root.instance, root.accessToken, status.id)
    actionProc.command = cmd
    actionProc.running = true
  }

  function toggleFavourite(status) {
    var cmd = status.favourited
      ? Model.unfavouriteCmd(root.instance, root.accessToken, status.id)
      : Model.favouriteCmd(root.instance, root.accessToken, status.id)
    actionProc.command = cmd
    actionProc.running = true
  }

  function toggleBookmark(status) {
    var cmd = status.bookmarked
      ? Model.unbookmarkCmd(root.instance, root.accessToken, status.id)
      : Model.bookmarkCmd(root.instance, root.accessToken, status.id)
    actionProc.command = cmd
    actionProc.running = true
  }

  function toggleFollow(account) {
    var cmd = root.isFollowing(account.id)
      ? Model.unfollowCmd(root.instance, root.accessToken, account.id)
      : Model.followCmd(root.instance, root.accessToken, account.id)
    actionProc.command = cmd
    actionProc.running = true
  }

  function onActionExited(exitCode) {
    root.loadTimelines()
  }

  function startReply(status) {
    root.replyToId = status.id
    root.replyToUser = Model.accountHandle(status.account)
    root.composerText = ""
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
    root.composerText = ""
    if (keyCatcher) keyCatcher.forceActiveFocus()
  }

  function logout() {
    if (root.hostWidget) root.hostWidget.clearAuth()
    root.currentUser = null
    root.homeTimeline = []
    root.localTimeline = []
    root.mentions = []
    root.relationships = {}
    root.composerText = ""
    root.replyToId = ""
    root.replyToUser = ""
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
              iconText: "\uf09b"
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

              TextEdit {
                id: composerInput
                anchors.fill: parent
                anchors.margins: Style.space(8)
                text: root.composerText
                color: root.contentForeground
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.body
                wrapMode: TextEdit.Wrap
                selectByMouse: true
                onTextEdited: root.composerText = text
                Keys.onEscapePressed: function(event) {
                  if (root.replyToId !== "") root.cancelReply()
                  keyCatcher.forceActiveFocus()
                  event.accepted = true
                }
              }
            }

            Row {
              spacing: Style.space(8)

              Button {
                text: root.posting ? "Posting..." : "Post"
                bordered: true
                focusable: true
                enabled: !root.posting && root.composerText.trim() !== ""
                foreground: root.contentForeground
                fontFamily: root.contentFontFamily
                onClicked: root.postStatus()
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
              // Single source of truth: the grid, the column count and the
              // alt text all read this one list. Deriving them from separate
              // statusMedia() calls let the grid end up populated while the
              // card believed it had no media, which collapsed the card to the
              // text height and let the image spill past the card and the
              // window edge.
              readonly property var media: Model.statusMedia(modelData.status || modelData)
              readonly property int mediaCount: media.length
              readonly property bool sensitive: (modelData.status || modelData).sensitive === true
              readonly property bool mediaVisible: mediaCount > 0 && (!sensitive || mediaRevealed)
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

                  Row {
                    width: parent.width
                    spacing: Style.space(6)

                    Text {
                      text: Model.accountDisplayName(modelData.account || modelData.status?.account)
                      color: root.contentForeground
                      font.family: root.contentFontFamily
                      font.pixelSize: Style.font.bodySmall
                      font.bold: true
                      elide: Text.ElideRight
                    }

                    Text {
                      anchors.verticalCenter: parent.verticalCenter
                      text: Model.accountHandle(modelData.account || modelData.status?.account)
                      color: Qt.darker(root.contentForeground, 1.5)
                      font.family: root.contentFontFamily
                      font.pixelSize: Style.font.caption
                      elide: Text.ElideRight
                    }

                    Text {
                      anchors.verticalCenter: parent.verticalCenter
                      text: Model.formatTime(modelData.created_at || modelData.status?.created_at)
                      color: Qt.darker(root.contentForeground, 1.7)
                      font.family: root.contentFontFamily
                      font.pixelSize: Style.font.caption
                    }

                    Item { width: Style.space(4) }

                    Button {
                      visible: !root.isFollowing((modelData.account || modelData.status?.account)?.id)
                      text: "Follow"
                      bordered: true
                      focusable: true
                      foreground: root.contentForeground
                      fontFamily: root.contentFontFamily
                      onClicked: root.toggleFollow(modelData.account || modelData.status?.account)
                    }
                  }

                  // RichText ignores the item's color property and falls back
                  // to black, which is unreadable on the bar, so both colours
                  // are inlined by statusRichText instead.
                  Text {
                    width: parent.width
                    textFormat: Text.RichText
                    text: Model.statusRichText(
                      modelData.status || modelData,
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
                      iconText: "\uf079"
                      tooltipText: "Reply"
                      foreground: root.contentForeground
                      fontFamily: root.contentFontFamily
                      onClicked: root.startReply(modelData.status || modelData)
                    }

                    PanelActionButton {
                      iconText: "\uf0e4"
                      tooltipText: (modelData.status || modelData).reblogged ? "Unreblog" : "Reblog"
                      foreground: (modelData.status || modelData).reblogged ? Color.accent : root.contentForeground
                      fontFamily: root.contentFontFamily
                      onClicked: root.toggleReblog(modelData.status || modelData)
                    }

                    PanelActionButton {
                      iconText: "\uf004"
                      tooltipText: (modelData.status || modelData).favourited ? "Unfavourite" : "Favourite"
                      foreground: (modelData.status || modelData).favourited ? Color.accent : root.contentForeground
                      fontFamily: root.contentFontFamily
                      onClicked: root.toggleFavourite(modelData.status || modelData)
                    }

                    PanelActionButton {
                      iconText: "\uf02e"
                      tooltipText: (modelData.status || modelData).bookmarked ? "Unbookmark" : "Bookmark"
                      foreground: (modelData.status || modelData).bookmarked ? Color.accent : root.contentForeground
                      fontFamily: root.contentFontFamily
                      onClicked: root.toggleBookmark(modelData.status || modelData)
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
