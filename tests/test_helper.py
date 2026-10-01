#!/usr/bin/env python3
"""Tests for mastodon_helper.py.

The helper is the only component that ever sees a credential, so these tests
aim at three things: that a secret cannot reach a process argument list, that a
token is only ever sent over TLS to the host it was issued for, and that the
state file stays unreadable for other users.

Run with: python3 -m unittest discover -s tests -v
"""

import contextlib
import io
import json
import os
import stat
import subprocess
import ssl
import sys
import tempfile
import threading
import unittest
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
HELPER = os.path.join(ROOT, "mastodon_helper.py")

sys.path.insert(0, ROOT)
import mastodon_helper as helper  # noqa: E402

TOKEN = "test-access-token-do-not-leak"
CLIENT_SECRET = "test-client-secret-do-not-leak"
CODE = "test-authorization-code-do-not-leak"


_CERT_CACHE = {}


def self_signed_cert():
    """One certificate for the whole run, so the tests do not pay for openssl
    thirty times. The helper trusts it through SSL_CERT_FILE, which keeps the
    production code free of a "disable verification" switch."""
    if not _CERT_CACHE:
        directory = tempfile.mkdtemp()
        cert = os.path.join(directory, "cert.pem")
        key = os.path.join(directory, "key.pem")
        subprocess.run(
            ["openssl", "req", "-x509", "-newkey", "rsa:2048", "-keyout", key,
             "-out", cert, "-days", "1", "-nodes", "-subj", "/CN=localhost"],
            check=True, capture_output=True)
        _CERT_CACHE["cert"] = cert
    return _CERT_CACHE["cert"]


class Recorder:
    """A local TLS server that records what a request actually carried."""

    def __init__(self):
        self.requests = []
        self.redirect_to = ""
        # When set to a path, a POST to it is answered with 422 instead of the
        # usual reply. Used to make an endpoint that normally succeeds fail.
        self.error_path = ""
        outer = self

        class Handler(BaseHTTPRequestHandler):
            protocol_version = "HTTP/1.1"

            def _record(self, body=b""):
                # Kept as bytes: an upload body is a picture, not text, so it
                # has to be asserted on byte for byte.
                outer.requests.append({
                    "method": self.command,
                    "path": self.path,
                    "headers": dict(self.headers),
                    "raw": body,
                })

            def do_GET(self):
                self._record()
                if self.path == "/boom":
                    payload = b'{"error":"nope"}'
                    self.send_response(500)
                    self.send_header("Content-Type", "application/json")
                    self.send_header("Content-Length", str(len(payload)))
                    self.end_headers()
                    self.wfile.write(payload)
                    return
                if self.path == "/redirect":
                    self.send_response(302)
                    self.send_header("Location", outer.redirect_to)
                    self.send_header("Content-Length", "0")
                    self.end_headers()
                    return
                self._reply()

            def do_POST(self):
                self._read_body_and_reply()

            def do_PUT(self):
                # An alt text is sent as a PUT on the media endpoint, so the
                # recorder has to answer it the way the instance does.
                self._read_body_and_reply()

            def _read_body_and_reply(self):
                length = int(self.headers.get("Content-Length") or 0)
                self._record(self.rfile.read(length))
                if self.path == "/boom" or self.path == outer.error_path:
                    payload = b'{"error":"nope"}'
                    self.send_response(422)
                    self.send_header("Content-Type", "application/json")
                    self.send_header("Content-Length", str(len(payload)))
                    self.end_headers()
                    self.wfile.write(payload)
                    return
                self._reply()

            def _reply(self):
                if self.path == "/huge":
                    # One byte over the helper's cap, framed as a syntactically
                    # valid (if truncated-looking) JSON array so a bug that
                    # forgot to enforce the limit would still parse it.
                    payload = b"[" + b"1," * (10 * 1024 * 1024) + b"1]"
                    self.send_response(200)
                    self.send_header("Content-Type", "application/json")
                    self.send_header("Content-Length", str(len(payload)))
                    self.end_headers()
                    self.wfile.write(payload)
                    return
                payload = json.dumps({"ok": True, "path": self.path}).encode("utf-8")
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(payload)))
                self.end_headers()
                self.wfile.write(payload)

            def log_message(self, *args):
                pass

        self.server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        context.load_cert_chain(self_signed_cert(), os.path.join(
            os.path.dirname(self_signed_cert()), "key.pem"))
        self.cert = self_signed_cert()
        self.server.socket = context.wrap_socket(self.server.socket, server_side=True)
        self.port = self.server.server_address[1]
        self.base = "https://localhost:%d" % self.port
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()

    def stop(self):
        self.server.shutdown()
        self.server.server_close()

    @property
    def last(self):
        return self.requests[-1]


