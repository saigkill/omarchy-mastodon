# AGENTS.md

Guidance for AI agents working in this repository. The README documents *what*
the plugin does; this file records *how* to change it without breaking it.

## What this is

An Omarchy shell plugin (Quickshell/QML) with a Python helper that owns the
Mastodon credentials. Roughly 1700 lines of `Panel.qml`, ~700 of `Model.js`,
~550 of `mastodon_helper.py`.

## The one rule that matters most

**Never let a credential reach a process argument or the panel.**

`/proc/<pid>/cmdline` is world readable. Anything passed on a command line is
public on the machine. That is why:

- the panel never sees the access token, the client secret or the OAuth code;
- every API call and every read/write of the state file goes through
  `mastodon_helper.py` and nothing else — no `curl`, no `sh -c`;
- the local upload path travels in `MASTODON_UPLOAD_PATH` on the process
  environment, and `upload` takes no argument at all, so there is no way to pass
  a path by accident;
- a token is only ever sent over TLS, to the instance it was issued for.

`tests/test_helper.py` enforces this. If a change makes it possible for a
credential to appear in argv, the tests are supposed to fail — do not adjust the
tests to make a new design pass.

## Before you change anything

```sh
node tests/test_model.js                       # command builders, parsing
python3 -m unittest discover -s tests          # credentials, TLS, uploads
```

Both must be green before and after. Run both whenever you touch `Model.js`,
`mastodon_helper.py`, `BarWidget.qml` or `Panel.qml`.

## Editing Panel.qml

**Count the braces after every insertion.** This is not optional — a stray `}`
closes the enclosing `Column` and silently moves everything after it out of the
panel. Quickshell then reports one `Syntax error` and the window opens empty.

```sh
python3 - <<'EOF'
import re
depth = 0
for l in open('Panel.qml', encoding='utf-8').read().split('\n'):
    s = re.sub(r'"(\\.|[^"\\])*"', '""', l)
    s = re.sub(r'//.*', '', s)
    for c in s:
        depth += (c == '{') - (c == '}')
print(depth)  # must be 0
EOF
```

`qmllint` is not a substitute. The `qs.*` imports produce false positives, and on
a genuinely broken file it exits 255 without printing anything at all — a clean
run proves nothing.

**Invisible items still take space.** An item with `visible: false` still reports
an `implicitHeight` to its `Column`, which leaves a gap. Use `height: visible ?
implicitHeight : 0`, as the existing rows do.

**`TextEdit` has no usable implicit size.** Anything that must scroll or wrap
needs `TextArea`; see "The scrolling composer" in the README.

**`Array.isArray()` is `false` for a list from QML.** QML passes arrays to
functions as `QVariantList`. Code that needs `length` rather than `isArray` —
that is what `Model.pendingMediaIds()` does.

**Do not bind a property you also write imperatively.** An imperative write to a
bound property drops the binding permanently, and a binding cannot be restored
from inside a signal handler. That is why the composer text goes through
`setComposerText()` instead of `text: root.composerText`.

## Editing Model.js

Command builders are pure functions returning arrays, and each one is a command
with no shell in it. Keep them that way: a test asserts that every command starts
with the helper path and contains no shell metacharacters.

Everything here is pure and testable without a panel. When you add a builder,
also add it to the `COMMANDS` map at the bottom *and* to the list in
`tests/test_model.js`, which enumerates every command.

Instance limits are configuration and must be read, not assumed: character limit,
images per status, and the alt text limit all come from `GET /api/v2/instance`
with a fallback. Parse defensively — a `parseXLimit()` that returns its fallback
for null, a string, `0`, negative and absurd values.

## Editing mastodon_helper.py

Validate anything a caller controls **before** anything is sent. The media id in
`describe` goes into the request path, and `endpoint_path()` rules out another
origin but not a path climbing back out of the base with `../`, so the digits are
checked there.

Split form fields on the *first* `=` only, so a description containing `=` —
which is also what `urllib.parse.parse_qs(..., keep_blank_values=True)` is needed
for in the tests — survives.

A refused request must exit non-zero with an **empty stdout**. The panel reads
media ids off stdout and would otherwise mistake an error document for a result.

## Deploying to test

The plugin directory is watched by Quickshell: writing there reloads the plugin,
which closes an open panel. Copy files only when you mean to reload.

```sh
cp Model.js mastodon_helper.py Panel.qml ~/.config/omarchy/plugins/saigkill.mastodon/
omarchy plugin validate
omarchy restart shell
journalctl --user --since "-1m" | grep -i mastodon
```

Scratch files and test data go in `/tmp`, never in the plugin directory.

## Testing against the real instance

Do not post test statuses. A real upload leaves an unattached media id on the
instance that only the instance's own cleanup removes — `DELETE
/api/v1/media/:id` exists but is not implemented here. Diagnose against the API
and the log instead, and if a probe upload was unavoidable, say so.

The user's login state in `~/.local/state/omarchy-mastodon/auth.json` must not be
touched. Note that it is *not* the same file as the stale empty `auth.json` in the
plugin directory.

## Conventions

- English in code comments, English in the README, German in conversation.
- No dependencies beyond the standard library, Qt/QML and Quickshell.
- Keep constants in `Model.js` and let the panel read them from there.
- Match the surrounding comment density: this codebase explains *why*, especially
  where a non-obvious choice would otherwise look wrong.