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
