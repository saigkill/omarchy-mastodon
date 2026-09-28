var APP_NAME = "Omarchy Mastodon"
var APP_SCOPES = "read write follow"
var APP_WEBSITE = "https://github.com/saigkill/omarchy-mastodon1"
var PAGE_SIZE = 40
var MAX_MEDIA_PER_STATUS = 4

function normalizeInstance(input) {
  var text = String(input || "").trim().toLowerCase()
  if (text === "") return ""
  if (!/^https?:\/\//i.test(text)) text = "https://" + text
  return text.replace(/\/+$/, "")
}

function apiBase(instance) {
  return normalizeInstance(instance)
}

function authHeader(token) {
  return "Authorization: Bearer " + token
}

function curlGet(instance, endpoint, token) {
  return [
    "curl", "-sS", "-f",
    "-H", authHeader(token),
    apiBase(instance) + endpoint
  ]
}

function curlPost(instance, endpoint, token, fields) {
  var cmd = ["curl", "-sS", "-f", "-X", "POST", "-H", authHeader(token)]
  for (var key in fields) {
    cmd.push("-F")
    cmd.push(key + "=" + fields[key])
  }
  cmd.push(apiBase(instance) + endpoint)
  return cmd
}

function registerAppCmd(instance, redirectUri) {
  return [
    "curl", "-sS", "-f", "-X", "POST",
    "-F", "client_name=" + APP_NAME,
    "-F", "redirect_uris=" + redirectUri,
    "-F", "scopes=" + APP_SCOPES,
    "-F", "website=" + APP_WEBSITE,
    apiBase(instance) + "/api/v1/apps"
  ]
}

function exchangeTokenCmd(instance, clientId, clientSecret, code, redirectUri) {
  return [
    "curl", "-sS", "-f", "-X", "POST",
    "-F", "client_id=" + clientId,
    "-F", "client_secret=" + clientSecret,
    "-F", "grant_type=authorization_code",
    "-F", "code=" + code,
    "-F", "redirect_uri=" + redirectUri,
    apiBase(instance) + "/oauth/token"
  ]
}

function randomPort() {
  return 49152 + Math.floor(Math.random() * 16000)
}

function callbackUri(port) {
  return "http://127.0.0.1:" + Number(port)
}

function verifyCredentialsCmd(instance, token) {
  return curlGet(instance, "/api/v1/accounts/verify_credentials", token)
}

// Older pages are fetched with max_id, which returns statuses strictly older
// than the given id, so paging never repeats the current last entry.
function pagedUrl(endpoint, maxId) {
  var separator = endpoint.indexOf("?") === -1 ? "?" : "&"
  var url = endpoint + separator + "limit=" + PAGE_SIZE
  if (maxId) url += "&max_id=" + encodeURIComponent(String(maxId))
  return url
}

function homeTimelineCmd(instance, token, maxId) {
  return curlGet(instance, pagedUrl("/api/v1/timelines/home", maxId), token)
}

function localTimelineCmd(instance, token, maxId) {
  return curlGet(instance, pagedUrl("/api/v1/timelines/public?local=true", maxId), token)
}

function mentionsCmd(instance, token, maxId) {
  return curlGet(instance, pagedUrl("/api/v1/notifications?types[]=mention", maxId), token)
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

function postStatusCmd(instance, token, text, inReplyToId) {
  var fields = { status: text }
  if (inReplyToId) fields.in_reply_to_id = inReplyToId
  return curlPost(instance, "/api/v1/statuses", token, fields)
}

function reblogCmd(instance, token, id) {
  return curlPost(instance, "/api/v1/statuses/" + id + "/reblog", token, {})
}

function unreblogCmd(instance, token, id) {
  return curlPost(instance, "/api/v1/statuses/" + id + "/unreblog", token, {})
}

function favouriteCmd(instance, token, id) {
  return curlPost(instance, "/api/v1/statuses/" + id + "/favourite", token, {})
}

function unfavouriteCmd(instance, token, id) {
  return curlPost(instance, "/api/v1/statuses/" + id + "/unfavourite", token, {})
}

function bookmarkCmd(instance, token, id) {
  return curlPost(instance, "/api/v1/statuses/" + id + "/bookmark", token, {})
}

function unbookmarkCmd(instance, token, id) {
  return curlPost(instance, "/api/v1/statuses/" + id + "/unbookmark", token, {})
}

function followCmd(instance, token, id) {
  return curlPost(instance, "/api/v1/accounts/" + id + "/follow", token, {})
}

function unfollowCmd(instance, token, id) {
  return curlPost(instance, "/api/v1/accounts/" + id + "/unfollow", token, {})
}

function relationshipCmd(instance, token, id) {
  return curlGet(instance, "/api/v1/accounts/relationships[]=" + id, token)
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

function emptyAuth() {
  return { instance: "", clientId: "", clientSecret: "", accessToken: "" }
}

function decodeAuth(data) {
  if (!data || typeof data !== "object") return emptyAuth()
  return {
    instance: String(data.instance || ""),
    clientId: String(data.clientId || ""),
    clientSecret: String(data.clientSecret || ""),
    accessToken: String(data.accessToken || "")
  }
}

function isAuthed(auth) {
  return !!(auth && auth.instance && auth.accessToken)
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
    APP_NAME: APP_NAME,
    APP_SCOPES: APP_SCOPES,
    normalizeInstance: normalizeInstance,
    registerAppCmd: registerAppCmd,
    exchangeTokenCmd: exchangeTokenCmd,
    randomPort: randomPort,
    callbackUri: callbackUri,
    verifyCredentialsCmd: verifyCredentialsCmd,
    homeTimelineCmd: homeTimelineCmd,
    localTimelineCmd: localTimelineCmd,
    mentionsCmd: mentionsCmd,
    postStatusCmd: postStatusCmd,
    reblogCmd: reblogCmd,
    unreblogCmd: unreblogCmd,
    favouriteCmd: favouriteCmd,
    unfavouriteCmd: unfavouriteCmd,
    bookmarkCmd: bookmarkCmd,
    unbookmarkCmd: unbookmarkCmd,
    followCmd: followCmd,
    unfollowCmd: unfollowCmd,
    relationshipCmd: relationshipCmd,
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
