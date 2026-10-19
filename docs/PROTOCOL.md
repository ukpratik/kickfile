# kickFile wire protocol, version 1

This document describes protocol v1 as implemented in `app/lib/core/` and `app/lib/net/`, in enough detail to write a compatible client or server. Where this document and the code disagree, the code wins; please open an issue.

Every device is both a server (receiver) and a client (sender). A transfer goes from sender to receiver: the sender offers a list of items, the receiver accepts or declines, then the sender uploads each file and confirms its hash.

## Conventions

- **Fingerprint**: lowercase hex SHA-256 of a device's certificate in DER form, 64 characters. It is the device's identity everywhere (`fp`).
- **Platform**: one of `android`, `ios`, `macos`, `windows`, `linux`. Unknown values are read as `unknown`.
- Times are integers in milliseconds since the Unix epoch.
- All JSON is UTF-8. Unknown fields are ignored by v1 parsers.

## Transport

- HTTPS (HTTP/1.1 over TLS) on TCP. Default port **47420**. If the port is taken, the app binds an OS-assigned port and announces that port instead.
- The server listens on all IPv4 interfaces. Only IPv4 is used for discovery and pairing.
- Each device has one long-lived identity:
  - EC key on curve P-256 (`prime256v1`).
  - A self-signed X.509 certificate, subject `CN=kickfile`, serial 1, valid for 20 years.
  - Fingerprint = SHA-256 of the certificate DER.
- The server presents this certificate. The client trusts no CA and ignores the host name: it accepts the connection only if the SHA-256 of the presented certificate equals the fingerprint it expects for that peer.
- When the client doesn't know the fingerprint yet (subnet probe, short code), it accepts any certificate for `GET /v1/info` only, and then requires the `fp` in the response to equal the fingerprint of the certificate it saw. Otherwise the response is rejected.
- Certificate validity dates, issuer signature and extensions are not checked. The key is the identity.

### Why not mutual TLS

The receiver must also know who the sender is. With `dart:io`, a server that asks for a client certificate can't accept an unknown self-signed one (the handshake fails, and there is no verification callback). So the server only authenticates itself in TLS. The sender authenticates each request at the HTTP layer with a signed header, `X-KF-Auth`, using the same key and certificate it would have used for mutual TLS.

## Sender authentication: `X-KF-Auth`

Every request except `GET /v1/info` must carry this header. On `GET /v1/info` it is optional (it lets a Hidden device recognise trusted callers).

### Header value

```
X-KF-Auth: base64url( UTF-8( JSON {"c": ..., "t": ..., "n": ..., "s": ...} ) )
```

The outer encoding is base64url (RFC 4648 §5). The app sends it with `=` padding; receivers accept it with or without padding.

| Field | Type | Value |
|---|---|---|
| `c` | string | The sender's certificate, DER, standard base64 (with padding). |
| `t` | integer | Request time, ms since epoch. |
| `n` | string | Nonce, at most 64 characters. The app uses base64url of 16 random bytes. |
| `s` | string | ECDSA P-256 signature with SHA-256 over the signed bytes below. DER-encoded `SEQUENCE { INTEGER r, INTEGER s }`, standard base64. |

### Signed bytes

The UTF-8 encoding of these six lines joined by `\n` (no trailing newline):

```
kfv1
<METHOD>
<path-with-query>
<receiver-fingerprint>
<t>
<n>
```

- `<METHOD>`: the HTTP method in upper case (`GET`, `POST`, `PUT`).
- `<path-with-query>`: the request target exactly as sent: the path, plus `?` and the query if there is one. Example: `/v1/transfers/0b5d...e1/items/i3?offset=1048576`. All ids and values in v1 paths use unreserved characters only, so no percent-encoding is involved.
- `<receiver-fingerprint>`: the fingerprint of the receiver the client pinned for this connection. This binds the request to one receiver, so a captured header can't be replayed to another device.
- `<t>`: the same integer as the `t` field, in decimal.
- `<n>`: the same string as the `n` field.