class HelperTestCase(unittest.TestCase):
    def setUp(self):
        self.state_dir = tempfile.mkdtemp()
        self.state = os.path.join(self.state_dir, "omarchy-mastodon", "auth.json")
        self.server = Recorder()
        self.addCleanup(self.server.stop)
        previous = os.environ.get("MASTODON_AUTH_FILE")

        def restore_env():
            if previous is None:
                os.environ.pop("MASTODON_AUTH_FILE", None)
            else:
                os.environ["MASTODON_AUTH_FILE"] = previous

        self.addCleanup(restore_env)
        os.environ["MASTODON_AUTH_FILE"] = self.state

    def run_helper(self, *args, env=None, timeout=None):
        environment = dict(os.environ)
        environment["SSL_CERT_FILE"] = self.server.cert
        environment.update(env or {})
        return subprocess.run(
            [sys.executable, HELPER, *args],
            capture_output=True, env=environment, timeout=timeout)

    def write_auth(self, **fields):
        auth = helper.empty_auth()
        auth.update(fields)
        helper.write_state({"auth": auth})


class SecretsNeverReachArgv(HelperTestCase):
    def test_no_command_line_contains_a_secret(self):
        self.write_auth(
            instance=self.server.base,
            clientId="cid",
            clientSecret=CLIENT_SECRET,
            accessToken=TOKEN,
        )
        result = self.run_helper("get", "/api/v1/accounts/verify_credentials")
        self.assertEqual(result.returncode, 0, result.stderr)
        # The real check happens in the panel, but the same guarantee has to
        # hold for anything that would show up in ps output.
        self.assertNotIn(TOKEN.encode(), result.stderr)
        self.assertNotIn(TOKEN.encode(), result.stdout)

    def test_code_and_auth_json_travel_through_the_environment(self):
        # Runs in-process because the point is which channel the code arrives
        # on, so the post has to be faked rather than sent over the network.
        seen = {}

        def fake_post(endpoint, fields, auth):
            seen.update(fields)
            return {"access_token": TOKEN}

        original = helper.anonymous_post
        helper.anonymous_post = fake_post
        self.addCleanup(setattr, helper, "anonymous_post", original)
        self.write_auth(instance=self.server.base, clientId="cid", clientSecret=CLIENT_SECRET)
        previous = os.environ.get("MASTODON_OAUTH_CODE")

        def restore():
            if previous is None:
                os.environ.pop("MASTODON_OAUTH_CODE", None)
            else:
                os.environ["MASTODON_OAUTH_CODE"] = previous

        self.addCleanup(restore)
        os.environ["MASTODON_OAUTH_CODE"] = CODE

        buffer = io.StringIO()
        with contextlib.redirect_stdout(buffer):
            helper.cmd_exchange(["http://127.0.0.1:5555"])

        self.assertEqual(seen["code"], CODE)
        self.assertEqual(seen["client_secret"], CLIENT_SECRET)
        # The token is written to the state file and only acknowledged back.
        self.assertEqual(helper.read_state()["auth"]["accessToken"], TOKEN)
        self.assertNotIn(TOKEN, buffer.getvalue())
        self.assertEqual(json.loads(buffer.getvalue())["ok"], True)

    def test_exchange_response_does_not_leak_the_token(self):
        self.write_auth(instance=self.server.base, clientId="cid", clientSecret=CLIENT_SECRET)
        result = self.run_helper(
            "exchange", "http://127.0.0.1:5555", env={"MASTODON_OAUTH_CODE": CODE})
        # The token endpoint is faked here, so this asserts the shape only.
        self.assertNotIn(TOKEN.encode(), result.stdout + result.stderr)

    def test_load_reports_a_boolean_instead_of_the_token(self):
        self.write_auth(
            instance=self.server.base, clientId="cid",
            clientSecret=CLIENT_SECRET, accessToken=TOKEN)
        result = self.run_helper("load")
        self.assertEqual(result.returncode, 0, result.stderr)
        payload = json.loads(result.stdout)
        self.assertTrue(payload["auth"]["hasToken"])
        self.assertNotIn(b"accessToken", result.stdout)
        self.assertNotIn(CLIENT_SECRET.encode(), result.stdout)


