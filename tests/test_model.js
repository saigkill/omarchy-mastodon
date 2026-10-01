// Guards the one property the marketplace review objected to: no command line
// the panel builds may contain a credential, a host it has no business talking
// to, or a shell.
//
// Run with: node tests/test_model.js

const assert = require("assert")
const fs = require("fs")
const path = require("path")
const Model = require(path.join(__dirname, "..", "Model.js"))

const HELPER = "/plugin/mastodon_helper.py"
const SECRET_LIKE = [
  "access_token", "accessToken", "client_secret", "clientSecret",
  "Authorization", "Bearer", "code=",
]

let passed = 0
function test(name, body) {
  try {
    body()
    passed++
  } catch (error) {
    console.error("FAIL: " + name)
    console.error("      " + error.message)
    process.exitCode = 1
  }
}

// Every builder in the plugin, invoked with an id that would be recognisable
// if it ever ended up somewhere it does not belong.
const COMMANDS = {
  "verifyCredentialsCmd": Model.verifyCredentialsCmd(HELPER),
  "instanceConfigCmd": Model.instanceConfigCmd(HELPER),
  "homeTimelineCmd": Model.homeTimelineCmd(HELPER),
  "homeTimelineCmd paged": Model.homeTimelineCmd(HELPER, "110000000000000001"),
  "localTimelineCmd": Model.localTimelineCmd(HELPER),
  "mentionsCmd": Model.mentionsCmd(HELPER),
  "postStatusCmd": Model.postStatusCmd(HELPER, "hello world", "110000000000000002"),
  "reblogCmd": Model.reblogCmd(HELPER, "110000000000000003"),
  "unreblogCmd": Model.unreblogCmd(HELPER, "110000000000000003"),
  "favouriteCmd": Model.favouriteCmd(HELPER, "110000000000000003"),
  "unfavouriteCmd": Model.favouriteCmd(HELPER, "110000000000000003"),
  "bookmarkCmd": Model.bookmarkCmd(HELPER, "110000000000000003"),
  "unbookmarkCmd": Model.unbookmarkCmd(HELPER, "110000000000000003"),
  "followCmd": Model.followCmd(HELPER, "42"),
  "unfollowCmd": Model.unfollowCmd(HELPER, "42"),
  "relationshipCmd": Model.relationshipCmd(HELPER, "42"),
  "registerAppCmd": Model.registerAppCmd(HELPER, "http://127.0.0.1:5000"),
  "exchangeTokenCmd": Model.exchangeTokenCmd(HELPER, "http://127.0.0.1:5000"),
  "loadCmd": Model.loadCmd(HELPER),
  "saveCmd": Model.saveCmd(HELPER),
  "logoutCmd": Model.logoutCmd(HELPER),
  "uploadMediaCmd": Model.uploadMediaCmd(HELPER),
}

test("every command starts with the helper and has no shell", function () {
  for (const name in COMMANDS) {
    const cmd = COMMANDS[name]
    assert.ok(Array.isArray(cmd), name + " must be an array")
    assert.strictEqual(cmd[0], HELPER, name + " must not shell out")
    for (const part of cmd) {
      assert.ok(
        !/^(sh|bash|curl|wget|\/bin\/)/.test(part),
        name + " must not contain a shell or an http client: " + part)
    }
  }
})

test("no command line mentions a credential", function () {
  for (const name in COMMANDS) {
    const joined = COMMANDS[name].join(" ")
    for (const secret of SECRET_LIKE) {
      assert.ok(
        joined.indexOf(secret) === -1,
        name + " leaks " + secret + ": " + joined)
    }
  }
})

test("no command line names a host", function () {
  for (const name in COMMANDS) {
    for (const part of COMMANDS[name]) {
      assert.ok(
        !/^https?:\/\//.test(part) || part.indexOf("127.0.0.1") !== -1,
        name + " names a host: " + part)
    }
  }
})