The request body is not signed. Its integrity comes from TLS to the pinned receiver, and for file content also from the SHA-256 sent in `done`.

### Verification (receiver)

1. Decode base64url, then JSON. `c`, `n`, `s` must be strings, `t` an integer, `n` at most 64 characters.
2. `|now - t|` must be at most 5 minutes.
3. Decode `c`; the caller's fingerprint is SHA-256 of these bytes. Take the EC public key from the certificate's SubjectPublicKeyInfo.
4. Verify `s` over the signed bytes, built with the receiver's own fingerprint, the actual method and the actual path and query.
5. Reject a `(fingerprint, n)` pair already seen. The cache holds the most recent 4096 pairs; together with the 5-minute window this stops replays.

The verified fingerprint is the caller's identity for trust, blocking and transfer ownership. Any failure gives `401` with `"error": "unauthorized"` and one of these messages: `missing`, `malformed`, `fields`, `clock`, `cert`, `certificate`, `signature`, `replay`.

## Verification code (SAS)

On first contact, both devices show a 6-digit code that the users can compare. It depends only on the two fingerprints and is the same on both sides:

```
lo, hi = sort([fpA, fpB])                     # lexicographic, lowercase hex
d      = SHA-256( UTF-8("kickfile-sas-v1\n" + lo + "\n" + hi) )
n      = ((d[0] << 24) | (d[1] << 16) | (d[2] << 8) | d[3]) mod 1000000   # unsigned big-endian
code   = zero-pad(n, 6)                       # shown as "482 913"
```

The receiver shows it on its first-contact prompt; the sender shows it while waiting for an answer. Devices paired by QR code don't need it.

## Discovery

### DNS-SD

| Item | Value |
|---|---|
| Service type | `_kickfile._tcp` |
| Instance name | The device name |
| Port | The server's port (normally 47420) |
| TXT `v` | Protocol version, `1` |
| TXT `fp` | The device's fingerprint |
| TXT `p` | The device's platform |

A device announces only while it is Visible. A browser should:

1. Ignore its own `fp` and any `fp` that isn't 64 lowercase hex characters.
2. Treat a `v` other than `1` as an incompatible device and not contact it.
3. Confirm the device with `GET /v1/info` over TLS pinned to the TXT `fp`, using the resolved IPv4 addresses. Only a successful pinned request makes the device "online".

### Subnet probe

When DNS-SD finds nothing (for example on networks that block multicast), the app sends `GET /v1/info` to every host `x.y.z.1` to `x.y.z.254` of each of its own IPv4 /24 networks, on port 47420, without a known fingerprint (see Transport). It uses up to 64 parallel requests with a 600 ms timeout. Devices on a non-default port, and Hidden devices, are not found this way.

### Liveness

The app re-sends pinned `GET /v1/info` to known devices every 4 seconds (2 s timeout) and marks a device offline after two failures. Any verified request from a device also marks it online at its source address.

## Pairing

### QR link

```
kickfile://c?v=1&a=192.168.1.23,10.0.0.4&p=47420&fp=<64 hex>&s=482913&n=Arjun%27s%20MacBook
```

| Parameter | Meaning | Rules |
|---|---|---|
| `v` | Protocol version | Must be `1`, otherwise the code is rejected as a version mismatch. |
| `a` | IPv4 addresses of the showing device, comma-separated, best first | Entries that aren't dotted-decimal IPv4 are dropped; at least one must remain. |
| `p` | Server port | 1 to 65535 |
| `fp` | Fingerprint | `^[0-9a-f]{64}$` |
| `s` | One-time pairing secret | `^\d{6}$` |
| `n` | Device name | Control characters removed, cut to 64 characters |

Parameters are query-encoded. On Android the link is also an intent (`VIEW` with scheme `kickfile`), so a camera app can open it.

The secret is a random number from 100000 to 999999. It is valid for 10 minutes and is cleared after one successful pairing or when the QR screen closes.

### Short code

