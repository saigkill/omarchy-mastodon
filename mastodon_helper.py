#!/usr/bin/env python3
"""HTTP client for the Omarchy Mastodon panel.

Credentials are owned by this process. The panel used to shell out to curl and
hand it the access token, the OAuth client secret and the one-time
authorization code as command line arguments, and to `sh` for writing the state
file. Command lines live in /proc/<pid>/cmdline, which is mode 0444 and
therefore readable by every user on the machine, so a bearer token for a
social account was published to any local process.

Here the access token and the client secret never cross a process boundary at
all: the panel passes only non-sensitive arguments (endpoint, status id, form
fields) and this script reads the credentials from the 0600 state file itself.
The two secrets that cannot be read from the file yet, the authorization code
and the instance chosen during login, arrive through the environment, because
/proc/<pid>/environ is mode 0400 and stays readable by the owner alone.

The instance is also taken from the state file rather than from the caller, so
a token can only ever be sent to the server it was issued for.
"""

import ipaddress
import json
import os
import sys
import urllib.error
import urllib.parse
import urllib.request

# Keep in sync with Model.js; tests/test_model.js asserts that they match.
APP_NAME = "Omarchy Mastodon"
APP_SCOPES = "read write follow"
APP_WEBSITE = "https://github.com/saigkill/omarchy-mastodon1"

TIMEOUT = 30

# The only keys the panel is allowed to write. clientSecret and accessToken are
# owned by this script so that a compromised or buggy panel cannot overwrite a
# valid token with a stale copy of its own.
WRITABLE_KEYS = ("instance", "clientId")

EXIT_USAGE = 2
EXIT_INSECURE = 3
EXIT_STATE = 4
EXIT_HTTP = 5
EXIT_NETWORK = 6


class HelperError(Exception):
    def __init__(self, message, status):
        super().__init__(message)
        self.message = message
        self.status = status


# ---------------------------------------------------------------- state file


def auth_file():
    override = os.environ.get("MASTODON_AUTH_FILE", "").strip()
    if override:
        return override
    base = os.environ.get("XDG_STATE_HOME", "").strip()
    if not base:
        base = os.path.join(os.path.expanduser("~"), ".local", "state")
    return os.path.join(base, "omarchy-mastodon", "auth.json")


def empty_auth():
    return {"instance": "", "clientId": "", "clientSecret": "", "accessToken": ""}


def read_state():
    try:
        with open(auth_file(), "r", encoding="utf-8") as handle:
            data = json.load(handle)
    except (OSError, ValueError):
        return {"auth": empty_auth()}
    if not isinstance(data, dict) or not isinstance(data.get("auth"), dict):
        return {"auth": empty_auth()}
    auth = empty_auth()
    for key, value in data["auth"].items():
        if key in auth:
            auth[key] = "" if value is None else str(value)
    return {"auth": auth}


def write_state(state):
    path = auth_file()
    directory = os.path.dirname(path)
    if directory:
        os.makedirs(directory, mode=0o700, exist_ok=True)
    payload = json.dumps({"auth": state["auth"]})
    # os.open only applies mode when it creates the file, and the process umask
    # can only ever remove bits, so the permissions are set again afterwards.
    # A pre-existing file from an older install also gets tightened here.
    descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
        os.fchmod(handle.fileno(), 0o600)
        handle.write(payload)


def public_state(state):
    """The view of the state file that is safe to hand back to the panel.

    The client secret and the access token are deliberately reduced to a
    boolean, so the panel has no copy of either and cannot leak one into its
    own logs, a crash dump or a stack trace.
    """
    auth = state["auth"]
    return {
        "auth": {
            "instance": auth["instance"],
            "clientId": auth["clientId"],
            "hasToken": bool(auth["accessToken"]),
        }
    }


# ------------------------------------------------------------------- URLs


def is_loopback(host):
    """True only for a name that really is this machine.

    A prefix test such as host.startswith("127.") is not enough: the name
    "127.0.0.1.evil.example" resolves through DNS and would be granted the
    plaintext exception, so the address has to be parsed as an address.
    """
    name = (host or "").strip("[]").rstrip(".").lower()
    if not name:
        return False
    if name == "localhost":
        return True
    try:
        return ipaddress.ip_address(name).is_loopback
    except ValueError:
        return False