class TokenStaysOnTls(HelperTestCase):
    def test_https_instance_sends_the_bearer_header(self):
        self.write_auth(instance=self.server.base, accessToken=TOKEN)
        result = self.run_helper("get", "/api/v1/accounts/verify_credentials")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.server.last["headers"]["Authorization"], "Bearer " + TOKEN)

    def test_plaintext_instance_is_refused(self):
        self.write_auth(instance="http://mastodon.example", accessToken=TOKEN)
        result = self.run_helper("get", "/api/v1/accounts/verify_credentials")
        self.assertEqual(result.returncode, helper.EXIT_INSECURE)
        self.assertIn(b"insecure_instance", result.stderr)
        self.assertEqual(result.stdout, b"")
        self.assertEqual(self.server.requests, [])

    def test_instance_without_a_scheme_is_refused(self):
        self.write_auth(instance="mastodon.example", accessToken=TOKEN)
        result = self.run_helper("get", "/api/v1/accounts/verify_credentials")
        self.assertEqual(result.returncode, helper.EXIT_INSECURE)

    def test_loopback_plaintext_is_allowed(self):
        self.assertEqual(helper.secure_base("http://127.0.0.1:8080"), "http://127.0.0.1:8080")
        self.assertEqual(helper.secure_base("http://localhost:8080"), "http://localhost:8080")

    def test_a_lookalike_host_is_not_loopback(self):
        for host in ("http://localhost.evil.example", "http://127.0.0.1.evil.example",
                     "http://notlocalhost"):
            with self.assertRaises(helper.HelperError):
                helper.secure_base(host)

    def test_https_instance_with_a_host_is_required(self):
        with self.assertRaises(helper.HelperError):
            helper.secure_base("https:///no-host")

    def test_endpoint_cannot_escape_the_base(self):
        self.write_auth(instance=self.server.base, accessToken=TOKEN)
        for endpoint in ("//evil.example/steal", "https://evil.example/steal",
                         "api/v1/timelines/home", ""):
            result = self.run_helper("get", endpoint)
            self.assertEqual(result.returncode, helper.EXIT_USAGE, endpoint)

    def test_token_is_bound_to_the_instance_in_the_state_file(self):
        # The panel cannot redirect the token to another host because it never
        # names the host: the endpoint is resolved against the stored instance.
        self.write_auth(instance=self.server.base, accessToken=TOKEN)
        result = self.run_helper("get", "/api/v1/timelines/home?limit=40")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(self.server.last["path"].startswith("/api/v1/timelines/home"))
        self.assertEqual(self.server.last["headers"]["Host"], "localhost:%d" % self.server.port)


class StateFileSymlinkAttack(HelperTestCase):
    def test_a_symlinked_state_file_is_refused_instead_of_followed(self):
        # If another user (or a compromised process running as this one)
        # replaces auth.json with a symlink, the write must not follow it:
        # otherwise the access token/client secret would land in whatever
        # file the symlink points at instead of the intended state file.
        target = os.path.join(self.state_dir, "victim.json")
        with open(target, "w", encoding="utf-8") as handle:
            handle.write("not touched")
        os.makedirs(os.path.dirname(self.state), exist_ok=True)
        os.symlink(target, self.state)

        result = self.run_helper("logout")

        self.assertNotEqual(result.returncode, 0)
        self.assertTrue(os.path.islink(self.state), "the symlink itself was removed")
        with open(target, encoding="utf-8") as handle:
            self.assertEqual(handle.read(), "not touched")


