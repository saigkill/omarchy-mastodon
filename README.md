# Mastodon client (saigkill.mastodon)

Mastodon client for the Omarchy Quattro bar with OAuth login, timelines and interactions.

## Features

- **Bar widget** — a Mastodon icon in the bar. Opens a panel with:
  - **OAuth login** — enter your instance, authorize in the browser, and the token is saved permanently
  - **Three tabs** — Home, Local, Mentions
  - **Composer** — single composer box at the top of the panel, available in every tab
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

## Install

```sh
omarchy plugin add https://github.com/saigkill/omarchy-mastodon1.git --enable
```

## Remove

```sh
omarchy plugin remove saigkill.mastodon
```
