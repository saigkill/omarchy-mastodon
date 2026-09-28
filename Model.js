// The app name and website are only ever sent to a Mastodon instance during
// app registration, which now happens entirely inside mastodon_helper.py, so
// they are declared there and nowhere else. APP_SCOPES stays here too: the
// panel needs it to build the browser authorize URL.
var APP_SCOPES = "read write follow"
var PAGE_SIZE = 40
var MAX_MEDIA_PER_STATUS = 4

// ------------------------------------------------------------------- instance
//
// The panel used to hand curl a bearer token, a client secret and the OAuth
// authorization code as command line arguments, and shelled out via `sh -c`
// to write the state file. Command lines live in /proc/<pid>/cmdline, which
// is world-readable, so every local process could read a Mastodon account's
// credentials. All of that now lives in mastodon_helper.py: the panel only
// ever passes it non-secret arguments (an endpoint, a status, a redirect
// URI), and the helper itself owns the 0600 state file that holds the
// client secret and the access token.
//
// normalizeInstance is the last line of defence against sending a token
// somewhere it does not belong: it accepts only https, or http to a name
// that really is this machine (the OAuth loopback callback), and rejects a
// userinfo component that could make a host look like it belongs to the
// user when it does not.

function isLoopbackHost(host) {
  var text = String(host || "").toLowerCase()
  if (text === "") return false
  if (text === "localhost") return true
  if (text === "::1") return true
  var match = /^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$/.exec(text)
  if (!match) return false
  for (var i = 1; i <= 4; i++) {
    if (Number(match[i]) > 255) return false
  }
  return Number(match[1]) === 127
}

// Splits "scheme://authority/rest" without relying on a URL constructor
// (not reliably available in the QML JS engine). Only http/https survive;
// any other explicit scheme (ftp:, javascript:, file:) is refused outright
// instead of being coerced, since prefixing "https://" onto an already
// schemed string would smuggle the original scheme into the host portion.
function normalizeInstance(input) {
  var text = String(input || "").trim().toLowerCase()
  if (text === "") return ""

  var explicitScheme = /^([a-z][a-z0-9+.-]*):/i.exec(text)
  if (explicitScheme) {
    if (explicitScheme[1] !== "http" && explicitScheme[1] !== "https") return ""
  } else {
    text = "https://" + text
  }

  var parsed = /^(https?):\/\/(.*)$/i.exec(text)
  if (!parsed) return ""
  var scheme = parsed[1]
  var afterScheme = parsed[2]

  var slash = afterScheme.indexOf("/")
  var authority = slash === -1 ? afterScheme : afterScheme.substring(0, slash)
  var rest = slash === -1 ? "" : afterScheme.substring(slash)

  // A userinfo component ("host@evil.example") makes the real host look
  // like a username, which is a classic phishing trick against naive host
  // parsing, so authority is refused outright the moment it contains one.
  if (authority === "" || authority.indexOf("@") !== -1) return ""

  var host
  if (authority.charAt(0) === "[") {
    var close = authority.indexOf("]")
    if (close === -1) return ""
    host = authority.substring(1, close)
  } else {
    var colon = authority.indexOf(":")
    host = colon === -1 ? authority : authority.substring(0, colon)
  }
  if (host === "") return ""

  // https is always fine. Plaintext http only survives for the loopback
  // OAuth callback; a token or a private timeline must never go out on the
  // wire to anything else.
  if (scheme === "http" && !isLoopbackHost(host)) return ""

  return (scheme + "://" + authority + rest).replace(/\/+$/, "")
}