The typed fallback is `<last octet>-<secret>`, for example `23-482913`, where the last octet is from the first address in `a`. It is offered only when the port is 47420. Input is accepted as `23-482913`, `23 482913` or `23-482 913`. The host is the scanner's own IPv4 address with its last octet replaced (1 to 254), so it works only when both devices are on the same /24 network.

### Pairing sequence

The scanning device (S) pairs with the showing device (D):

1. S: `GET /v1/info?s=<secret>`, signed. With a QR code, TLS is pinned to `fp` and each address in `a` is tried in order. With a short code, the fingerprint is learnt from the response (see Transport).
2. S: `POST /v1/pair` with the secret and its own details, signed.
3. On `200`, D marks the caller's fingerprint (from `X-KF-Auth`) as trusted and unblocked, and S marks D as trusted. Later transfers between them show no verification code.

## Endpoints

All paths start with `/v1/`. Request and response bodies are JSON (`Content-Type: application/json`), except the file upload body. JSON request bodies may be at most 4 MiB. Every response, including errors, has a JSON body.

| Method | Path | Auth | Purpose |
|---|---|---|---|
| `GET` | `/v1/info[?s=<secret>]` | optional | Device info |
| `POST` | `/v1/pair` | required | Pair with a QR or short-code secret |
| `POST` | `/v1/transfers` | required | Offer a transfer, or resume one |
| `PUT` | `/v1/transfers/{tid}/items/{iid}?offset=<n>` | required | Upload the rest of one file |
| `POST` | `/v1/transfers/{tid}/items/{iid}/done` | required | Confirm one file's SHA-256 |
| `POST` | `/v1/transfers/{tid}/finish` | required | End the transfer |
| `POST` | `/v1/transfers/{tid}/cancel` | required | Cancel the transfer |

Any other method or path returns `404 not_found`.

### `GET /v1/info`

Response `200`:

```json
{"v": 1, "fp": "3f9a...c2", "name": "Arjun's MacBook", "platform": "macos", "port": 47420}
```

| Field | Type | Meaning |
|---|---|---|
| `v` | integer | Protocol version. A client must treat anything other than `1` as a version mismatch. |
| `fp` | string | Fingerprint; must equal the server certificate's fingerprint. |
| `name` | string | Device name (clients clean it: control characters removed, at most 64 characters). |
| `platform` | string | Platform |
| `port` | integer | The port the server listens on |

If the device is Hidden, it answers `404 not_found` unless the request has a valid `X-KF-Auth` from a trusted device, or `s` is the current pairing secret. An invalid `X-KF-Auth` on this endpoint is ignored (the request is treated as anonymous), not rejected.

### `POST /v1/pair`

Request:

```json
{"secret": "482913", "name": "Pixel 8", "platform": "android", "port": 47420}
```

`secret` is required. `port` defaults to 47420 if missing. Response `200`: the receiver's info object, as for `/v1/info`.

Errors: `401 unauthorized`, `403 bad_secret` (missing, wrong or expired secret).

### `POST /v1/transfers` (offer)

Request:

```json
{
  "id": "0b5d1c7e-3a2f-4f7e-9d61-2c8e5b9a41e1",
  "name": "Pixel 8",
  "platform": "android",
  "items": [
    {"id": "i0", "kind": "dir",  "path": "Trip",           "size": 0,       "mtime": 0},
    {"id": "i1", "kind": "file", "path": "Trip/IMG_1.jpg", "size": 3145728, "mtime": 1760860800000},
    {"id": "i2", "kind": "text", "path": "Text",           "size": 0,       "mtime": 0, "text": "Hello"}
  ]
}
```