def secure_base(instance):
    """Validate the API base URL and refuse to send a token without TLS."""
    raw = (instance or "").strip().rstrip("/")
    if not raw:
        raise HelperError("missing_instance", EXIT_USAGE)
    parts = urllib.parse.urlsplit(raw)
    if parts.scheme == "https" and parts.hostname:
        return raw
    if parts.scheme == "http" and is_loopback(parts.hostname):
        # The OAuth callback server is the one plaintext endpoint, and it is
        # bound to loopback. Any other http:// host would put the token, the
        # composed status and the password-free-but-private timeline on the
        # wire, so it is rejected instead of downgraded.
        return raw
    raise HelperError("insecure_instance", EXIT_INSECURE)


def endpoint_path(endpoint):
    """Accept only a path on the validated base, never a new origin.

    Rejecting "//host" and a missing leading slash stops a crafted endpoint
    from walking out of the base URL via urlsemantics or an authority
    component and shipping the bearer token somewhere else.
    """
    text = str(endpoint or "")
    if not text.startswith("/") or text.startswith("//"):
        raise HelperError("bad_endpoint", EXIT_USAGE)
    if "://" in text:
        raise HelperError("bad_endpoint", EXIT_USAGE)
    return text


def loopback_uri(uri):
    """Validate an OAuth redirect URI: it must point back at this machine."""
    parts = urllib.parse.urlsplit(str(uri or ""))
    if parts.scheme == "http" and is_loopback(parts.hostname):
        return str(uri)
    raise HelperError("bad_redirect_uri", EXIT_USAGE)


class SameOriginRedirect(urllib.request.HTTPRedirectHandler):
    """Never let a redirect carry the Authorization header to another origin."""

    max_redirections = 3

    def redirect_request(self, req, fp, code, msg, headers, newurl):
        current = urllib.parse.urlsplit(req.full_url)
        target = urllib.parse.urlsplit(newurl)
        if (current.scheme, current.netloc) != (target.scheme, target.netloc):
            raise HelperError("cross_origin_redirect", EXIT_HTTP)
        return super().redirect_request(req, fp, code, msg, headers, newurl)


# ------------------------------------------------------------------ request


def api_request(method, endpoint, auth, fields=None):
    token = auth.get("accessToken") or ""
    if not token:
        raise HelperError("not_authenticated", EXIT_STATE)
    url = secure_base(auth.get("instance")) + endpoint_path(endpoint)

    body = None
    headers = {
        "Accept": "application/json",
        "User-Agent": APP_NAME,
        "Authorization": "Bearer " + token,
    }
    if fields is not None:
        body = urllib.parse.urlencode(fields).encode("utf-8")
        headers["Content-Type"] = "application/x-www-form-urlencoded"

    request = urllib.request.Request(url, data=body, headers=headers, method=method)
    opener = urllib.request.build_opener(SameOriginRedirect)
    try:
        with opener.open(request, timeout=TIMEOUT) as response:
            payload = response.read()
    except urllib.error.HTTPError as error:
        # curl ran with -f, which also suppressed the body and returned a
        # non-zero status, so the panel already treats a failed page as
        # unparsable output. Keeping that contract avoids the panel mistaking a
        # transient error for an empty timeline and clearing the hasMore flag.
        raise HelperError("http_%d" % error.code, EXIT_HTTP) from None
    except (urllib.error.URLError, OSError):
        raise HelperError("network_error", EXIT_NETWORK) from None
    return payload.decode("utf-8", "replace")


def anonymous_post(endpoint, fields, auth):
    url = secure_base(auth.get("instance")) + endpoint_path(endpoint)
    body = urllib.parse.urlencode(fields).encode("utf-8")
    request = urllib.request.Request(
        url,
        data=body,
        method="POST",
        headers={
            "Accept": "application/json",
            "User-Agent": APP_NAME,
            "Content-Type": "application/x-www-form-urlencoded",
        },
    )
    opener = urllib.request.build_opener(SameOriginRedirect)
    try:
        with opener.open(request, timeout=TIMEOUT) as response:
            payload = response.read()
    except urllib.error.HTTPError as error:
        raise HelperError("http_%d" % error.code, EXIT_HTTP) from None
    except (urllib.error.URLError, OSError):
        raise HelperError("network_error", EXIT_NETWORK) from None
    return json.loads(payload.decode("utf-8", "replace"))


def emit(data):
    sys.stdout.write(json.dumps(data))
    sys.stdout.flush()


def emit_text(payload):
    sys.stdout.write(payload)
    sys.stdout.flush()


# -------------------------------------------------------------- subcommands