test("a post carries the status and the reply target, nothing else", function () {
  const cmd = Model.postStatusCmd(HELPER, "hello world", "110000000000000002")
  assert.deepStrictEqual(cmd, [
    HELPER, "post", "/api/v1/statuses",
    "status=hello world", "in_reply_to_id=110000000000000002",
  ])
  const withoutReply = Model.postStatusCmd(HELPER, "hello world", null)
  assert.strictEqual(withoutReply.length, 4)
  assert.strictEqual(withoutReply[4], undefined)
})

test("paging keeps limit and max_id", function () {
  const cmd = Model.homeTimelineCmd(HELPER, "110000000000000001")
  assert.strictEqual(cmd[2], "/api/v1/timelines/home?limit=40&max_id=110000000000000001")
  const first = Model.homeTimelineCmd(HELPER)
  assert.strictEqual(first[2], "/api/v1/timelines/home?limit=40")
})

test("mentions keep their query separator", function () {
  assert.strictEqual(
    Model.mentionsCmd(HELPER)[2],
    "/api/v1/notifications?types[]=mention&limit=40")
})

// --------------------------------------------------------- character limit

test("the instance is asked for its own character limit", function () {
  assert.deepStrictEqual(Model.instanceConfigCmd(HELPER), [
    HELPER, "get", "/api/v2/instance",
  ])
})

test("the limit an instance reports is the one the composer uses", function () {
  const instance = function (max) {
    return { configuration: { statuses: { max_characters: max } } }
  }
  // Mastodon's own default, and instances that raised or lowered it.
  assert.strictEqual(Model.parseMaxCharacters(instance(500)), 500)
  assert.strictEqual(Model.parseMaxCharacters(instance(400)), 400)
  assert.strictEqual(Model.parseMaxCharacters(instance(5000)), 5000)
  assert.strictEqual(Model.parseMaxCharacters(instance(1)), 1)
  // A limit that arrives as a number in a string or a float is still a limit.
  assert.strictEqual(Model.parseMaxCharacters(instance("750")), 750)
  assert.strictEqual(Model.parseMaxCharacters(instance(500.7)), 500)
})

test("a missing or nonsensical limit falls back to the default", function () {
  const fallback = Model.DEFAULT_MAX_CHARACTERS
  assert.strictEqual(Model.parseMaxCharacters(null), fallback)
  assert.strictEqual(Model.parseMaxCharacters(undefined), fallback)
  assert.strictEqual(Model.parseMaxCharacters("500"), fallback)
  assert.strictEqual(Model.parseMaxCharacters({}), fallback)
  assert.strictEqual(Model.parseMaxCharacters({ configuration: null }), fallback)
  assert.strictEqual(Model.parseMaxCharacters({ configuration: {} }), fallback)
  assert.strictEqual(
    Model.parseMaxCharacters({ configuration: { statuses: {} } }), fallback)
  // Zero or negative would make the composer refuse every keystroke, an
  // absurd value would allow posts the instance then rejects.
  assert.strictEqual(Model.parseMaxCharacters({ configuration: { statuses: { max_characters: 0 } } }), fallback)
  assert.strictEqual(Model.parseMaxCharacters({ configuration: { statuses: { max_characters: -5 } } }), fallback)
  assert.strictEqual(Model.parseMaxCharacters({ configuration: { statuses: { max_characters: 1e9 } } }), fallback)
  assert.strictEqual(Model.parseMaxCharacters({ configuration: { statuses: { max_characters: "many" } } }), fallback)
  assert.strictEqual(Model.parseMaxCharacters({ configuration: { statuses: { max_characters: null } } }), fallback)
  assert.strictEqual(Model.parseMaxCharacters({ configuration: { statuses: [] } }), fallback)
  assert.strictEqual(fallback, 500)
})

