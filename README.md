# Mastodon client (saigkill.mastodon)

Mastodon client for the Omarchy Quattro bar with OAuth login, timelines and interactions.

![Preview](https://github.com/saigkill/omarchy-mastodon/blob/master/preview.png?raw=true)
![Preview1](https://github.com/saigkill/omarchy-mastodon/blob/master/preview1.png?raw=true)

## Features

- **Bar widget** — a Mastodon icon in the bar. Opens a panel with:
  - **OAuth login** — enter your instance, authorize in the browser, and the token is saved permanently
  - **Three tabs** — Home, Local, Mentions
  - **Composer** — single composer box, available in every tab
  - **Attaching images** — the "Image" button opens the desktop file chooser
    (Omarchy's `omarchy-file-select`), you may pick several at once, and each is
    uploaded right away and shown as a thumbnail. Post it together with the text
    or on its own, and remove it again with the small ✕ on the thumbnail
  - **Alt text per image** — click a thumbnail to describe it. The badge reads
    `+ALT` while an image has none and `ALT` once it has one
  - **Character limit** — the counter next to the Post button shows `23/500`, and
    the field refuses a character more than the instance allows
  - **Replies** — the reply button on a status scrolls back to the composer, shows
    "Replying to @user" and focuses the field. <kbd>Esc</kbd> cancels the reply and
    returns keyboard navigation to the feed
  - **Reactions** — Reblog, Favourite and Bookmark buttons on every status
  - **Follow** — follow button next to each username (hidden if already following)
  - **Media** — up to four images per status, alt text shown underneath. Click
    an image to open the full-size version. Posts marked sensitive stay hidden
    behind a "Show media" button so nothing loads unasked
  - **Links** — links in a status are clickable and open in your browser. Only
    `http`/`https` targets are ever opened, everything else degrades to plain text
  - **Infinite scroll** — scrolling to the end of a timeline loads the next 40
    older posts per tab

While the composer or the instance field has focus, the panel's `j`/`k`/`h`/`l`/space
shortcuts are handed to the text editor instead of moving the feed cursor.

## Panel layout

The panel has a fixed height, which is the Omarchy convention and keeps the panel
from jumping around while you scroll:

```
┌──────────────────────────────┐
│ MASTODON              ⟳  ⏻   │  header        stays put
├──────────────────────────────┤
│ [Home] [Local] [Mentions]    │  tabs          stays put

├──────────────────────────────┤
│ What's on your mind?         │  composer      stays put
│ [ Post ] [ Image ]     23/500│
│ ▢ALT ▢ALT                    │  ┐ thumbnails, and the
│ Alt text [        ] [Save]   │  ┘ alt text editor for one
├──────────────────────────────┤
│  ▢ 10:24  @someone           │  ┐
│  status text …                │  │ the feed scrolls,
│  ↩  ⇄  ♥  🔖                 │  │ only this part moves
│  ▢ …                         │  ┘
└──────────────────────────────┘
```

Only the feed is inside the scroll area, so the composer is always visible and
ready to type into without scrolling back up. The trade-off is that the fixed
part takes about 200 px of the panel height, leaving roughly 450 px for posts.
To change the total height, edit `Style.space(700)` in `Panel.qml` (the
`contentHeight` of the `KeyboardPanel`). The composer box itself keeps its 70px
and scrolls its own text once a status outgrows it.

## OAuth flow

1. Enter your instance (e.g. `mastodon.social`)
2. The plugin registers an app with the instance
3. A local HTTP server starts on a random port
4. The browser opens the authorization page
5. After authorizing, the browser redirects to the local server
6. The plugin exchanges the code for an access token
7. The token is saved to `~/.local/state/omarchy-mastodon/auth.json` (deliberately
   outside the plugin directory — writing there makes Quickshell reload the
   plugin and drop an open panel)

## Credential handling

All Mastodon API calls and all reads/writes of the state file go through
`mastodon_helper.py`, not `curl` and not a shell. This is deliberate, not
incidental:

- **Nothing secret ever appears on a command line.** `/proc/<pid>/cmdline` is
  world-readable, so any local process could once read the access token, the
  OAuth client secret and the authorization code straight out of `ps` output.
  The QML side now only ever passes the helper non-secret arguments (an
  endpoint, a status, a redirect URI); the helper reads the token and the
  client secret from its own state file, and the one-time authorization code
  arrives through the `MASTODON_OAUTH_CODE` environment variable instead
  (`/proc/<pid>/environ` is readable only by the owning user).
- **The panel holds no secret at all.** `BarWidget.qml`'s view of the
  credentials (`Model.emptyAuth()`) is just `{ instance, clientId, hasToken }`.
  The access token and the client secret are owned exclusively by the helper
  and never travel back into QML, so a crash, a log line or a stray property
  in the panel cannot leak either of them.
- **`auth.json` is `0600` and symlink-safe.** The helper opens it with
  `O_NOFOLLOW`, so a symlink planted at that path is refused instead of
  followed, and permissions are re-tightened on every write even if the file
  pre-dates this version.
- **Non-loopback instances must be `https`.** `Model.normalizeInstance()` (QML
  side) and `secure_base()` (helper side) both reject `http://` except to
  `localhost`/`127.0.0.0/8`/`::1`, which is only ever used for the local OAuth
  callback. Lookalike hosts (`127.0.0.1.evil.example`) and userinfo smuggling
  (`host@evil.example`) are rejected explicitly, not just by accident of
  string matching.
- **Redirects can't exfiltrate the token.** A same-method redirect keeps the
  `Authorization` header, so the helper's opener refuses to follow one that
  changes scheme or host.
- **Response bodies are capped at 10 MiB** so a malicious or compromised
  instance cannot exhaust the helper (and, downstream, the QML
  `StdioCollector` that buffers its stdout) with an oversized reply.

See `mastodon_helper.py`'s module docstring for the full reasoning, and
`tests/test_helper.py` for the tests that pin this behaviour down.

## API endpoints used

- `POST /api/v1/apps` — register OAuth app
- `POST /oauth/token` — exchange code for token
- `GET /api/v1/accounts/verify_credentials` — current user
- `GET /api/v2/instance` — the instance's own character and image limits
- `GET /api/v1/timelines/home` — home timeline
- `GET /api/v1/timelines/public?local=true` — local timeline
- `GET /api/v1/notifications?types[]=mention` — mentions
- `POST /api/v2/media` — upload an attached image
- `PUT /api/v1/media/:id` — set the alt text of an attached image
- `POST /api/v1/statuses` — post status, with `media_ids[]` for the images
- `POST /api/v1/statuses/:id/reblog` / `unreblog` — reblog
- `POST /api/v1/statuses/:id/favourite` / `unfavourite` — favourite
- `POST /api/v1/statuses/:id/bookmark` / `unbookmark` — bookmark
- `POST /api/v1/accounts/:id/follow` / `unfollow` — follow
- `GET /api/v1/accounts/relationships` — follow state

Timelines are requested with `limit=40`, and older pages with `max_id` set to the
oldest id currently held. Overlapping pages are de-duplicated, and a failed page
is not mistaken for the end of the timeline.

## The composer character limit

Mastodon's default is **500 characters** per status, but the limit is instance
configuration (`MAX_CHARACTERS`) and administrators do raise or lower it. The
panel therefore asks the instance itself (`configuration.statuses.max_characters`
in `GET /api/v2/instance`, fetched once per login) and uses whatever comes back,
falling back to 500 when the instance reports nothing usable.

The counter is `used/limit` and turns red once the limit is reached. The
composer cuts the overflow in its `textEdited` handler, so typing, pasting and
drag and drop all stop at the limit instead of producing a post the instance
answers with a 422. (`TextEdit` has no `maxLength` in Qt 6 — only `TextInput`
has one, and the composer has to wrap — and an imperative write to a bound
`text` property would drop the binding for good, which is why the field is
synced through `setComposerText()` instead of `text: composerText`.) The status
is cut once more in `postStatusCmd()`, the one place every post passes through.

## Attaching images

The **Image** button next to Post opens the desktop file chooser, several files
can be picked at once, and each one is uploaded to the instance immediately.
The instance hands back a media id, and the status then carries that id in
`media_ids[]` — which is why an image is uploaded *before* the status exists and
why the Post button stays disabled until every upload has come back.

**The chooser is Omarchy's, not Qt's.** `omarchy-file-select` goes through the
XDG portal, so what opens is an ordinary desktop window. A
`QtQuick.Dialogs.FileDialog` does not open at all inside Quickshell, and the
panel would in any case be in the way: it lives in the Overlay layer, so a
normal client window opens *underneath* it. The panel therefore closes itself
while the chooser is up and opens again afterwards. The panel object stays alive
while its window is hidden, so the text, the reply target and the images already
attached all survive the round trip.

Because only one `Quickshell.Io.Process` runs one command at a time, a
multi-file selection is uploaded one after the other from a queue. A file whose
upload failed keeps its slot and shows a warning instead of silently vanishing,
and carries no id, so it is left out of the post; pressing Post again reuses the
uploads rather than sending them a second time.

**What is refused before anything is sent.** `mastodon_helper.py` only accepts a
regular file — `stat()` decides that *before* the file is opened, so opening a
fifo cannot block the panel waiting for a writer that never comes — plus one of
the formats the chooser offers (`.jpg`, `.jpeg`, `.png`, `.gif`, `.webp`) and a
size of at most 20 MiB, which is above Mastodon's own 16 MiB default. How many
images a status may carry comes from the instance
(`configuration.statuses.max_media_attachments`), capped at the four the panel
shows.

**The path stays out of the command line.** `/proc/<pid>/cmdline` is world
readable and a filename says what is about to be published, so the path travels
in `MASTODON_UPLOAD_PATH` on the process environment instead. `mastodon_helper.py
upload` takes no argument at all, which makes it impossible to pass a path there
by accident. The multipart body itself is built in memory with a random
boundary, and the file's name is folded to ASCII for the part header so that a
quote or a newline in it cannot break the header apart.

A post may consist of images only: in that case the `status` field is left out of
the request entirely rather than sent empty, which the instance would answer with
a 422.

## Alt text

The alt text belongs to the attachment, not to the status, so it does not travel
in the post request. Clicking a thumbnail opens a one-line editor underneath the
image strip; **Save** (or <kbd>Enter</kbd>) sends it, **Cancel** or
<kbd>Esc</kbd> throws it away, and the thumbnail's badge changes from `+ALT` to
`ALT`. A failure keeps the text in the field instead of dropping it, so nothing
typed is lost.

**Why it is sent at Save and not at Post.** The instance only answers
`PUT /api/v1/media/:id` while the attachment is not yet part of a posted status —
once the post exists, the answer is a 404. The panel therefore sends the text the
moment it is confirmed, while it still can, and afterwards only remembers what
was accepted. `describe` is a form-field request, not a file upload, so unlike
`upload` it needs no path in the environment: it takes the media id and one
`description=<text>` argument and splits on the *first* `=`, so a text that
contains one survives.

The media id is the only piece of that command the caller controls and it goes
into the request path, so `cmd_describe` checks that it is all digits before
anything is sent. `endpoint_path()` rules out a crafted endpoint pointing at
another origin, but not a path like `/api/v1/media/../../accounts/...` climbing
back out, so the digits are checked here. How long a description may be is
instance configuration too (`configuration.media_attachments.description_limit`,
10000 on Mastodon's own instances) and the field is clamped to it.

Alt text is also what the feed renders underneath an image, so an image with none
is announced as such rather than silently described as a picture.

## The scrolling composer

The composer box is a fixed 70px tall, which is about four lines. A full status
is longer than that, so the box scrolls: the field sits in a `ScrollView` (the
same pattern the monitor and audio panels use) and the scrollbar only appears
once the text is taller than the box.

A `TextEdit` alone cannot do this. In Qt 6 it has `contentHeight` but no
`contentY`, so it is not a `Flickable` and simply cuts everything below the
last visible line off. `TextArea` is used instead: it is a `TextEdit` subclass
that reports its wrapped height as `implicitHeight`, and that number is what
gives the scroll view something to scroll. The flickable is only `interactive`
while there is something to scroll, otherwise its drag would swallow the drag
that selects text, and both the scroll view and the field have an empty
`background` so the themed box and the placeholder underneath stay visible.

## Files and where state lives

| Path | What it is |
| --- | --- |
| `Panel.qml` | Panel UI: header, tabs, composer, feed, cards, media |
| `BarWidget.qml` | Bar slot, icon button, OAuth orchestration |
| `Model.js` | Pure helpers: command builders, paging, HTML/URL sanitising, media extraction, character limit parsing. Holds no credential. |
| `mastodon_helper.py` | Owns every credential: talks to the Mastodon API and reads/writes the state file. See "Credential handling" above |
| `oauth_server.py` | Local HTTP callback server used during login |
| `manifest.json` | Omarchy plugin manifest (id, entry points, bar placement) |
| `LICENSE` | MIT license text |
| `~/.local/state/omarchy-mastodon/auth.json` | OAuth token, `0600`, owned by `mastodon_helper.py` (**yours, never in the repo**) |

Only `manifest.json`, `BarWidget.qml`, `Panel.qml`, `Model.js`,
`mastodon_helper.py` and `oauth_server.py` belong in the plugin directory. Do
not put anything else there that changes at runtime — Quickshell watches the
directory and reloads the plugin, which closes an open panel and can leave a
`Quickshell.Io.Process` dead.

## Install

The plugin id is `saigkill.mastodon`, taken from `manifest.json`.

### Option A — from git (the normal way)

Once the repository is published, this is the one-liner:

```sh
omarchy plugin add https://github.com/saigkill/omarchy-mastodon.git --enable
```

`--enable` turns the widget on straight away. If the clone or the enable step is
interrupted, re-running the command is safe.

Verify with:

```sh
omarchy plugin list | grep saigkill.mastodon
```

You should see it listed as `enabled`, kind `bar-widget`, source `third-party`.
If it shows `disabled`, switch it on without re-downloading:

```sh
omarchy plugin enable saigkill.mastodon
```

A plugin installed this way is git-managed, so later releases can be pulled in
with:

```sh
omarchy plugin update saigkill.mastodon
omarchy restart shell
```

`omarchy plugin update` only touches plugins that were installed from a git URL.
If you installed option B by copying files, update your working copy and copy it
over again instead.

> **Note:** this repository currently has no git remote configured, so the command
> above only works once the repo is pushed to GitHub. Until then use option B.

### Option B — from a local clone (development)

Useful when you work on the plugin locally and want to edit the files directly.

```sh
# 1. get the code somewhere
git clone https://github.com/saigkill/omarchy-mastodon.git ~/src/omarchy-mastodon
cd ~/src/omarchy-mastodon

# 2. check the plugin folder is valid before copying it in
omarchy plugin validate .

# 3. copy it into the plugin directory
mkdir -p ~/.config/omarchy/plugins
cp -r . ~/.config/omarchy/plugins/saigkill.mastodon

# 4. make both Python helpers executable (needed for login and every API call)
chmod +x ~/.config/omarchy/plugins/saigkill.mastodon/oauth_server.py
chmod +x ~/.config/omarchy/plugins/saigkill.mastodon/mastodon_helper.py

# 5. enable it
omarchy plugin enable saigkill.mastodon
omarchy restart shell
```

`omarchy plugin add` copies the files, so it does not link to your working copy.
To keep editing in one place, either repeat step 3 after each change, or install a
symlink instead of a copy:

```sh
ln -s ~/src/omarchy-mastodon1 ~/.config/omarchy/plugins/saigkill.mastodon
```

With a symlink, edits in your clone are picked up on the next
`omarchy restart shell`.

### After every change

```sh
omarchy restart shell
```

Always use a full restart rather than relying on the automatic reload. The
hot-reload path can leave the OAuth `Process` dead, which means the login button
does nothing until a restart. If the restart reports
`Omarchy shell did not become ready after restart.`, run it once more and check:

```sh
omarchy-shell shell ping
```

## Remove

### Just hide it

```sh
omarchy plugin disable saigkill.mastodon
omarchy restart shell
```

The files stay in place and `omarchy plugin enable saigkill.mastodon` brings it
back.

### Uninstall completely

```sh
omarchy plugin remove saigkill.mastodon --yes
```

Check that both the plugin directory and the saved token are gone:

```sh
ls ~/.config/omarchy/plugins/saigkill.mastodon   # should not exist
ls ~/.local/state/omarchy-mastodon/              # should not exist
```

`omarchy plugin remove` only deletes the plugin directory. The OAuth token lives
in `~/.local/state/omarchy-mastodon/auth.json` and is **not** removed with it —
that is intentional, so reinstalling does not force you to log in again. To
revoke the access yourself, either:

- remove the state directory:

  ```sh
  rm -rf ~/.local/state/omarchy-mastodon
  ```

- or use the logout button in the panel header, which clears the token locally,
- or revoke the app on your instance under *Preferences → Authorized apps*.

## Troubleshooting

**Login button does nothing.** The OAuth callback server is a `Quickshell`
`Process`. If a hot reload killed it, `omarchy restart shell` and try again.

**Panel does not open.** Check that the widget is enabled and that the shell
sees the plugin:

```sh
omarchy plugin list | grep saigkill.mastodon
journalctl --user -n 100 | grep -i mastodon
```

**The Image button does nothing, or the chooser stays hidden.** The chooser is
`omarchy-file-select`, which needs the XDG portal; if it is missing the button
reports nothing useful. Check that it is installed and that the panel closes and
comes back:

```sh
omarchy-file-select --title "Test"   # should open a normal window
journalctl --user --since "-1m" | grep -i mastodon
```

**"Upload failed: ..." under the composer.** The file was refused before or
during the upload. The formats are `.jpg`, `.jpeg`, `.png`, `.gif` and `.webp`,
the size limit is 20 MiB, and the instance's own limit on images per status is
read from its configuration. The `!` on the thumbnail marks the file that
failed; remove it with ✕ and pick it again.

**"Alt text not saved" under the image strip.** The instance refused the
`PUT /api/v1/media/:id`. That endpoint only answers while the attachment is not
yet part of a posted status, so this means the image was already posted and its
alt text can no longer be changed — edit the post on the web instead. The typed
text stays in the field so it can be copied over.

**The panel is empty and the log says `Syntax error`.** A brace went missing or
was left over, and Quickshell reports only the line where it noticed, not the one
that caused it. Count the braces to find the real place:

```sh
python3 - <<'EOF'
import re
depth = 0
for n, l in enumerate(open('Panel.qml', encoding='utf-8').read().split('\n'), 1):
    s = re.sub(r'"(\\.|[^"\\])*"', '""', l)
    s = re.sub(r'//.*', '', s)
    for c in s:
        depth += (c == '{') - (c == '}')
print(depth)  # must be 0
EOF
```

**QML errors in the log.** The plugin uses `qs.*` imports, so `qmllint` reports
false positives. Trust the shell log instead:

```sh
journalctl --user --since "-1m" | grep -i mastodon
```

`qmllint` does not reliably report a syntax error here either — it can exit 255
without printing anything at all — so a clean run proves nothing. Use the brace
count above.

**Feed overlaps the panel edges or images are missing.** Both come from the feed
column not reporting its height, so the panel cannot clip it. The cards read
their media list from a single `Model.statusMedia()` call; if that ever returns
an empty list for a post that visibly has images, check `Array.isArray()` — QML
passes arrays to functions as `QVariantList`, for which `Array.isArray()` is
`false`.

**Local or Mentions tab is empty.** Not necessarily a bug. Some instances expose
little or no public local timeline, and a muted/blocked filter can leave Mentions
empty while Home is full.

## Testing

Two independent test suites cover the parts that matter most: that no
credential ever reaches a process argument or the panel, and that a token is
only ever sent over TLS to the instance it was issued for.

```sh
# Model.js: command builders, instance validation, the credential-shaped view
node tests/test_model.js

# mastodon_helper.py: TLS enforcement, redirect handling, state file
# permissions/symlink safety, response size cap, image upload validation,
# alt text on the media endpoint
python3 -m unittest discover -s tests -v
```

Both should be run before sending a patch that touches `Model.js`,
`BarWidget.qml`, `Panel.qml` or `mastodon_helper.py`.

## License

[MIT](LICENSE) — Copyright (c) 2026 Sascha Manns.

You are free to use, copy, modify, merge, publish, distribute, sublicense and
sell copies, and the license text must be kept in all copies or substantial
portions of the software. The software is provided without any warranty.

## Contributing

Patches are welcome. Two things are worth knowing before you start:

- **Do not commit anything that changes at runtime into the plugin directory.**
  Quickshell watches `~/.config/omarchy/plugins/` and reloads the plugin on any
  change, which closes an open panel and can leave the OAuth `Process` dead.
  Scratch files and test data belong in `/tmp`.
- **Test QML in the running shell, not with `qmllint`.** The `qs.*` imports make
  `qmllint` report false positives; `journalctl --user` is the source of truth.
  `qmllint` is not a syntax check here either — it can report nothing at all on a
  broken file. After inserting a block into `Panel.qml`, count the braces (see
  Troubleshooting) and then reload the plugin for real.
- **Check the panel structure, not just the balance.** A stray `}` closes an
  enclosing `Column` and moves everything after it out of the panel: the log shows
  one `Syntax error` and the window opens empty. The line Quickshell names is
  where it *noticed*, not where the extra brace is.
- **Never reintroduce a credential into `Model.js`, `BarWidget.qml` or
  `Panel.qml`.** The access token and the client secret must stay inside
  `mastodon_helper.py`; see "Credential handling" above and run both test
  suites (see "Testing") before submitting.