def cmd_load(_args):
    # A missing or unreadable file is not an error here: the panel asks for
    # the state on start up and has to fall back to "logged out".
    emit(public_state(read_state()))


def cmd_save(_args):
    raw = os.environ.get("MASTODON_AUTH_JSON", "")
    if not raw:
        raise HelperError("missing_auth_json", EXIT_USAGE)
    try:
        incoming = json.loads(raw).get("auth", {})
    except (AttributeError, ValueError):
        raise HelperError("invalid_auth_json", EXIT_USAGE) from None
    state = read_state()
    for key in WRITABLE_KEYS:
        if key in incoming:
            value = incoming.get(key)
            state["auth"][key] = "" if value is None else str(value).strip()
    if not state["auth"]["instance"]:
        state["auth"]["clientId"] = ""
    write_state(state)
    emit(public_state(state))


def cmd_logout(_args):
    state = {"auth": empty_auth()}
    write_state(state)
    emit(public_state(state))


def cmd_register(args):
    if len(args) != 1:
        raise HelperError("usage: register <redirect-uri>", EXIT_USAGE)
    redirect_uri = loopback_uri(args[0])
    state = read_state()
    state["auth"]["instance"] = secure_base(state["auth"]["instance"])
    data = anonymous_post(
        "/api/v1/apps",
        {
            "client_name": APP_NAME,
            "redirect_uris": redirect_uri,
            "scopes": APP_SCOPES,
            "website": APP_WEBSITE,
        },
        state["auth"],
    )
    if not isinstance(data, dict) or not data.get("client_id"):
        raise HelperError("register_failed", EXIT_HTTP)
    state["auth"]["clientId"] = str(data["client_id"])
    # The client secret is stored here and stays here; only the public client id
    # travels back to the panel, which needs it for the authorize URL.
    state["auth"]["clientSecret"] = str(data.get("client_secret") or "")
    write_state(state)
    emit({"client_id": state["auth"]["clientId"]})


def cmd_exchange(args):
    if len(args) != 1:
        raise HelperError("usage: exchange <redirect-uri>", EXIT_USAGE)
    redirect_uri = loopback_uri(args[0])
    code = os.environ.get("MASTODON_OAUTH_CODE", "")
    if not code:
        raise HelperError("missing_code", EXIT_USAGE)
    state = read_state()
    auth = state["auth"]
    if not auth["clientId"] or not auth["clientSecret"]:
        raise HelperError("missing_client", EXIT_STATE)
    data = anonymous_post(
        "/oauth/token",
        {
            "client_id": auth["clientId"],
            "client_secret": auth["clientSecret"],
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": redirect_uri,
        },
        auth,
    )
    token = data.get("access_token") if isinstance(data, dict) else None
    if not token:
        raise HelperError("token_exchange_failed", EXIT_HTTP)
    auth["accessToken"] = str(token)
    write_state(state)
    # The token is acknowledged, not returned: the panel re-reads the state
    # file through `load` and only ever learns whether a token exists.
    emit({"ok": True})


def cmd_get(args):
    if len(args) != 1:
        raise HelperError("usage: get <endpoint>", EXIT_USAGE)
    emit_text(api_request("GET", args[0], read_state()["auth"]))


def cmd_post(args):
    if len(args) < 1:
        raise HelperError("usage: post <endpoint> [key=value ...]", EXIT_USAGE)
    # Form fields are public by construction, the only ones the panel posts are
    # a status and the id it replies to.
    fields = {}
    for item in args[1:]:
        if "=" not in item:
            raise HelperError("bad_field", EXIT_USAGE)
        key, value = item.split("=", 1)
        fields[key] = value
    emit_text(api_request("POST", args[0], read_state()["auth"], fields))


COMMANDS = {
    "load": cmd_load,
    "save": cmd_save,
    "logout": cmd_logout,
    "register": cmd_register,
    "exchange": cmd_exchange,
    "get": cmd_get,
    "post": cmd_post,
}


def main(argv):
    if len(argv) < 2 or argv[1] not in COMMANDS:
        sys.stderr.write("usage: mastodon_helper.py <%s> [args]\n" % "|".join(sorted(COMMANDS)))
        return EXIT_USAGE
    try:
        COMMANDS[argv[1]](argv[2:])
    except HelperError as error:
        sys.stderr.write("MASTODON_ERROR:" + error.message + "\n")
        return error.status
    except ValueError:
        sys.stderr.write("MASTODON_ERROR:invalid_response\n")
        return EXIT_HTTP
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