| Field | Rules |
|---|---|
| `id` | Transfer id, `^[A-Za-z0-9-]{8,64}$`. The app uses a UUID v4. It is also the resume key. |
| `name` | Sender's device name, string of at most 256 characters (cleaned to 64). |
| `platform` | Sender's platform. |
| `items` | 1 to 10,000 items. |
| `items[].id` | `^[A-Za-z0-9_-]{1,32}$`, unique in the offer. The app uses `i0`, `i1`, ... |
| `items[].kind` | `file`, `dir` or `text`. Anything else is `422`. |
| `items[].path` | At most 4096 characters. For `file` and `dir`, a relative path (rules below), unique among file and dir items. For `text`, a free-form label. |
| `items[].size` | Integer, 0 to 2^50. Bytes for a file; must be 0 for a dir. |
| `items[].mtime` | Optional integer, ms since epoch, 0 if unknown. The receiver sets it on the saved file. |
| `items[].text` | Text items only: 1 to 100,000 characters. Not allowed on file or dir items. |

Relative path rules (file and dir): `/` separators; not empty; no leading `/`; no drive prefix like `C:`; no `\` or NUL; no empty, `.` or `..` segments; at most 64 segments. A dir item creates a folder, which also allows empty folders. The receiver then makes each segment safe for its file system: it replaces `< > : " | ? * \ /` and control characters with `_`, strips trailing dots and spaces, prefixes Windows reserved names (`CON`, `NUL`, `COM1`, ...) with `_`, and cuts each segment to 200 UTF-8 bytes, keeping an extension of up to 16 characters. If the name exists, it saves as `name (1).ext`, `name (2).ext`, and so on.

The receiver handles an offer in this order:

1. Blocked sender: `403 declined`.
2. Transfer id cancelled earlier: `410 cancelled`.
3. Transfer id known (active or paused): resume (see Resume). If it belongs to another sender: `422 invalid_offer` (`id in use`).
4. Another new offer from the same sender within 5 seconds: `429 rate_limited`.
5. Not enough free space for the total file size plus 64 MiB: `507 no_space` with `needed` and `free`.
6. Another prompt is open, or another transfer moved data in the last 30 seconds: `409 busy`.
7. Ask the user, unless the sender is trusted with auto-accept on. **The request stays open until the user answers**, for up to 60 seconds. Clients should wait at least 75 seconds.

Response `200`:

```json
{"accepted": true, "offsets": {"i1": 0}, "done": ["i0", "i2"]}
```

| Field | Meaning |
|---|---|
| `accepted` | Always `true` on `200`. |
| `offsets` | For each file item still to send: the byte offset to upload from. |
| `done` | Items already complete. On a new transfer, these are the dir and text items: text arrives in the offer itself. |

Errors: `403 declined` (declined or blocked by the user), `408 timeout` (no answer in 60 s), `409 busy`, `410 cancelled` (the sender cancelled while the prompt was open), `422 invalid_offer`, `429 rate_limited`, `507 no_space`.

### `PUT /v1/transfers/{tid}/items/{iid}?offset=<n>` (upload)

Uploads the bytes of one file from `offset` to its end, in one request.

- `Content-Length` is required and must equal `size - offset`. A chunked body is rejected (`422`).
- `Content-Type: application/octet-stream`.
- `offset` must be `0` (start over) or equal to the number of bytes the receiver has. Otherwise `409 offset_mismatch` with `received`.

Response `200`:

```json
{"received": 3145728}
```

If the item is already complete, the receiver answers `200` with `received` equal to the size, without reading the body.

Errors:

| Status | `error` | When |
|---|---|---|
| 401 | `unauthorized` | Not the sender of this transfer. |
| 404 | `unknown_transfer` | No such transfer (also after finish). |
| 404 | `not_found` | No such item. |
| 409 | `offset_mismatch` | Wrong offset; body has `received`. |
| 409 | `busy` | The transfer is paused and another one is active. |
| 410 | `cancelled` | The transfer was cancelled. |
| 422 | `invalid_offer` | Not a file item, missing or bad `offset`, or `offset + Content-Length != size`. |
| 507 | `no_space` | The disk filled up. The transfer is paused; re-offer when there is room. |
| 500 | `unreachable` | The body ended early, or a newer upload of the same item took over. The partial is kept. |
| 500 | `io` | Write error. |