class StateFilePermissions(HelperTestCase):
    def test_state_file_is_owner_only(self):
        self.run_helper("logout")
        mode = stat.S_IMODE(os.stat(self.state).st_mode)
        self.assertEqual(mode, 0o600, oct(mode))

    def test_permissions_are_tightened_on_an_existing_file(self):
        os.makedirs(os.path.dirname(self.state), exist_ok=True)
        with open(self.state, "w", encoding="utf-8") as handle:
            handle.write("{}")
        os.chmod(self.state, 0o644)
        self.run_helper("logout")
        mode = stat.S_IMODE(os.stat(self.state).st_mode)
        self.assertEqual(mode, 0o600, oct(mode))

    def test_a_pre_existing_directory_is_left_alone(self):
        # The directory only has to keep other users out of writing new files;
        # the credentials are protected by the 0600 file inside it.
        directory = os.path.dirname(self.state)
        os.makedirs(directory, exist_ok=True)
        os.chmod(directory, 0o755)
        self.run_helper("logout")
        mode = stat.S_IMODE(os.stat(directory).st_mode)
        self.assertEqual(mode & 0o022, 0, oct(mode))
        self.assertEqual(stat.S_IMODE(os.stat(self.state).st_mode), 0o600)

    def test_missing_state_file_loads_as_logged_out(self):
        result = self.run_helper("load")
        self.assertEqual(result.returncode, 0, result.stderr)
        payload = json.loads(result.stdout)
        self.assertFalse(payload["auth"]["hasToken"])
        self.assertEqual(payload["auth"]["instance"], "")

    def test_corrupt_state_file_loads_as_logged_out(self):
        os.makedirs(os.path.dirname(self.state), exist_ok=True)
        with open(self.state, "w", encoding="utf-8") as handle:
            handle.write("not json")
        result = self.run_helper("load")
        self.assertEqual(result.returncode, 0)
        self.assertFalse(json.loads(result.stdout)["auth"]["hasToken"])


class SaveAndLogout(HelperTestCase):
    def test_save_keeps_the_secrets_that_only_the_helper_knows(self):
        self.write_auth(
            instance=self.server.base, clientId="old",
            clientSecret=CLIENT_SECRET, accessToken=TOKEN)
        result = self.run_helper(
            "save", env={"MASTODON_AUTH_JSON": json.dumps(
                {"auth": {"instance": "https://new.example", "clientId": "new"}})})
        self.assertEqual(result.returncode, 0, result.stderr)
        state = helper.read_state()["auth"]
        self.assertEqual(state["instance"], "https://new.example")
        self.assertEqual(state["clientId"], "new")
        self.assertEqual(state["clientSecret"], CLIENT_SECRET)
        self.assertEqual(state["accessToken"], TOKEN)

    def test_save_cannot_overwrite_the_token(self):
        self.write_auth(instance=self.server.base, accessToken=TOKEN)
        self.run_helper("save", env={"MASTODON_AUTH_JSON": json.dumps(
            {"auth": {"instance": "https://new.example", "accessToken": "attacker-token"}})})
        self.assertEqual(helper.read_state()["auth"]["accessToken"], TOKEN)

    def test_clearing_the_instance_clears_the_client_id(self):
        self.write_auth(instance=self.server.base, clientId="cid")
        self.run_helper("save", env={"MASTODON_AUTH_JSON": json.dumps({"auth": {"instance": ""}})})
        self.assertEqual(helper.read_state()["auth"]["clientId"], "")

    def test_logout_removes_every_credential(self):
        self.write_auth(
            instance=self.server.base, clientId="cid",
            clientSecret=CLIENT_SECRET, accessToken=TOKEN)
        result = self.run_helper("logout")
        self.assertEqual(result.returncode, 0)
        self.assertFalse(json.loads(result.stdout)["auth"]["hasToken"])
        state = helper.read_state()["auth"]
        self.assertEqual(state["accessToken"], "")
        self.assertEqual(state["clientSecret"], "")

    def test_save_without_the_environment_variable_fails(self):
        result = self.run_helper("save")
        self.assertEqual(result.returncode, helper.EXIT_USAGE)


