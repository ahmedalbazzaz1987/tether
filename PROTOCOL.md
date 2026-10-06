# Tether wire protocol (v1)

Both apps (macOS / Swift and Windows / Go) implement this document byte-for-byte.
All integers are big-endian.

## 1. Transports

A *packet* is an opaque byte string. Two transports carry packets:

* **Direct TCP** (LAN, default port 47800): each packet is `u32 length | bytes`. Max 16 MiB.
* **Relay WebSocket** (internet): one binary WebSocket message = one packet.
  Text messages are only used for relay signalling (section 5).

## 2. Handshake (plaintext packets)

```
V→H  P1 = "TTH1" | ver u8 (=1) | viewerEph[32] | nameLen u8 | name
H→V  P2 = "TTS1" | ver u8 | hostEph[32] | hostPub[32] | salt[16] | iters u32 |
          os u8 (1=mac,2=windows) | nameLen u8 | name | sig[64]
V→H  P3 = "TTP1" | proofV[32]
H→V  P4 = "TTOK" | proofH[32]        (success)
          "TTNO" | reason u8          (1 = wrong password, 2 = locked out, 3 = busy)
```

* `viewerEph`, `hostEph` – ephemeral X25519 public keys.
* `hostPub` – host's long-term Ed25519 key. Viewers pin it per host ID (trust on first use)
  and refuse to continue if it changes.
* `th  = SHA256("tether-v1" | P1 | P2 without sig)`; `sig = Ed25519(hostKey, th)`.
  The viewer verifies `sig` **before** sending anything that depends on the password.
* `shared = X25519(eph)`; `kpw = PBKDF2-HMAC-SHA256(password, salt, iters, 32)`.
* `ikm = shared | kpw`, and with `HKDF-SHA256(ikm, salt = th, info, 32)`:
  * `proofV = HMAC-SHA256(HKDF(.., "tether proof v"), "viewer")`
  * `proofH = HMAC-SHA256(HKDF(.., "tether proof h"), "host")`
  * `kV2H = HKDF(.., "tether key v2h")`, `kH2V = HKDF(.., "tether key h2v")`
* The host checks `proofV` against every accepted password (one-time and permanent).
  5 failures within 5 minutes lock the host for 5 minutes.
* Passwords are UTF-8 with all whitespace removed.

## 3. Encrypted records

Every packet after P4 is `AES-256-GCM(key, nonce, plaintext)` = `ciphertext | tag[16]`.
`nonce = 00 00 00 00 | u64 counter`, one counter per direction starting at 0.
Plaintext = `type u8 | payload`.

| type | name  | payload |
|------|-------|---------|
| 0x01 | JSON  | UTF-8 JSON object with a `"t"` field |
| 0x02 | Video | `seq u32 | width u16 | height u16 | count u16 | rect*` ; rect = `x u16 y u16 w u16 h u16 fmt u8 (1=JPEG) len u32 data` |
| 0x03 | Mouse | `kind u8 (0 move,1 down,2 up,3 wheel) | button u8 (0 L,1 R,2 M) | x u16 | y u16 | dx i16 | dy i16` – x/y normalised 0..65535 over the shared display; wheel in 1/120-notch units |
| 0x04 | Key   | `down u8 | hid u16` – USB HID keyboard usage (page 7) |
| 0x05 | Ack   | `seq u32` – viewer finished drawing that frame |
| 0x06 | File  | `id u32 | bytes` |
| 0x7F | Frag  | `origType u8 | last u8 | bytes` – messages over 512 KiB are split; fragments of one message are contiguous |

The host keeps at most 2 video frames un-acknowledged.

## 4. JSON messages

| t | direction | fields |
|---|-----------|--------|
| hello | both | `os, name, version`; host adds `displays:[{id,name,w,h}]`, `display` |
| display | V→H | `id` |
| refresh | V→H | – (send a full frame) |
| quality | V→H | `q: "fast" \| "balanced" \| "best"` |
| clip | both | `text` |
| chat | both | `text` |
| file.offer | both | `id, name, size` |
| file.ack | both | `id, bytes` (receiver progress; sender keeps ≤ 4 MiB un-acked) |
| file.end | both | `id` |
| file.cancel | both | `id` |
| ping / pong | both | `ts` |
| bye | both | – |

## 5. Relay (Cloudflare Worker + Durable Object, one object per host ID)

* Host control socket: `wss://RELAY/host?id=ID&secret=HEX&lan=ip:port,ip:port`
  – the first registration stores `SHA256(secret)`; later ones must match.
  Relay → host text: `{"t":"incoming","sid":"…"}`.
* Viewer: `wss://RELAY/connect?id=ID`
  – relay → viewer text `{"t":"info","lan":[…]}` (`lan` only when both share a public IP) or
  `{"t":"error","reason":"offline"}`.
  – viewer → relay text `{"t":"relay"}` asks the host to join (viewer may first try LAN directly).
  – relay → viewer text `{"t":"ready"}` once the host joined; binary messages are then piped.
* Host data socket: `wss://RELAY/accept?id=ID&secret=HEX&sid=SID`.

## 6. LAN discovery (no relay needed on the same network)

* Viewer broadcasts UDP `TETHER-FIND <id>` to port 47800 (255.255.255.255 and each interface's directed broadcast), up to 3 times within ~0.9 s.
* The host whose ID matches (and that allows direct LAN connections) replies `TETHER-HERE <id> <tcpPort>` to the sender.
* The viewer then connects directly over TCP. Only if nothing answers does it fall back to the relay.