// Used only to show the address the user typed back to them (e.g. in a
// tooltip while login is failing). Unlike normalizeInstance this never
// rejects anything, so it must never be used to decide where a request is
// allowed to go.
function displayInstance(input) {
  var text = String(input || "").trim().toLowerCase()
  if (text === "") return ""
  if (!/^https?:\/\//i.test(text)) text = "https://" + text
  return text.replace(/\/+$/, "")
}

function randomPort() {
  return 49152 + Math.floor(Math.random() * 16000)
}

function callbackUri(port) {
  return "http://127.0.0.1:" + Number(port)
}

// ------------------------------------------------------------- helper commands
//
// Every command below runs mastodon_helper.py, never curl and never a shell.
// The instance, the client secret and the access token are not passed as
// arguments; the helper reads them from its own state file. The one-time
// OAuth authorization code is handed over through the MASTODON_AUTH_JSON /
// MASTODON_OAUTH_CODE environment variables instead of argv, since
// /proc/<pid>/environ (unlike /proc/<pid>/cmdline) is readable only by the
// owning user.

// Older pages are fetched with max_id, which returns statuses strictly older
// than the given id, so paging never repeats the current last entry.
function pagedUrl(endpoint, maxId) {
  var separator = endpoint.indexOf("?") === -1 ? "?" : "&"
  var url = endpoint + separator + "limit=" + PAGE_SIZE
  if (maxId) url += "&max_id=" + encodeURIComponent(String(maxId))
  return url
}

function loadCmd(helper) {
  return [helper, "load"]
}

function saveCmd(helper) {
  return [helper, "save"]
}

function logoutCmd(helper) {
  return [helper, "logout"]
}

function registerAppCmd(helper, redirectUri) {
  return [helper, "register", redirectUri]
}

function exchangeTokenCmd(helper, redirectUri) {
  return [helper, "exchange", redirectUri]
}

function verifyCredentialsCmd(helper) {
  return [helper, "get", "/api/v1/accounts/verify_credentials"]
}

function homeTimelineCmd(helper, maxId) {
  return [helper, "get", pagedUrl("/api/v1/timelines/home", maxId)]
}

function localTimelineCmd(helper, maxId) {
  return [helper, "get", pagedUrl("/api/v1/timelines/public?local=true", maxId)]
}

function mentionsCmd(helper, maxId) {
  return [helper, "get", pagedUrl("/api/v1/notifications?types[]=mention", maxId)]
}

function relationshipCmd(helper, id) {
  return [helper, "get", "/api/v1/accounts/relationships[]=" + id]
}

function postStatusCmd(helper, text, inReplyToId) {
  var cmd = [helper, "post", "/api/v1/statuses", "status=" + text]
  if (inReplyToId) cmd.push("in_reply_to_id=" + inReplyToId)
  return cmd
}

function reblogCmd(helper, id) {
  return [helper, "post", "/api/v1/statuses/" + id + "/reblog"]
}

function unreblogCmd(helper, id) {
  return [helper, "post", "/api/v1/statuses/" + id + "/unreblog"]
}

function favouriteCmd(helper, id) {
  return [helper, "post", "/api/v1/statuses/" + id + "/favourite"]
}

function unfavouriteCmd(helper, id) {
  return [helper, "post", "/api/v1/statuses/" + id + "/unfavourite"]
}

function bookmarkCmd(helper, id) {
  return [helper, "post", "/api/v1/statuses/" + id + "/bookmark"]
}

function unbookmarkCmd(helper, id) {
  return [helper, "post", "/api/v1/statuses/" + id + "/unbookmark"]
}

function followCmd(helper, id) {
  return [helper, "post", "/api/v1/accounts/" + id + "/follow"]
}

function unfollowCmd(helper, id) {
  return [helper, "post", "/api/v1/accounts/" + id + "/unfollow"]
}

function parseJson(text) {
  try {
    return JSON.parse(String(text || ""))
  } catch (error) {
    return null
  }
}

function stripHtml(html) {
  var text = String(html || "")
  text = text.replace(/<br\s*\/?>/gi, "\n")
  text = text.replace(/<\/p>/gi, "\n\n")
  text = text.replace(/<[^>]+>/g, "")
  text = text.replace(/&amp;/g, "&")
  text = text.replace(/&lt;/g, "<")
  text = text.replace(/&gt;/g, ">")
  text = text.replace(/&quot;/g, '"')
  text = text.replace(/&#39;/g, "'")
  text = text.replace(/&nbsp;/g, " ")
  return text.replace(/^\s+|\s+$/g, "")
}

function formatTime(iso) {
  var date = new Date(iso)
  if (isNaN(date.getTime())) return ""
  var now = new Date()
  var diff = now.getTime() - date.getTime()
  var minutes = Math.floor(diff / 60000)
  if (minutes < 1) return "now"
  if (minutes < 60) return minutes + "m"
  var hours = Math.floor(minutes / 60)
  if (hours < 24) return hours + "h"
  var days = Math.floor(hours / 24)
  if (days < 7) return days + "d"
  return date.toLocaleDateString()
}

function accountDisplayName(account) {
  var name = String(account.display_name || "").trim()
  if (name === "") name = String(account.username || "")
  return name
}

function accountHandle(account) {
  var acct = String(account.acct || "")
  if (acct.indexOf("@") === -1 && account.url) {
    try {
      var host = new URL(account.url).hostname
      acct = acct + "@" + host
    } catch (error) {}
  }
  return acct
}

function statusText(status) {
  return stripHtml(status.content)
}

function statusUrl(status) {
  return String(status.url || "")
}

// Only http(s) is handed to Qt.openUrlExternally. Statuses are attacker
// controlled, so javascript:, file: and data: URLs must never survive.
function safeHttpUrl(url) {
  var text = String(url || "").trim()
  return /^https?:\/\//i.test(text) ? text : ""
}

// &amp; is decoded last so that an escaped "&amp;lt;" stays the literal text
// "&lt;" instead of collapsing into a tag.
function decodeEntities(text) {
  return String(text || "")
    .replace(/&lt;/g, "<")
    .replace(/&gt;/g, ">")
    .replace(/&quot;/g, '"')
    .replace(/&#39;/g, "'")
    .replace(/&nbsp;/g, " ")
    .replace(/&amp;/g, "&")
}

function escapeHtml(text) {
  return String(text || "")
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;")
}

// Rebuilds Mastodon's HTML into a QML RichText subset: paragraph and line
// breaks survive, every other tag is dropped, and <a> is the only markup kept.
// Colours are inlined because RichText ignores the item's color property and
// would otherwise fall back to black on a dark bar.
function statusRichText(status, baseColor, linkColor) {
  var html = String(status.content || "")

  html = html.replace(/<br\s*\/?>/gi, "\n")
  html = html.replace(/<\/p>\s*<p[^>]*>/gi, "\n\n")
  html = html.replace(/<p[^>]*>/gi, "")
  html = html.replace(/<\/p>/gi, "")

  // Lift the anchors out before the remaining markup is stripped, otherwise
  // the hrefs are lost. The placeholder survives stripping and escaping
  // because it uses control characters no status text can contain.
  var links = []
  html = html.replace(
    /<a\b[^>]*href\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+))[^>]*>([\s\S]*?)<\/a>/gi,
    function (all, quoted, single, bare, label) {
      var url = safeHttpUrl(decodeEntities(quoted || single || bare || ""))
      links.push({ url: url, label: stripHtml(label) })
      return "\u0001LINK" + (links.length - 1) + "\u0001"
    })

  var text = escapeHtml(stripHtml(html))
  for (var i = 0; i < links.length; i++) {
    // An anchor whose href failed the scheme check still has to be replaced,
    // otherwise its placeholder would surface as literal text in the post.
    var replacement = escapeHtml(links[i].label)
    if (links[i].url !== "") {
      replacement = '<a href="' + escapeHtml(links[i].url) + '">'
        + '<font color="' + escapeHtml(linkColor || "#7aa2f7") + '">'
        + escapeHtml(links[i].label) + "</font></a>"
    }
    text = text.split("\u0001LINK" + i + "\u0001").join(replacement)
  }

  return '<font color="' + escapeHtml(baseColor || "#ffffff") + '">' + text + "</font>"
}

// preview_url is a smaller derivative of the original, which keeps the feed
// responsive; url is kept for opening the full-size image.
function statusMedia(status) {
  var attachments = status.media_attachments
  var out = []
  // QML hands arrays on to functions as QVariantList, for which
  // Array.isArray() is false. Duck-type on length instead.
  if (!attachments || typeof attachments.length !== "number") return out
  for (var i = 0; i < attachments.length && i < MAX_MEDIA_PER_STATUS; i++) {
    var attachment = attachments[i]
    if (!attachment) continue
    var preview = safeHttpUrl(attachment.preview_url)
    var full = safeHttpUrl(attachment.url)
    var source = preview || full
    if (source === "") continue
    out.push({
      url: source,
      fullUrl: full || source,
      description: String(attachment.description || "")
    })
  }
  return out
}

// Notifications wrap the status in .status, timeline entries are the status
// itself. Both carry an id, so one accessor covers timelines and mentions.
function entryId(entry) {
  var status = entry && entry.status ? entry.status : entry
  return status && status.id ? String(status.id) : ""
}

function oldestId(list) {
  if (!Array.isArray(list) || list.length === 0) return ""
  return entryId(list[list.length - 1])
}

// max_id pages can overlap by one entry on some servers, so appending has to
// de-duplicate instead of blindly concatenating.
function appendUnique(list, page) {
  var known = {}
  var merged = Array.isArray(list) ? list.slice() : []
  var i
  for (i = 0; i < merged.length; i++) known[entryId(merged[i])] = true
  if (!Array.isArray(page)) return merged
  for (i = 0; i < page.length; i++) {
    var id = entryId(page[i])
    if (id === "" || known[id]) continue
    known[id] = true
    merged.push(page[i])
  }
  return merged
}

// ----------------------------------------------------------------------- auth
//
// This is the panel's only view of the credentials: an instance, a public
// client id, and whether a token exists. The client secret and the access
// token are owned entirely by mastodon_helper.py and never cross back into
// the panel, so a bug or a crash here cannot leak either of them.

function emptyAuth() {
  return { instance: "", clientId: "", hasToken: false }
}

function decodeAuth(data) {
  if (!data || typeof data !== "object") return emptyAuth()
  // Built field by field instead of spread/assign, so a secret slipped into
  // the input object (e.g. a stale accessToken/clientSecret) cannot ride
  // along into the decoded result.
  return {
    instance: String(data.instance || ""),
    clientId: String(data.clientId || ""),
    hasToken: data.hasToken === true
  }
}

function isAuthed(auth) {
  return !!(auth && auth.instance && auth.hasToken === true)
}

function emptyData() {
  return { auth: emptyAuth() }
}

function decode(data) {
  if (!data || typeof data !== "object") return emptyData()
  return { auth: decodeAuth(data.auth) }
}

if (typeof module !== "undefined") {
  module.exports = {
    APP_SCOPES: APP_SCOPES,
    normalizeInstance: normalizeInstance,
    displayInstance: displayInstance,
    randomPort: randomPort,
    callbackUri: callbackUri,
    loadCmd: loadCmd,
    saveCmd: saveCmd,
    logoutCmd: logoutCmd,
    registerAppCmd: registerAppCmd,
    exchangeTokenCmd: exchangeTokenCmd,
    verifyCredentialsCmd: verifyCredentialsCmd,
    homeTimelineCmd: homeTimelineCmd,
    localTimelineCmd: localTimelineCmd,
    mentionsCmd: mentionsCmd,
    relationshipCmd: relationshipCmd,
    postStatusCmd: postStatusCmd,
    reblogCmd: reblogCmd,
    unreblogCmd: unreblogCmd,
    favouriteCmd: favouriteCmd,
    unfavouriteCmd: unfavouriteCmd,
    bookmarkCmd: bookmarkCmd,
    unbookmarkCmd: unbookmarkCmd,
    followCmd: followCmd,
    unfollowCmd: unfollowCmd,
    parseJson: parseJson,
    stripHtml: stripHtml,
    formatTime: formatTime,
    accountDisplayName: accountDisplayName,
    accountHandle: accountHandle,
    statusText: statusText,
    statusUrl: statusUrl,
    statusRichText: statusRichText,
    statusMedia: statusMedia,
    safeHttpUrl: safeHttpUrl,
    pagedUrl: pagedUrl,
    entryId: entryId,
    oldestId: oldestId,
    appendUnique: appendUnique,
    PAGE_SIZE: PAGE_SIZE,
    emptyAuth: emptyAuth,
    decodeAuth: decodeAuth,
    isAuthed: isAuthed,
    emptyData: emptyData,
    decode: decode
  }
}