A PUT to a paused transfer resumes it without a new offer, if the receiver isn't busy.

### `POST /v1/transfers/{tid}/items/{iid}/done`

Request:

```json
{"sha256": "9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08"}
```

`sha256` is the lowercase hex SHA-256 of the whole file. The receiver compares it with the hash of the bytes it received; on success it moves the file into place. Response `200 {}`. Calling it again for a complete item also returns `200 {}`.

Errors: `409 offset_mismatch` with `received` (the file isn't complete), `422 hash_mismatch` (the partial is deleted; upload again from offset 0), `422 invalid_offer` (bad `sha256`), `404`, `401`, `410` as for upload, `500 io`.

### `POST /v1/transfers/{tid}/finish`

Request body `{}`. Response `200 {}`. The receiver ends the transfer: complete if every item is done, otherwise partial (the sender skipped items, for example a file that changed or was deleted). Leftover partial data is deleted. The transfer id is then unknown (`404 unknown_transfer`).

### `POST /v1/transfers/{tid}/cancel`

Request body `{}`. Response `200 {}`. Cancels an active or paused transfer and deletes its partial data. If the offer is still waiting for the user, the prompt closes and the open offer request returns `410 cancelled`. An unknown id is a no-op (`200 {}`). A transfer from another sender: `401 unauthorized`. After a cancel, any request for that id returns `410 cancelled`.

The receiving user can also cancel: the sender's next request then gets `410 cancelled`.

## Errors

Every error response has this body:

```json
{"error": "offset_mismatch", "message": null, "received": 1048576}
```

`error` is a stable code, `message` an optional detail for logs (not for display), and some codes add fields.

| `error` | Status | Extra fields |
|---|---|---|
| `unauthorized` | 401 | |
| `declined` | 403 | |
| `bad_secret` | 403 | |
| `not_found` | 404 | |
| `unknown_transfer` | 404 | |
| `timeout` | 408 | |
| `busy` | 409 | |
| `offset_mismatch` | 409 | `received` |
| `cancelled` | 410 | |
| `invalid_offer` | 422 | |
| `hash_mismatch` | 422 | |
| `version_mismatch` | 426 | Reserved; a v1 server doesn't send it. |
| `rate_limited` | 429 | |
| `io` | 500 | |
| `protocol` | 500 | Also used for unexpected server errors. |
| `unreachable` | 500 | |
| `no_space` | 507 | `needed`, `free` (bytes) |

Clients should switch on `error`, not on the status code (`busy` and `offset_mismatch` share 409). An unknown `error` should be treated as `protocol`.

## Resume

- The transfer id is the resume key. To resume, the sender sends the **same offer** again (same id and items). The receiver answers `200` with `offsets` from the partial data it has on disk (a partial longer than the file counts as 0) and `done` with the finished items. No prompt is shown.
- The sender then uploads each remaining file from its offset. To produce the whole-file hash for `done`, it hashes bytes `[0, offset)` from its own copy first. Before resuming, the app checks that the source file's size and mtime still match the offer; if not, it skips the item.
- The receiver pauses a transfer when an upload breaks or when no data arrives for 30 seconds. Paused transfers survive app restarts and are kept for 24 hours from when they were accepted, then deleted.
- A transfer paused because the disk was full answers a re-offer with `507 no_space` until there is room for the remaining bytes.
- If the sender gets `offset_mismatch`, it should restart from the `received` value in the error.

## Integrity

- Each file is checked with SHA-256 over its full content, sent in `done`. The receiver hashes while writing and re-hashes the partial from disk after a restart. A mismatch deletes the partial; the sender may upload again from 0 (the app retries once).
- Files are written to a temporary location and moved to the final name only after the hash matches, so a partial file never appears as a finished one.
- Text items travel inside the offer and rely on TLS for integrity.

## Limits and timeouts

| Item | Value |
|---|---|
| Items per offer | 1 to 10,000 |
| Text item | 1 to 100,000 characters |
| File size | 0 to 2^50 bytes |
| JSON body (request or response) | 4 MiB |
| Item path | 4096 characters, 64 segments; each saved segment cut to 200 UTF-8 bytes |
| Device name | Cut to 64 characters after removing control characters (256 accepted on the wire) |
| Transfer id / item id | `^[A-Za-z0-9-]{8,64}$` / `^[A-Za-z0-9_-]{1,32}$` |
| Nonce | 64 characters |
| Clock skew for `X-KF-Auth` | ±5 minutes |
| Offer answer timeout | 60 seconds |
| New offers per sender | 1 per 5 seconds |
| Pairing secret lifetime | 10 minutes, one use |
| Paused transfer lifetime | 24 hours |
| Receiver idle pause | 30 seconds without data |
| Server keep-alive idle timeout | 30 seconds |

## Versioning

- The version appears in four places: the path prefix `/v1/`, `v` in `/v1/info`, TXT `v`, and `v` in the QR link. In this version all are `1`.
- A client must not talk to a device whose `/v1/info` returns another `v`, whose TXT `v` differs, or whose QR code has another `v`; the app shows these as needing an update.
- Within v1, changes are additive only: new optional JSON fields (which v1 parsers ignore), new endpoints, new error codes (which old clients read as `protocol`). Anything that changes the meaning of existing fields, the signed bytes or the endpoints needs a new version, served under a new path prefix such as `/v2/`.
- The signed-bytes prefix `kfv1` and the SAS prefix `kickfile-sas-v1` change with any new version of those schemes.

## Security properties and non-goals

What v1 protects against, on a shared LAN:

- **Eavesdropping**: everything travels over TLS.
- **Impersonating a known device**: a device is its key. The client pins the receiver's certificate, and the receiver checks a signature from the sender's key on every request. A device with a different key is a different device, and the app warns when a trusted name and platform show up with a new key.
- **Replay**: signatures cover method, path, query, receiver and time, and nonces are remembered for the 5-minute window.
- **Tampering**: TLS, plus a per-file SHA-256 checked before a file is saved.
- **Unwanted files**: nothing is written without the receiver's accept (or the user's earlier choice to auto-accept that device). Users can decline and block devices; offers are rate-limited per device; Hidden devices don't announce and answer `/v1/info` only to trusted devices or a valid pairing secret.
- **Path tricks**: absolute paths, `..`, drive letters and reserved names are rejected or neutralised, so files land only inside the save folder.
- **Man in the middle on first contact**: QR pairing carries the fingerprint, so it is authenticated. Without QR, first contact is trust on first use; comparing the 6-digit code detects an interposed device.