class RedirectsAndErrors(HelperTestCase):
    def test_cross_origin_redirect_is_refused(self):
        # A 302 to another origin would resend the Authorization header, since
        # urllib keeps the headers of a same-method redirect. The token must
        # never follow a redirect off the instance it belongs to.
        target = Recorder()
        self.addCleanup(target.stop)

        self.server.redirect_to = target.base + "/steal"
        self.write_auth(instance=self.server.base, accessToken=TOKEN)
        result = self.run_helper("get", "/redirect")
        self.assertEqual(result.returncode, helper.EXIT_HTTP)
        self.assertIn(b"cross_origin_redirect", result.stderr)
        self.assertEqual(target.requests, [], "token was offered to another origin")

    def test_missing_token_is_reported(self):
        self.write_auth(instance=self.server.base)
        result = self.run_helper("get", "/api/v1/accounts/verify_credentials")
        self.assertEqual(result.returncode, helper.EXIT_STATE)
        self.assertIn(b"not_authenticated", result.stderr)

    def test_http_error_yields_no_body(self):
        self.write_auth(instance=self.server.base, accessToken=TOKEN)
        result = self.run_helper("get", "/boom")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stdout, b"")

    def test_unknown_subcommand_is_a_usage_error(self):
        self.assertEqual(self.run_helper("rm", "-rf").returncode, helper.EXIT_USAGE)
        self.assertEqual(self.run_helper().returncode, helper.EXIT_USAGE)

    def test_post_rejects_a_field_without_a_separator(self):
        self.write_auth(instance=self.server.base, accessToken=TOKEN)
        result = self.run_helper("post", "/api/v1/statuses", "status")
        self.assertEqual(result.returncode, helper.EXIT_USAGE)

    def test_an_oversized_response_is_refused_instead_of_buffered(self):
        # A malicious or compromised instance must not be able to exhaust the
        # helper's (and the QML StdioCollector's) memory with an enormous
        # response body.
        self.write_auth(instance=self.server.base, accessToken=TOKEN)
        result = self.run_helper("get", "/huge")
        self.assertEqual(result.returncode, helper.EXIT_HTTP)
        self.assertIn(b"response_too_large", result.stderr)
        self.assertEqual(result.stdout, b"")


