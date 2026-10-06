# Tether — User Guide

Your own private remote-desktop app for Mac and Windows. Light, end-to-end encrypted, and removable with one click.

---

## 1. Install on the Mac (once)

```bash
cd ~/Developer/Tether/mac
./build.sh --install
```

- Needs only the Xcode Command Line Tools (`xcode-select --install` if missing).
- If you see `permission denied`, run `bash build.sh --install` instead.
- The app is copied to Applications and opens automatically.
- **Controlling a Windows PC needs no permissions on the Mac.**
- Screen Recording and Accessibility are only needed if someone should control *this* Mac; Tether shows you where to allow them.

## 2. Run on Windows

1. Copy `Tether-Windows-x64.exe` anywhere on the PC (e.g. Documents). There is no installer.
2. Double-click it.
   - "Windows protected your PC" → **More info** → **Run anyway** (shown because the app isn't signed with a paid certificate).
   - Firewall prompt → tick **Private networks** → **Allow** (needed for direct connections on your home network).
3. On very old Windows 10 PCs without a window, install the Microsoft **WebView2 Runtime** (built into Windows 11).

## 3. First connection — same Wi-Fi (no setup)

1. On Windows, the **This computer** card shows e.g. `Local network ready (192.168.1.25)`.
2. On the Mac, type `192.168.1.25` in **Partner ID or IP address**.
3. Enter the **one-time password** shown on Windows → **Connect**.

## 4. Connect over the internet from anywhere (one-time, ~5 minutes)

Tether uses a tiny private relay to introduce the two computers. It runs **free** on Cloudflare, and it **cannot see your screen or password** — everything is encrypted between the two computers.

1. Push the `Tether` folder to a new GitHub repository named `tether` (account `ahmedalbazzaz1987`).
2. Create a free account at [dash.cloudflare.com](https://dash.cloudflare.com).
3. **Workers & Pages** → **Create** → **Import a repository** → connect GitHub → choose `tether`.
4. Set **Project name** to `tether-relay` and **Root directory** (under build settings) to `relay` → **Deploy**.
5. You get an address like `tether-relay.<you>.workers.dev`.
6. Open **Settings** (gear icon) on **both** computers and paste it into **Relay address**.

The status line now shows 🟢 **Ready for connections**. Connect with the 9-digit **ID** instead of an IP.
On the same network Tether connects **directly** automatically (green **Direct** badge), otherwise through the relay (**Relay**).

> Alternative: add a GitHub secret `CLOUDFLARE_API_TOKEN` and run the **Deploy relay** workflow from the Actions tab.

## 5. Unattended access to the Windows PC

On Windows → **Settings**:
- **Unattended access**: enter a permanent password (8+ characters) → **Save**.
- Turn on **Start Tether when I sign in**.

You can then reach it any time with its ID and the permanent password (while it's on and signed in).

## 6. During a session

| Feature | How |
|---|---|
| Full screen | ⛶ button (F11 on Windows) |
| Quality | Fast / Balanced / Best quality |
| Multiple monitors | Display picker in the toolbar |
| Special keys | **Keys** menu (Alt+Tab, Win, Task Manager, Lock…) |
| ⌘ on Mac = Ctrl on Windows | On by default (toggle in the Keys menu) |
| Copy & paste between computers | Automatic for text |
| Send files | **Chat & files** → **Files** → **Send files…** (or drag & drop on the Mac) — saved to `Downloads/Tether` |
| Chat | **Chat & files** → **Chat** |

The controlled computer always shows a red banner — **"… is controlling this computer"** — with a **Disconnect** button.

## 7. Security in brief

- End-to-end encryption (X25519 + AES-256-GCM); the relay only forwards ciphertext.
- The password never travels over the network (cryptographic proof only).
- The one-time password changes after every session.
- 5 wrong passwords lock the computer for 5 minutes.
- Each computer has an identity fingerprint; Tether warns you if it ever changes.
- No system service, no admin rights, no changes to your security settings.

## 8. Updates

Tether checks GitHub Releases of `ahmedalbazzaz1987/tether` and offers **Update now**.
To publish: push a tag like `v1.0.1`; GitHub builds the files. If the Mac build fails there, run `./build.sh --release` on the Mac and upload `build/Tether-macOS.zip` by hand.

## 9. Complete removal

**Settings** → **Uninstall Tether…**
- **Mac**: removes settings, login item and permissions, and moves the app to the Trash.
- **Windows**: removes settings, the sign-in entry, WebView2 data and firewall rules (Windows may ask once), then deletes the exe itself.

Files you received stay in Downloads.

## 10. Known limits

- The Windows lock screen and UAC (admin) prompts aren't visible remotely — that would require a system service, avoided on purpose.
- Apps running as administrator on Windows ignore remote input unless Tether itself runs as administrator.
- No Ctrl+Alt+Del (a Windows restriction) and no audio.
- On the Mac, system shortcuts like ⌘Tab stay local; use the **Keys** menu to send them.
