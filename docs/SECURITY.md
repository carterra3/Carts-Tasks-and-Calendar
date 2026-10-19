# Security model

Carts talks to servers you configure (CalDAV, CardDAV, ICS links) and keeps
account passwords and private calendar links. This is what the sync helper
(`sync/calsync.py`) does to keep them safe.

## Secrets

- Passwords and private links are stored in the desktop keyring through
  `secret-tool` (service `carts`). They are never written to the JSON files
  and never appear on a command line; the QML hands them to the helper on
  stdin.
- The data folder (`~/.local/share/carts`) is mode 700 and the helper runs
  with `umask 077`.

## Talking to servers

- **Schemes.** Only `https://` is allowed, except plain `http://` to this
  machine (`localhost`, `127.0.0.1`, `::1`) for local test servers. `webcal://`
  is rewritten to `https://`. Every redirect hop is checked again, so a
  redirect can't reach `file://` or downgrade https to http.
- **Redirects with credentials.** The `Authorization` header is only sent on
  a redirect to the same host or a real subdomain of the original host's
  parent domain (e.g. `caldav.icloud.com` → `p52-caldav.icloud.com`), never
  to a look-alike (`evilicloud.com`) or a sibling under a public suffix
  (`co.uk`). Links without credentials may redirect anywhere (Google feeds
  do).
- **Server-supplied hrefs are untrusted.** A CalDAV/CardDAV href is only used
  when it is on the same scheme, host and port, sits under the collection's
  path, and has no `.`/`..` segment after percent-decoding. This is checked at
  sync and again right before every PUT or DELETE.
- **Bounded reads.** Response bodies are read in chunks with a size cap
  (20 MB; 64 KB for error bodies).
- **No silent overwrites.** Edits are sent with `If-Match`, so an item
  changed elsewhere since the last sync is reported, not overwritten.

## Reporting a problem

Please open an issue, or for something sensitive, contact the maintainer
through GitHub before posting details.