Non-goals and known limits:

- **Privacy on the network**: a Visible device announces its name, platform and fingerprint to everyone on the LAN, and `/v1/info` answers anyone.
- **Strong first-contact verification**: the code has 6 digits (about 20 bits). It stops casual mistakes and unprepared attackers, but an active attacker who can generate many keys can search for a matching code. Use QR pairing when that matters.
- **Short-code pairing**: the secret proves the scanner to the showing device, but the scanner learns the showing device's fingerprint from the network, so an on-path attacker on the LAN can answer in its place. QR pairing doesn't have this weakness.
- **Brute force of the pairing secret**: the secret has 6 digits and lives for 10 minutes. After 10 wrong tries (on `/v1/pair` or `/v1/info?s=`) it stops working until the user opens Show QR again, so a guess succeeds with a chance of about 1 in 90,000.
- **Denial of service**: anyone on the network can keep a device busy, and per-device limits and blocks are tied to a key that an attacker can replace at will.
- **Compromised devices**: a device whose `identity.json` is copied can be impersonated until the other side forgets it. There is no revocation or certificate expiry check.
- **Data at rest**: received files are saved as plain files; nothing is encrypted on disk.
- **Internet use**: the protocol is for one local network or hotspot. There is no relay, NAT traversal or IPv6 support.
- **Clocks**: devices must agree on the time within 5 minutes, or signed requests fail with `401`.
