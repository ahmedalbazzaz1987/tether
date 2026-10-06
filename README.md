# Tether

A small, private remote-desktop app for macOS and Windows — control one computer from another over your local network or the internet.

| | macOS | Windows |
|---|---|---|
| App | `Tether.app` (~2–3 MB, Swift) | `Tether-Windows-x64.exe` (~8 MB, portable, no installer) |
| Control other computers | ✓ | ✓ |
| Be controlled | ✓ (needs Screen Recording + Accessibility) | ✓ |

**Features:** ID + one-time password (changes after every session), permanent password for unattended access, end-to-end encryption, automatic direct LAN connection, clipboard text sync, file transfer both ways (drag & drop on Mac), chat, multi-monitor, quality presets, full screen, special-key menu, ⌘→Ctrl mapping, updates from GitHub Releases, one-click uninstall that leaves nothing behind.

## Layout

```
mac/        Swift sources + build.sh (Command Line Tools only)
windows/    Go sources (core/ is shared logic, win/ is Windows-only, core/app/web is the UI)
relay/      Cloudflare Worker + Durable Object (free plan) that pairs computers by ID
PROTOCOL.md Wire protocol both apps implement
```

## Build

* **macOS:** `cd mac && ./build.sh --install` (`--release` makes a universal `build/Tether-macOS.zip`).
* **Windows:** `cd windows && GOOS=windows GOARCH=amd64 go build -trimpath -ldflags="-s -w -H windowsgui" -o Tether.exe ./cmd/tether`
  (the module uses `replace` directives pointing golang.org/x/* at their GitHub mirrors; set `GOPROXY=direct GOSUMDB=off` if proxy.golang.org is unreachable).
* **Relay:** `cd relay && npx wrangler deploy`, or import the repo in the Cloudflare dashboard (project name `tether-relay`, root directory `relay`), or run the *Deploy relay* workflow.

## Security model

* Handshake: ephemeral X25519, host identity Ed25519 (pinned by viewers on first use), password proven with PBKDF2-SHA256 (150k) + HKDF/HMAC — the password never crosses the network.
* Records: AES-256-GCM with per-direction counters. The relay only sees ciphertext.
* The host never reveals anything password-derived first, and locks for 5 minutes after 5 wrong passwords.
* The relay binds each ID to a secret held by that computer, so nobody else can register the same ID.

## Releasing an update

1. Bump `session.AppVersion` (windows/core/session/common.go), `mac/VERSION` and the versions in `windows/winres/winres.json` (then regenerate the `.syso` files: `go-winres make --in winres/winres.json --arch amd64,arm64 --out cmd/tether/rsrc`).
2. Run `./mac/build.sh --release` on the Mac and copy `mac/build/Tether-macOS.zip` to `prebuilt/`, update `RELEASE_NOTES.md`, then commit and push to `main`. The *Release* workflow builds Windows (and macOS when the runner can) and publishes tag `v<VERSION>` automatically.
3. Asset names the apps look for: `Tether-macOS.zip`, `Tether-Windows-x64.exe`, `Tether-Windows-arm64.exe`.