test("the composer is capped at the limit and counts what is in it", function () {
  const panel = fs.readFileSync(path.join(__dirname, "..", "Panel.qml"), "utf8")
  // TextEdit has no maxLength property in Qt 6 (only TextInput has one, and
  // the composer has to wrap). Assigning it makes the whole panel fail to
  // load, so the clamping has to happen in the textEdited handler instead.
  assert.ok(!/maxLength\s*:/.test(panel),
    "Panel.qml must not assign maxLength, TextEdit has no such property")
  assert.ok(/Model\.limitText\(text,\s*root\.maxCharacters\)/.test(panel),
    "the composer must cut an over-long text where it accepts input")
  assert.ok(/root\.composerLength\s*\+\s*"\/"\s*\+\s*root\.maxCharacters/.test(panel),
    "the composer must show a used/total counter")
})

test("the composer scrolls instead of cutting the text off", function () {
  const panel = fs.readFileSync(path.join(__dirname, "..", "Panel.qml"), "utf8")

  function block(source, from) {
    assert.ok(from >= 0, "Panel.qml should contain the block that starts at " + from)
    let depth = 0
    for (let i = source.indexOf("{", from); i < source.length; i += 1) {
      if (source[i] === "{") depth += 1
      else if (source[i] === "}") {
        depth -= 1
        if (depth === 0) return source.slice(from, i + 1)
      }
    }
    throw new Error("unbalanced block at " + from)
  }

  const scroll = block(panel, panel.lastIndexOf("ScrollView {", panel.indexOf("id: composerScroll")))
  const field = block(scroll, scroll.indexOf("TextArea {"))

  // A TextEdit has contentHeight but no contentY in Qt 6, so on its own it
  // cannot scroll: a long status simply disappears below the last visible
  // line. The ScrollView is what gives the composer a scroll range.
  assert.ok(/clip:\s*true/.test(scroll), "the scroll view must clip its content")
  assert.ok(/background:\s*Item\s*\{\s*\}/.test(scroll),
    "a default background would paint over the themed box and the placeholder")
  assert.ok(/ScrollBar\.horizontal\.policy:\s*ScrollBar\.AlwaysOff/.test(scroll),
    "the composer only scrolls vertically")
  assert.ok(/ScrollBar\.vertical\.policy:[\s\S]*ScrollBar\.AsNeeded\s*:\s*ScrollBar\.AlwaysOff/.test(scroll),
    "the scrollbar may only appear when there is something to scroll")
  assert.ok(/property:\s*"interactive"/.test(scroll),
    "an always interactive flickable would swallow the drag that selects text")

  // TextArea, not TextEdit: only TextArea reports its wrapped height as
  // implicitHeight, and that is the number the ScrollView scrolls.
  assert.ok(/TextArea\s*\{\s*id:\s*composerInput/.test(field),
    "the composer field has to be a TextArea")
  assert.ok(/padding:\s*0/.test(field), "the field must not add its own insets")
  assert.ok(/height:\s*Math\.max\(implicitHeight,\s*composerScroll\.availableHeight\)/.test(field),
    "the field has to grow with its text")
  assert.ok(!/anchors\./.test(field),
    "an anchored field inside a ScrollView fights it over the size")
})

test("a post is cut to the limit as well", function () {
  const long = "x".repeat(600)
  const cmd = Model.postStatusCmd(HELPER, long, null, 500)
  assert.strictEqual(cmd[3], "status=" + "x".repeat(500))
  // Without a known limit nothing is cut, so the composer keeps the last word.
  assert.strictEqual(Model.postStatusCmd(HELPER, long, null)[3], "status=" + long)
  assert.strictEqual(
    Model.postStatusCmd(HELPER, "hello world", null, 500)[3], "status=hello world")
})

test("limitText cuts to the limit and leaves the rest alone", function () {
  assert.strictEqual(Model.limitText("hello", 500), "hello")
  assert.strictEqual(Model.limitText("hello", 5), "hello")
  assert.strictEqual(Model.limitText("hello", 4), "hell")
  assert.strictEqual(Model.limitText("", 500), "")
  assert.strictEqual(Model.limitText("hello", 500.9), "hello")
  // A limit that is not usable must not empty the composer, otherwise a bad
  // value from the instance would make the panel impossible to type in.
  assert.strictEqual(Model.limitText("hello", 0), "hello")
  assert.strictEqual(Model.limitText("hello", -1), "hello")
  assert.strictEqual(Model.limitText("hello", NaN), "hello")
  assert.strictEqual(Model.limitText("hello", undefined), "hello")
  assert.strictEqual(Model.limitText("hello", "nonsense"), "hello")
  assert.strictEqual(Model.limitText(undefined, 5), "")
  assert.strictEqual(Model.limitText(null, 5), "")
  assert.strictEqual(Model.limitText(12345, 3), "123")
  // Newlines are characters too and have to be counted.
  assert.strictEqual(Model.limitText("a\nb\nc", 3), "a\nb")
})

test("an emoji is counted as two, which is the safe direction", function () {
  // JS counts UTF-16 units, Mastodon counts characters, so a surrogate pair
  // must never make the counter claim there is more room than there is.
  const emoji = "\ud83d\ude00"
  assert.strictEqual(emoji.length, 2)
  assert.strictEqual(Model.limitText(emoji.repeat(3), 5).length, 4)
  assert.ok(Model.limitText(emoji.repeat(3), 5).length >= 3)
})

// ------------------------------------------------------------- reblog/boost

test("displayStatus unwraps a boost to the original post", function () {
  const original = { id: "1", content: "hi", media_attachments: [{ url: "https://x/1.png", preview_url: "https://x/1.png" }] }
  const boost = { id: "2", content: "", media_attachments: [], account: { id: "9" }, reblog: original }
  assert.strictEqual(Model.displayStatus(boost), original)
  assert.strictEqual(Model.displayStatus({ status: boost }), original)
})

test("displayStatus leaves a plain post untouched", function () {
  const status = { id: "1", content: "hi" }
  assert.strictEqual(Model.displayStatus(status), status)
  assert.strictEqual(Model.displayStatus({ status: status }), status)
})

test("reblogger returns the booster only for a boost", function () {
  const booster = { id: "9" }
  const boost = { id: "2", account: booster, reblog: { id: "1" } }
  assert.strictEqual(Model.reblogger(boost), booster)
  assert.strictEqual(Model.reblogger({ id: "1" }), null)
})

test("boosted media survives statusMedia via displayStatus", function () {
  const original = {
    id: "1",
    media_attachments: [{ url: "https://x/1.png", preview_url: "https://x/1.png", description: "" }],
  }
  const boost = { id: "2", media_attachments: [], reblog: original }
  const media = Model.statusMedia(Model.displayStatus(boost))
  assert.strictEqual(media.length, 1)
  assert.strictEqual(media[0].url, "https://x/1.png")
})

test("statusCard reads the OpenGraph preview of a link-share post", function () {
  const status = {
    media_attachments: [],
    card: { url: "https://example.com/a", title: "A title", image: "https://example.com/a.jpg" },
  }
  const card = Model.statusCard(status)
  assert.deepStrictEqual(card, { image: "https://example.com/a.jpg", url: "https://example.com/a", title: "A title" })
})

test("statusCard is null without a usable image", function () {
  assert.strictEqual(Model.statusCard({ card: null }), null)
  assert.strictEqual(Model.statusCard({ card: { url: "https://example.com/a" } }), null)
  assert.strictEqual(Model.statusCard({ card: { image: "javascript:alert(1)" } }), null)
  assert.strictEqual(Model.statusCard({}), null)
})

// ------------------------------------------------------------- instance url

test("a bare host becomes https", function () {
  assert.strictEqual(Model.normalizeInstance("mastodon.social"), "https://mastodon.social")
  assert.strictEqual(Model.normalizeInstance("  Mastodon.Social  "), "https://mastodon.social")
  assert.strictEqual(Model.normalizeInstance("https://mastodon.social/"), "https://mastodon.social")
})

test("a remote plaintext instance is refused", function () {
  assert.strictEqual(Model.normalizeInstance("http://mastodon.social"), "")
  assert.strictEqual(Model.normalizeInstance("http://192.0.2.1:8080"), "")
})

test("a lookalike host is not loopback", function () {
  assert.strictEqual(Model.normalizeInstance("http://localhost.evil.example"), "")
  assert.strictEqual(Model.normalizeInstance("http://127.0.0.1.evil.example"), "")
  assert.strictEqual(Model.normalizeInstance("http://notlocalhost"), "")
  assert.strictEqual(Model.normalizeInstance("http://127.0.0.1x"), "")
})

test("loopback plaintext is allowed for the callback", function () {
  assert.strictEqual(Model.normalizeInstance("http://127.0.0.1:5000"), "http://127.0.0.1:5000")
  assert.strictEqual(Model.normalizeInstance("http://localhost:5000"), "http://localhost:5000")
  assert.strictEqual(Model.normalizeInstance("http://[::1]:5000"), "http://[::1]:5000")
})

test("a scheme other than http is refused", function () {
  assert.strictEqual(Model.normalizeInstance("ftp://mastodon.social"), "")
  assert.strictEqual(Model.normalizeInstance("javascript://mastodon.social"), "")
  assert.strictEqual(Model.normalizeInstance("file:///etc/passwd"), "")
  assert.strictEqual(Model.normalizeInstance(""), "")
})

test("userinfo cannot smuggle a host", function () {
  assert.strictEqual(Model.normalizeInstance("https://mastodon.social@evil.example"), "")
  assert.strictEqual(Model.normalizeInstance("mastodon.social@evil.example"), "")
})

test("https is not required on a loopback-free local range", function () {
  // 0.0.0.0 and 10.x are not loopback and must not get the plaintext exception.
  assert.strictEqual(Model.normalizeInstance("http://0.0.0.0:5000"), "")
  assert.strictEqual(Model.normalizeInstance("http://10.0.0.1"), "")
  assert.strictEqual(Model.normalizeInstance("http://256.0.0.1"), "")
})

test("the tooltip still shows an address that is not usable", function () {
  assert.strictEqual(Model.displayInstance("http://mastodon.social"), "http://mastodon.social")
  assert.strictEqual(Model.displayInstance("mastodon.social"), "https://mastodon.social")
})

// --------------------------------------------------------------------- auth

test("the panel view of the credentials holds no secret", function () {
  const auth = Model.emptyAuth()
  assert.deepStrictEqual(Object.keys(auth).sort(), ["clientId", "hasToken", "instance"])
  assert.strictEqual(auth.hasToken, false)
  assert.ok(!("accessToken" in auth))
  assert.ok(!("clientSecret" in auth))
})

test("a stored token cannot be smuggled back in through decodeAuth", function () {
  const decoded = Model.decodeAuth({
    instance: "https://mastodon.social",
    clientId: "abc",
    hasToken: true,
    accessToken: "stolen",
    clientSecret: "stolen",
  })
  assert.strictEqual(decoded.hasToken, true)
  assert.ok(!("accessToken" in decoded))
  assert.ok(!("clientSecret" in decoded))
})

test("authed needs an instance and a token", function () {
  assert.strictEqual(Model.isAuthed(Model.emptyAuth()), false)
  assert.strictEqual(Model.isAuthed({ instance: "https://a.example", hasToken: false }), false)
  assert.strictEqual(Model.isAuthed({ instance: "", hasToken: true }), false)
  assert.strictEqual(Model.isAuthed({ instance: "https://a.example", hasToken: true }), true)
  // A truthy string must not count, the helper is what decides.
  assert.strictEqual(Model.isAuthed({ instance: "https://a.example", hasToken: "yes" }), false)
})

// ------------------------------------------------------------------ images

test("the chooser is Omarchy's, and it asks for several images", function () {
  const cmd = Model.pickMediaCmd()
  assert.strictEqual(cmd[0], "omarchy-file-select")
  assert.ok(cmd.indexOf("--multiple") !== -1,
    "picking more than one image at a time is the point of --multiple")
  assert.strictEqual(cmd[cmd.length - 2], "--extensions")
  // The filter has to name every format the helper accepts, or the chooser
  // hides a file the user can perfectly well post.
  for (const extension of ["jpg", "jpeg", "png", "gif", "webp"]) {
    assert.ok(cmd[cmd.length - 1].split(" ").indexOf(extension) !== -1,
      "the chooser filter misses " + extension)
  }
})

test("the upload command is the subcommand and nothing else", function () {
  // The path is the one thing that must never appear on a command line: it is
  // readable by every local user through /proc/<pid>/cmdline and it names what
  // is about to be published. It travels in MASTODON_UPLOAD_PATH instead.
  assert.deepStrictEqual(Model.uploadMediaCmd(HELPER), [HELPER, "upload"])
})

test("only media the instance accepted belongs in a post", function () {
  assert.deepStrictEqual(Model.pendingMediaIds([]), [])
  assert.deepStrictEqual(Model.pendingMediaIds(null), [])
  assert.deepStrictEqual(Model.pendingMediaIds(undefined), [])
  // An upload that failed has no id, so it must not be sent as an empty one.
  assert.deepStrictEqual(
    Model.pendingMediaIds([{ id: "111" }, { id: "" }, { id: null }, {}, { id: "222" }]),
    ["111", "222"])
  // An id the JSON parser turned into a number still has to be posted as text.
  assert.deepStrictEqual(Model.pendingMediaIds([{ id: 111 }]), ["111"])
  // QML hands arrays to functions as QVariantList, for which isArray is false,
  // so the length is what the list is recognised by.
  const variantList = { length: 2, 0: { id: "111" }, 1: { id: "222" } }
  assert.deepStrictEqual(Model.pendingMediaIds(variantList), ["111", "222"])
  // Already extracted ids have to survive this function as well, so that
  // handing its result on does not drop them.
  assert.deepStrictEqual(Model.pendingMediaIds(["111", "222"]), ["111", "222"])
  assert.deepStrictEqual(Model.pendingMediaIds(["111", "", "222"]), ["111", "222"])
})

test("a path is shortened to its name", function () {
  assert.strictEqual(Model.baseName("/home/sascha/Pictures/hof.png"), "hof.png")
  assert.strictEqual(Model.baseName("hof.png"), "hof.png")
  assert.strictEqual(Model.baseName("/trailing/slash/"), "")
  assert.strictEqual(Model.baseName(""), "")
  assert.strictEqual(Model.baseName(null), "")
})

test("a post carries the media ids it was given", function () {
  const cmd = Model.postStatusCmd(HELPER, "hello world", null, 500, [
    { id: "111" }, { id: "" }, { id: "222" },
  ])
  assert.deepStrictEqual(cmd, [
    HELPER, "post", "/api/v1/statuses", "status=hello world",
    "media_ids[]=111", "media_ids[]=222",
  ])
  const reply = Model.postStatusCmd(HELPER, "hi", "110000000000000002", 500, [
    { id: "111" },
  ])
  assert.strictEqual(reply[4], "in_reply_to_id=110000000000000002")
  assert.strictEqual(reply[5], "media_ids[]=111")
})

test("a post keeps media ids that were already extracted", function () {
  // The panel runs pendingMediaIds over its attachments and hands the result
  // in, so postStatusCmd is given bare ids rather than entries. Reading `.id`
  // off a string yields undefined and dropped every image from the post while
  // the text went out normally — the regression this pins down.
  const media = [{ id: "111" }, { id: "" }, { id: "222" }]
  const ids = Model.pendingMediaIds(media)
  assert.deepStrictEqual(ids, ["111", "222"])
  assert.deepStrictEqual(Model.postStatusCmd(HELPER, "hi", null, 500, ids), [
    HELPER, "post", "/api/v1/statuses", "status=hi",
    "media_ids[]=111", "media_ids[]=222",
  ])
  // The same list as QML would hand it over.
  const variantList = { length: 1, 0: { id: "111" } }
  assert.deepStrictEqual(
    Model.postStatusCmd(HELPER, "hi", null, 500, variantList),
    [HELPER, "post", "/api/v1/statuses", "status=hi", "media_ids[]=111"])
})

test("a picture can be posted without a word of text", function () {
  // Mastodon accepts a media-only status, but not one that sends an empty
  // status field together with the images, so the field has to be left out.
  const cmd = Model.postStatusCmd(HELPER, "", null, 500, [{ id: "111" }])
  assert.deepStrictEqual(cmd, [
    HELPER, "post", "/api/v1/statuses", "media_ids[]=111",
  ])
  // The panel trims the composer's text before it gets here, so an empty field
  // arrives as an empty string and never as whitespace.
  assert.ok(Model.postStatusCmd(HELPER, "", null, 500, []).length === 3,
    "a status with neither text nor media is refused by the instance")
})

test("the instance decides how many images a status may carry", function () {
  const instance = function (max) {
    return { configuration: { statuses: { max_media_attachments: max } } }
  }
  const fallback = Model.MAX_MEDIA_PER_STATUS
  assert.strictEqual(Model.parseMaxMediaAttachments(instance(4)), 4)
  assert.strictEqual(Model.parseMaxMediaAttachments(instance(1)), 1)
  assert.strictEqual(Model.parseMaxMediaAttachments(instance("2")), 2)
  assert.strictEqual(Model.parseMaxMediaAttachments(instance(2.9)), 2)
  // More than the panel shows would only produce an instance that refuses the
  // post, so it falls back rather than pretending it can.
  assert.strictEqual(Model.parseMaxMediaAttachments(instance(16)), fallback)
  assert.strictEqual(Model.parseMaxMediaAttachments(instance(0)), fallback)
  assert.strictEqual(Model.parseMaxMediaAttachments(instance(-5)), fallback)
  assert.strictEqual(Model.parseMaxMediaAttachments(instance(null)), fallback)
  assert.strictEqual(Model.parseMaxMediaAttachments(instance("many")), fallback)
  assert.strictEqual(Model.parseMaxMediaAttachments(null), fallback)
  assert.strictEqual(Model.parseMaxMediaAttachments("4"), fallback)
  assert.strictEqual(Model.parseMaxMediaAttachments({}), fallback)
  assert.strictEqual(Model.parseMaxMediaAttachments({ configuration: {} }), fallback)
  assert.strictEqual(
    Model.parseMaxMediaAttachments({ configuration: { statuses: {} } }), fallback)
  assert.strictEqual(
    Model.parseMaxMediaAttachments({ configuration: { statuses: [] } }), fallback)
})

test("the panel hands the path to the helper on the environment", function () {
  const panel = fs.readFileSync(path.join(__dirname, "..", "Panel.qml"), "utf8")
  assert.ok(/uploadMediaProc\.environment\s*=\s*\(\{\s*MASTODON_UPLOAD_PATH:/.test(panel),
    "the upload path has to travel in the process environment")
  // The command itself must stay the bare subcommand, so there is no path left
  // to leak into /proc/<pid>/cmdline.
  assert.ok(/uploadMediaProc\.command\s*=\s*Model\.uploadMediaCmd\(root\.helperScript\)/.test(panel),
    "the upload command must not be built with the path in it")
  assert.ok(!/uploadMediaCmd\s*\(\s*root\.helperScript\s*,/.test(panel),
    "uploadMediaCmd must not take a path argument")
})

// --------------------------------------------------------- source inspection

test("the panel sources contain no shell and no curl", function () {
  for (const file of ["BarWidget.qml", "Panel.qml", "Model.js"]) {
    const source = fs.readFileSync(path.join(__dirname, "..", file), "utf8")
    const code = source.split("\n").filter(function (line) {
      const trimmed = line.trim()
      return trimmed.indexOf("//") !== 0 && trimmed.indexOf("*") !== 0
    }).join("\n")
    assert.ok(code.indexOf("curl") === -1, file + " still references curl")
    assert.ok(!/\bsh -c\b/.test(code), file + " still builds a shell command")
  }
})

console.log(passed + " passed" + (process.exitCode ? ", with failures" : ""))
