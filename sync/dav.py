"""HTTP and WebDAV plumbing shared by calsync.py and tasksync.py (standard
library only): https only except to localhost, no credentials across sites on
redirects, capped reads, server hrefs must stay inside their collection.
See docs/SECURITY.md.
"""

from __future__ import annotations

import base64
import ipaddress
import subprocess
import urllib.error
import urllib.parse
import urllib.request
import xml.etree.ElementTree as ET

UA = "Carts/0.5 (+https://omarchy.org)"
TIMEOUT = 25
MAX_BYTES = 20 * 1024 * 1024      # largest response we will read
MAX_ERROR_BYTES = 64 * 1024
LOCAL_HOSTS = {"localhost", "127.0.0.1", "::1"}

# Registrable suffixes with two labels: a host's parent must not be one of
# these, or "a.co.uk" would vouch for every other "*.co.uk" site.
PUBLIC_SUFFIXES = {
    "co.uk", "org.uk", "ac.uk", "gov.uk", "me.uk", "ltd.uk", "plc.uk", "net.uk",
    "com.au", "net.au", "org.au", "edu.au", "gov.au", "co.nz", "org.nz", "net.nz",
    "co.jp", "ne.jp", "or.jp", "ac.jp", "co.kr", "or.kr", "com.br", "net.br", "org.br",
    "com.cn", "net.cn", "org.cn", "com.tw", "com.hk", "com.sg", "com.my", "co.in", "net.in",
    "org.in", "co.za", "org.za", "com.mx", "com.ar", "com.tr", "co.il", "com.pl", "co.id",
    "github.io", "gitlab.io", "netlify.app", "vercel.app", "pages.dev", "herokuapp.com",
    "appspot.com", "blogspot.com", "cloudfront.net", "azurewebsites.net", "duckdns.org",
}
NS = {"d": "DAV:", "c": "urn:ietf:params:xml:ns:caldav", "a": "http://apple.com/ns/ical/", "cs": "http://calendarserver.org/ns/",
      "card": "urn:ietf:params:xml:ns:carddav"}

PROVIDERS = {
    "icloud": "https://caldav.icloud.com/",
    "fastmail": "https://caldav.fastmail.com/",
    "nextcloud": "",
    "caldav": "",
}

class Failure(Exception):
    pass


# --------------------------------------------------------------------------
# Secrets (secret-tool; the service names the app)
# --------------------------------------------------------------------------

def secret_get(service: str, key: str) -> str | None:
    try:
        r = subprocess.run(["secret-tool", "lookup", "service", service, "key", key],
                           capture_output=True, text=True, timeout=30)
    except FileNotFoundError:
        raise Failure("secret-tool not found (install libsecret)")
    except subprocess.TimeoutExpired:
        raise Failure("Keyring did not answer (is it locked?)")
    return r.stdout if r.returncode == 0 and r.stdout else None


def secret_set(service: str, key: str, value: str, label: str):
    try:
        r = subprocess.run(["secret-tool", "store", f"--label={label}", "service", service, "key", key],
                           input=value, capture_output=True, text=True, timeout=60)
    except FileNotFoundError:
        raise Failure("secret-tool not found (install libsecret)")
    except subprocess.TimeoutExpired:
        raise Failure("Keyring did not answer (is it locked?)")
    if r.returncode != 0:
        raise Failure("Could not save to the keyring: " + (r.stderr.strip() or "unknown error"))


def secret_clear(service: str, key: str):
    try:
        subprocess.run(["secret-tool", "clear", "service", service, "key", key], capture_output=True, timeout=30)
    except (FileNotFoundError, subprocess.TimeoutExpired):
        pass


# --------------------------------------------------------------------------
# HTTP
# --------------------------------------------------------------------------

def check_url(url):
    """https anywhere; plain http only to this machine (local test servers)."""
    parts = urllib.parse.urlsplit(url)
    scheme, host = parts.scheme.lower(), (parts.hostname or "").lower()
    if not host:
        raise Failure("That address has no server name")
    if scheme == "https" or (scheme == "http" and host in LOCAL_HOSTS):
        return url
    if scheme == "http":
        raise Failure("Only https:// addresses are allowed (http would send your data unencrypted)")
    raise Failure(f"Unsupported address type {scheme or '(none)'}://")


def _redirect_ok(orig, nxt, with_auth):
    """May a request (carrying credentials if with_auth) follow orig -> nxt?"""
    a, b = urllib.parse.urlsplit(orig), urllib.parse.urlsplit(nxt)
    try:
        check_url(nxt)
    except Failure:
        return False
    if a.scheme.lower() == "https" and b.scheme.lower() != "https":
        return False
    if not with_auth:
        return True
    ha, hb = (a.hostname or "").lower(), (b.hostname or "").lower()
    if ha == hb:
        return True
    if _is_ip(ha) or _is_ip(hb):
        return False
    # A sibling or child of the original host: caldav.icloud.com may hand
    # off to p52-caldav.icloud.com. The parent must be a real domain, not a
    # public suffix, and the match is on a label boundary.
    labels = ha.split(".")
    parent = ".".join(labels[1:]) if len(labels) >= 3 else ha
    if parent.count(".") < 1 or parent in PUBLIC_SUFFIXES:
        return hb.endswith("." + ha)
    return hb == parent or hb.endswith("." + parent)