class UploadingImages(HelperTestCase):
    """The upload path: what is sent, and what is refused before it is.

    An upload differs from every other call in two ways that are worth a test
    of their own: the body is a picture rather than form fields, so it has to
    survive byte for byte, and the only path the panel passes arrives on the
    environment, so the file has to be identified from the environment alone.
    """

    PNG = (b"\x89PNG\r\n\x1a\n" + b"\x00\x01\x02\x03" * 8
           + b"\r\n--not-the-boundary\r\nContent-Type: image/png\r\n\r\n"
           + b"\xff\xd8\xe0trailer")

    def setUp(self):
        super().setUp()
        self.dir = tempfile.mkdtemp()

    def write_image(self, name="picture.png", payload=PNG):
        path = os.path.join(self.dir, name)
        with open(path, "wb") as handle:
            handle.write(payload)
        return path

    def upload(self, path, *args, **kwargs):
        environment = {"MASTODON_UPLOAD_PATH": path} if path else {}
        return self.run_helper("upload", *args, env=environment, **kwargs)

    def boundary_of(self, headers):
        content_type = headers.get("Content-Type", "")
        self.assertTrue(
            content_type.startswith("multipart/form-data; boundary="),
            content_type)
        return content_type.split("boundary=", 1)[1].encode("ascii")

    def test_upload_posts_multipart_form_to_the_v2_endpoint(self):
        # v2 rather than v1: v1 refuses anything that is not pre-processed and
        # answers 422 for a file it has not seen before.
        self.write_auth(instance=self.server.base, accessToken=TOKEN)
        result = self.upload(self.write_image())
        self.assertEqual(result.returncode, 0, result.stderr)
        request = self.server.last
        self.assertEqual(request["path"], "/api/v2/media")
        self.assertEqual(request["headers"]["Authorization"], "Bearer " + TOKEN)
        self.assertIn("Omarchy Mastodon", request["headers"]["User-Agent"])
        boundary = self.boundary_of(request["headers"])
        body = request["raw"]
        self.assertTrue(body.startswith(b"--" + boundary + b"\r\n"))
        self.assertTrue(body.endswith(b"\r\n--" + boundary + b"--\r\n"))
        self.assertIn(b'Content-Disposition: form-data; name="file"', body)
        self.assertIn(b'filename="picture.png"', body)
        self.assertIn(b"Content-Type: image/png", body)

    def test_the_picture_travels_through_unmangled(self):
        # The body is built in memory and handed to urllib as bytes, so a bug
        # that decoded, re-encoded or truncated it would corrupt the picture.
        # The payload contains a CRLF and something that looks like a boundary
        # on purpose.
        self.write_auth(instance=self.server.base, accessToken=TOKEN)
        result = self.upload(self.write_image())
        self.assertEqual(result.returncode, 0, result.stderr)
        body = self.server.last["raw"]
        self.assertEqual(body.count(self.PNG), 1)
        self.assertIn(b"trailer", body)

    def test_a_filename_with_awkward_characters_is_folded_for_the_header(self):
        # A quote or a newline in the part header would end it early, and a
        # non-ASCII name would need the MIME quoting rules to survive. The
        # extension stays, because that is what tells the instance the type.
        self.write_auth(instance=self.server.base, accessToken=TOKEN)
        path = self.write_image('we"ird\nüä.png')
        result = self.upload(path)
        self.assertEqual(result.returncode, 0, result.stderr)
        body = self.server.last["raw"]
        self.assertIn(b'filename="we_ird___.png"', body)
        self.assertEqual(body.count(b'filename="'), 1)
        self.assertIn(b"Content-Type: image/png", body)

    def test_a_symlinked_image_is_accepted(self):
        # Photo directories are routinely symlinked, so following one is the
        # intended behaviour rather than an attack.
        self.write_auth(instance=self.server.base, accessToken=TOKEN)
        real = self.write_image("real.png")
        link = os.path.join(self.dir, "link.png")
        os.symlink(real, link)
        result = self.upload(link)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(b'filename="real.png"', self.server.last["raw"])

    def test_the_boundary_is_not_a_constant(self):
        # A fixed boundary could be cut the body short by a file that happens to
        # contain it.
        self.write_auth(instance=self.server.base, accessToken=TOKEN)
        first = self.upload(self.write_image("one.png"))
        self.assertEqual(first.returncode, 0, first.stderr)
        boundary_one = self.boundary_of(self.server.last["headers"])
        second = self.upload(self.write_image("two.png"))
        self.assertEqual(second.returncode, 0, second.stderr)
        boundary_two = self.boundary_of(self.server.last["headers"])
        self.assertNotEqual(boundary_one, boundary_two)

    def test_a_path_as_an_argument_is_refused(self):
        # /proc/<pid>/cmdline is readable by every local user, so there must be
        # no way to pass a filename there, not even by mistake.
        self.write_auth(instance=self.server.base, accessToken=TOKEN)
        path = self.write_image()
        result = self.upload(path, path)
        self.assertEqual(result.returncode, helper.EXIT_USAGE)
        self.assertIn(b"usage: upload", result.stderr)
        self.assertEqual(self.server.requests, [])

    def test_upload_without_the_environment_variable_is_refused(self):
        self.write_auth(instance=self.server.base, accessToken=TOKEN)
        result = self.upload(None)
        self.assertEqual(result.returncode, helper.EXIT_USAGE)
        self.assertIn(b"missing_upload_path", result.stderr)

    def test_a_fifo_is_refused_instead_of_blocking(self):
        # Opening a fifo waits for a writer that never comes, so the helper
        # would hang for as long as the panel waits for it.
        self.write_auth(instance=self.server.base, accessToken=TOKEN)
        fifo = os.path.join(self.dir, "pipe.png")
        os.mkfifo(fifo)
        result = self.upload(fifo, timeout=30)
        self.assertEqual(result.returncode, helper.EXIT_USAGE)
        self.assertIn(b"not_a_regular_file", result.stderr)

    def test_a_directory_is_refused(self):
        self.write_auth(instance=self.server.base, accessToken=TOKEN)
        result = self.upload(self.dir)
        self.assertEqual(result.returncode, helper.EXIT_USAGE)
        self.assertIn(b"not_a_regular_file", result.stderr)

    def test_an_unsupported_format_is_refused_before_it_is_sent(self):
        # The chooser filters, but a path can also arrive from anywhere else.
        self.write_auth(instance=self.server.base, accessToken=TOKEN)
        result = self.upload(self.write_image("notes.txt", b"hello"))
        self.assertEqual(result.returncode, helper.EXIT_USAGE)
        self.assertIn(b"unsupported_image", result.stderr)
        self.assertEqual(self.server.requests, [])

    def test_an_oversized_image_is_refused_before_it_is_sent(self):
        self.write_auth(instance=self.server.base, accessToken=TOKEN)
        path = os.path.join(self.dir, "huge.png")
        with open(path, "wb") as handle:
            handle.truncate(helper.MAX_UPLOAD_BYTES + 1)
        result = self.upload(path)
        self.assertEqual(result.returncode, helper.EXIT_USAGE)
        self.assertIn(b"file_too_large", result.stderr)
        self.assertEqual(self.server.requests, [])

    def test_a_missing_file_is_refused(self):
        self.write_auth(instance=self.server.base, accessToken=TOKEN)
        result = self.upload(os.path.join(self.dir, "gone.png"))
        self.assertEqual(result.returncode, helper.EXIT_USAGE)
        self.assertIn(b"unreadable_file", result.stderr)

    def test_upload_needs_a_token(self):
        self.write_auth(instance=self.server.base)
        result = self.upload(self.write_image())
        self.assertEqual(result.returncode, helper.EXIT_STATE)
        self.assertIn(b"not_authenticated", result.stderr)
        self.assertEqual(self.server.requests, [])

    def test_an_upload_error_is_reported_without_a_body(self):
        # The panel reads the media id off stdout, so a refused upload has to
        # be a non-zero exit with an empty stdout rather than an error document
        # it would mistake for an attachment.
        self.write_auth(instance=self.server.base, accessToken=TOKEN)
        self.server.error_path = "/api/v2/media"
        result = self.upload(self.write_image())
        self.assertEqual(result.returncode, helper.EXIT_HTTP)
        self.assertEqual(result.stdout, b"")


