# Mastodon client (saigkill.mastodon)

Mastodon client for the Omarchy Quattro bar with OAuth login, timelines and interactions.

## Features

- **Bar widget** — a Mastodon icon in the bar. Opens a panel with:
  - **OAuth login** — enter your instance, authorize in the browser, and the token is saved permanently
  - **Three tabs** — Home, Local, Mentions
  - **Composer** — single composer box, available in every tab
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
│ [ Post ]                      │
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
`contentHeight` of the `KeyboardPanel`).

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

## API endpoints used

- `POST /api/v1/apps` — register OAuth app
- `POST /oauth/token` — exchange code for token
- `GET /api/v1/accounts/verify_credentials` — current user
- `GET /api/v1/timelines/home` — home timeline
- `GET /api/v1/timelines/public?local=true` — local timeline
- `GET /api/v1/notifications?types[]=mention` — mentions
- `POST /api/v1/statuses` — post status
- `POST /api/v1/statuses/:id/reblog` / `unreblog` — reblog
- `POST /api/v1/statuses/:id/favourite` / `unfavourite` — favourite
- `POST /api/v1/statuses/:id/bookmark` / `unbookmark` — bookmark
- `POST /api/v1/accounts/:id/follow` / `unfollow` — follow
- `GET /api/v1/accounts/relationships` — follow state

Timelines are requested with `limit=40`, and older pages with `max_id` set to the
oldest id currently held. Overlapping pages are de-duplicated, and a failed page
is not mistaken for the end of the timeline.

## Files and where state lives

| Path | What it is |
| --- | --- |
| `Panel.qml` | Panel UI: header, tabs, composer, feed, cards, media |
| `BarWidget.qml` | Bar slot, icon button, OAuth orchestration, token storage |
| `Model.js` | Pure helpers: paging, HTML/URL sanitising, media extraction |
| `oauth_server.py` | Local HTTP callback server used during login |
| `manifest.json` | Omarchy plugin manifest (id, entry points, bar placement) |
| `LICENSE` | MIT license text |
| `~/.local/state/omarchy-mastodon/auth.json` | OAuth token (**yours, never in the repo**) |

Only `manifest.json`, `BarWidget.qml`, `Panel.qml`, `Model.js` and
`oauth_server.py` belong in the plugin directory. Do not put anything else there
that changes at runtime — Quickshell watches the directory and reloads the
plugin, which closes an open panel and can leave a `Quickshell.Io.Process` dead.

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
git clone https://github.com/saigkill/omarchy-mastodon1.git ~/src/omarchy-mastodon1
cd ~/src/omarchy-mastodon1

# 2. check the plugin folder is valid before copying it in
omarchy plugin validate .

# 3. copy it into the plugin directory
mkdir -p ~/.config/omarchy/plugins
cp -r . ~/.config/omarchy/plugins/saigkill.mastodon

# 4. make the login helper executable (needed for the OAuth callback)
chmod +x ~/.config/omarchy/plugins/saigkill.mastodon/oauth_server.py

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

**QML errors in the log.** The plugin uses `qs.*` imports, so `qmllint` reports
false positives. Trust the shell log instead:

```sh
journalctl --user --since "-1m" | grep -i mastodon
```

**Feed overlaps the panel edges or images are missing.** Both come from the feed
column not reporting its height, so the panel cannot clip it. The cards read
their media list from a single `Model.statusMedia()` call; if that ever returns
an empty list for a post that visibly has images, check `Array.isArray()` — QML
passes arrays to functions as `QVariantList`, for which `Array.isArray()` is
`false`.

**Local or Mentions tab is empty.** Not necessarily a bug. Some instances expose
little or no public local timeline, and a muted/blocked filter can leave Mentions
empty while Home is full.

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