def _is_ip(host):
    try:
        ipaddress.ip_address(host)
        return True
    except ValueError:
        return False


def owned(cal_url, href):
    """Is href an object inside the calendar collection at cal_url?"""
    if not href:
        return False
    c, h = urllib.parse.urlsplit(cal_url), urllib.parse.urlsplit(href)
    if (c.scheme.lower(), (c.hostname or "").lower(), c.port) != (h.scheme.lower(), (h.hostname or "").lower(), h.port):
        return False
    base = c.path if c.path.endswith("/") else c.path + "/"
    path, base = urllib.parse.unquote(h.path), urllib.parse.unquote(base)
    # Dot segments anywhere ("/cal/..", "/cal/./x/..") could resolve outside.
    if any(seg in (".", "..") for seg in path.split("/")):
        return False
    return path.startswith(base) and len(path) > len(base)


def _read_capped(fp, limit):
    chunks, total = [], 0
    while True:
        chunk = fp.read(65536)
        if not chunk:
            return b"".join(chunks)
        total += len(chunk)
        if total > limit:
            raise Failure(f"Server sent more than {limit // (1024 * 1024) or 1} MB; refusing to read it")
        chunks.append(chunk)

class _NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *args, **kwargs):
        return None


_opener = urllib.request.build_opener(_NoRedirect)


def http(method, url, body=None, headers=None, auth=None, redirects=5):
    hdrs = {"User-Agent": UA}
    hdrs.update(headers or {})
    if auth:
        token = base64.b64encode(f"{auth[0]}:{auth[1]}".encode()).decode()
        hdrs["Authorization"] = "Basic " + token
    data = body.encode("utf-8") if isinstance(body, str) else body
    check_url(url)
    for _ in range(redirects + 1):
        req = urllib.request.Request(url, data=data, method=method, headers=hdrs)
        try:
            with _opener.open(req, timeout=TIMEOUT) as resp:
                return resp.status, dict(resp.headers), _read_capped(resp, MAX_BYTES)
        except urllib.error.HTTPError as e:
            if e.code in (301, 302, 303, 307, 308) and e.headers.get("Location"):
                nxt = urllib.parse.urljoin(url, e.headers["Location"])
                if not _redirect_ok(url, nxt, bool(auth)):
                    if auth:
                        raise Failure("Server redirected to another site; refusing to send the password there")
                    raise Failure("Server redirected to an address that is not https; refusing to follow")
                if e.code == 303:
                    method, data = "GET", None
                url = nxt
                continue
            try:
                err_body = _read_capped(e, MAX_ERROR_BYTES) if e.fp else b""
            except Failure:
                err_body = b""
            return e.code, dict(e.headers or {}), err_body
        except urllib.error.URLError as e:
            raise Failure(f"Could not reach {urllib.parse.urlsplit(url).hostname}: {e.reason}")
        except TimeoutError:
            raise Failure(f"Timed out talking to {urllib.parse.urlsplit(url).hostname}")
    raise Failure("Too many redirects")


def decode(body: bytes) -> str:
    for enc in ("utf-8", "latin-1"):
        try:
            return body.decode(enc)
        except UnicodeDecodeError:
            continue
    return body.decode("utf-8", "replace")


def parse_xml(body: bytes):
    try:
        return ET.fromstring(body)
    except ET.ParseError:
        raise Failure("Server sent a response that is not valid XML")


def propfind(url, auth, props_xml, depth="0"):
    body = f'<?xml version="1.0" encoding="utf-8"?><d:propfind xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav" xmlns:a="http://apple.com/ns/ical/" xmlns:cs="http://calendarserver.org/ns/" xmlns:card="urn:ietf:params:xml:ns:carddav"><d:prop>{props_xml}</d:prop></d:propfind>'
    status, _, resp = http("PROPFIND", url, body, {"Depth": depth, "Content-Type": "application/xml; charset=utf-8"}, auth)
    if status == 401:
        raise Failure("Sign-in failed: check the username and app-specific password")
    if status == 403:
        raise Failure("The server refused access (403)")
    if status not in (207, 200):
        raise Failure(f"Server answered {status} to PROPFIND")
    return parse_xml(resp)


def href_of(root, path):
    el = root.find(path, NS)
    return el.text.strip() if el is not None and el.text else None


def collection_tag(url, auth):
    """The collection's change tag (CalendarServer ctag or DAV sync-token), or "".

    Any change to any object in the collection changes it, so an equal tag means
    the REPORT would return what we already have.
    """
    try:
        root = propfind(url, auth, "<cs:getctag/><d:sync-token/>")
    except Failure:
        return ""
    ctag = href_of(root, ".//cs:getctag") or ""
    token = href_of(root, ".//d:sync-token") or ""
    return (ctag + "|" + token) if (ctag or token) else ""


def principal(base, auth, well_known="/.well-known/caldav"):
    tried = []
    for cand in (base, urllib.parse.urljoin(base, well_known)):
        try:
            root = propfind(cand, auth, "<d:current-user-principal/>")
        except Failure as e:
            if "Sign-in failed" in str(e):
                raise
            tried.append(str(e))
            continue
        href = href_of(root, ".//d:current-user-principal/d:href")
        if href:
            return urllib.parse.urljoin(cand, href)
    raise Failure("Could not find an account at that address" + (f" ({tried[-1]})" if tried else ""))