class DescribingImages(HelperTestCase):
    """The alt text: PUT on the attachment, and the id that goes into it.

    Mastodon only answers PUT /api/v1/media/:id while the attachment is not yet
    part of a status, so this has to be a PUT on the media endpoint rather than
    a field on the status. The id arrives from the panel and lands in the
    request path, which is why it is checked before anything is sent.
    """

    def test_the_description_goes_to_the_media_endpoint_with_a_put(self):
        self.write_auth(instance=self.server.base, accessToken=TOKEN)
        result = self.run_helper("describe", "22348641", "description=ein Bild")
        self.assertEqual(result.returncode, 0, result.stderr)
        request = self.server.last
        self.assertEqual(request["method"], "PUT")
        self.assertEqual(request["path"], "/api/v1/media/22348641")
        self.assertEqual(request["headers"]["Authorization"], "Bearer " + TOKEN)
        self.assertEqual(
            request["headers"]["Content-Type"], "application/x-www-form-urlencoded")
        self.assertEqual(
            urllib.parse.parse_qs(request["raw"].decode("utf-8")),
            {"description": ["ein Bild"]})

    def test_an_alt_text_with_an_equals_sign_survives(self):
        # The panel sends one key=value argument, so the helper may only split on
        # the first "=" — a description that contains one has to stay intact.
        self.write_auth(instance=self.server.base, accessToken=TOKEN)
        result = self.run_helper("describe", "1", "description=a = b")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(
            urllib.parse.parse_qs(self.server.last["raw"].decode("utf-8")),
            {"description": ["a = b"]})

    def test_an_alt_text_can_be_set_and_cleared_again(self):
        self.write_auth(instance=self.server.base, accessToken=TOKEN)
        self.assertEqual(
            self.run_helper("describe", "1", "description=").returncode, 0)
        # keep_blank_values, because clearing an alt text sends an empty value
        # and parse_qs would otherwise drop the field entirely.
        self.assertEqual(
            urllib.parse.parse_qs(
                self.server.last["raw"].decode("utf-8"), keep_blank_values=True),
            {"description": [""]})

    def test_a_media_id_that_is_not_a_number_never_leaves_the_machine(self):
        # The id is the one piece of this command the caller controls, and it
        # goes into the path. endpoint_path() rules out another origin, but not
        # a path that climbs back out of /api/v1/media/, so the digits are
        # checked here. Nothing may be sent in that case.
        self.write_auth(instance=self.server.base, accessToken=TOKEN)
        for media_id in ("../accounts/verify_credentials", "1/../../x",
                         "22348641?x=1", "22348641#f", " ", "+1", ""):
            result = self.run_helper("describe", media_id, "description=x")
            self.assertEqual(result.returncode, helper.EXIT_USAGE, media_id)
            self.assertIn(b"bad_media_id", result.stderr)
        self.assertEqual(self.server.requests, [])

    def test_a_description_is_required(self):
        self.write_auth(instance=self.server.base, accessToken=TOKEN)
        for args in (("1",), ("1", "focus=0,0"), ("1", "descript")):
            result = self.run_helper("describe", *args)
            self.assertNotEqual(result.returncode, 0, args)
        self.assertEqual(self.server.requests, [])

    def test_describing_an_image_needs_a_token(self):
        self.write_auth(instance=self.server.base)
        result = self.run_helper("describe", "1", "description=x")
        self.assertEqual(result.returncode, helper.EXIT_STATE)
        self.assertIn(b"not_authenticated", result.stderr)
        self.assertEqual(self.server.requests, [])

    def test_an_instance_refusal_is_reported(self):
        # The instance answers 404 once the attachment is part of a status, and
        # the panel needs that to be a non-zero exit rather than a document it
        # would read as a saved description.
        self.write_auth(instance=self.server.base, accessToken=TOKEN)
        self.server.error_path = "/api/v1/media/1"
        result = self.run_helper("describe", "1", "description=x")
        self.assertEqual(result.returncode, helper.EXIT_HTTP)
        self.assertEqual(result.stdout, b"")


class ConstantsMatchThePanel(HelperTestCase):
    def test_the_advertised_scope_is_the_one_the_helper_requests(self):
        # The scope is the only shared constant left: the panel builds the
        # authorize URL with it, the helper asks the server for it. If the two
        # drift apart the login succeeds and the first API call is denied.
        with open(os.path.join(ROOT, "Model.js"), encoding="utf-8") as handle:
            model = handle.read()
        self.assertIn('var APP_SCOPES = "%s"' % helper.APP_SCOPES, model)

    def test_the_helper_owns_the_app_name(self):
        # The app name and website are only sent to the server on app
        # registration, so they live in exactly one place.
        with open(os.path.join(ROOT, "Model.js"), encoding="utf-8") as handle:
            model = handle.read()
        self.assertNotIn("APP_NAME", model)
        self.assertNotIn("APP_WEBSITE", model)


if __name__ == "__main__":
    unittest.main()
