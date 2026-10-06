import Foundation
import AppKit
import ServiceManagement
import UserNotifications

let githubRepo = "ahmedalbazzaz1987/tether"
let macAssetName = "Tether-macOS.zip"

struct UpdateInfo: Equatable {
    var version: String
    var notes: String
    var assetURL: URL
}

func isNewer(_ a: String, than b: String) -> Bool {
    func parts(_ v: String) -> [Int] {
        let p = v.trimmingCharacters(in: CharacterSet(charactersIn: "vV ")).split(separator: ".").map { Int($0.filter(\.isNumber)) ?? 0 }
        return (p + [0, 0, 0]).prefix(3).map { $0 }
    }
    let x = parts(a), y = parts(b)
    for i in 0..<3 where x[i] != y[i] { return x[i] > y[i] }
    return false
}

enum Notifier {
    static func setup() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    static func post(title: String, body: String) {
        let c = UNMutableNotificationContent()
        c.title = title
        c.body = body
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil))
    }
}

extension AppState {
    // MARK: - Updates (GitHub Releases)

    func checkUpdate(manual: Bool) {
        if manual { updateMessage = "Checking…" }
        var req = URLRequest(url: URL(string: "https://api.github.com/repos/\(githubRepo)/releases/latest")!)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("Tether/\(appVersion)", forHTTPHeaderField: "User-Agent")
        relaySession.dataTask(with: req) { data, resp, err in
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            var info: UpdateInfo?
            var msg = ""
            if err != nil { msg = "Update check failed: no connection" }
            else if code == 404 { msg = "No releases published yet" }
            else if code != 200 { msg = "Update check failed (\(code))" }
            else if let d = data, let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
                let tag = (j["tag_name"] as? String ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "v"))
                let assets = j["assets"] as? [[String: Any]] ?? []
                let asset = assets.first(where: { ($0["name"] as? String) == macAssetName })
                let url = asset?["browser_download_url"] as? String
                if isNewer(tag, than: appVersion), let u = url.flatMap(URL.init(string:)) {
                    info = UpdateInfo(version: tag, notes: j["body"] as? String ?? "", assetURL: u)
                    msg = "Version \(tag) is available"
                } else {
                    msg = "Tether is up to date"
                }
            }
            DispatchQueue.main.async {
                self.update = info
                self.updateMessage = (manual || info != nil) ? msg : ""
            }
        }.resume()
    }

    /// Downloads the new app, swaps the bundle in place and relaunches.
    func applyUpdate() {
        guard let u = update, !updating else { return }
        updating = true
        updateMessage = "Downloading \(u.version)…"
        relaySession.downloadTask(with: u.assetURL) { tmp, resp, err in
            func fail(_ m: String) { DispatchQueue.main.async { self.updating = false; self.updateMessage = "Update failed: \(m)" } }
            guard let tmp = tmp, err == nil, (resp as? HTTPURLResponse)?.statusCode == 200 else { return fail("download error") }
            let fm = FileManager.default
            let work = fm.temporaryDirectory.appendingPathComponent("tether-update-\(UUID().uuidString)")
            do {
                try fm.createDirectory(at: work, withIntermediateDirectories: true)
                let zip = work.appendingPathComponent("u.zip")
                try fm.moveItem(at: tmp, to: zip)
                let unzip = Process()
                unzip.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
                unzip.arguments = ["-x", "-k", zip.path, work.path]
                try unzip.run(); unzip.waitUntilExit()
                let newApp = work.appendingPathComponent("Tether.app")
                guard unzip.terminationStatus == 0, fm.fileExists(atPath: newApp.appendingPathComponent("Contents/MacOS/Tether").path) else {
                    return fail("the download did not contain Tether.app")
                }
                let current = Bundle.main.bundleURL
                // Replace after we quit, then relaunch. Also clears the quarantine flag of the download.
                let script = """
                sleep 1
                while /bin/kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do sleep 0.3; done
                /bin/rm -rf "\(current.path)"
                /bin/mv "\(newApp.path)" "\(current.path)"
                /usr/bin/xattr -dr com.apple.quarantine "\(current.path)" 2>/dev/null
                /bin/rm -rf "\(work.path)"
                /usr/bin/open "\(current.path)"
                """
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/bin/sh")
                p.arguments = ["-c", script]
                try p.run()
                DispatchQueue.main.async { self.quit() }
            } catch {
                fail(error.localizedDescription)
            }
        }.resume()
    }

    // MARK: - Uninstall

    /// Removes every file Tether created, its login item and permissions, then moves the app to the Trash.
    func uninstall() {
        viewerSession?.disconnect()
        endHostSession()
        try? SMAppService.mainApp.unregister()
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        let bid = Bundle.main.bundleIdentifier ?? "com.novamira.tether"
        let paths = [
            ConfigStore.dir.path,
            home.appendingPathComponent("Library/Caches/\(bid)").path,
            home.appendingPathComponent("Library/HTTPStorages/\(bid)").path,
            home.appendingPathComponent("Library/HTTPStorages/\(bid).binarycookies").path,
            home.appendingPathComponent("Library/Saved Application State/\(bid).savedState").path,
            home.appendingPathComponent("Library/WebKit/\(bid)").path,
            home.appendingPathComponent("Library/Preferences/\(bid).plist").path,
        ]
        for p in paths { try? fm.removeItem(atPath: p) }
        UserDefaults.standard.removePersistentDomain(forName: bid)
        let app = Bundle.main.bundleURL.path
        // A running app can be moved to the Trash; it keeps working until it quits.
        try? fm.trashItem(at: Bundle.main.bundleURL, resultingItemURL: nil)
        let script = """
        /usr/bin/tccutil reset ScreenCapture \(bid) >/dev/null 2>&1
        /usr/bin/tccutil reset Accessibility \(bid) >/dev/null 2>&1
        /usr/bin/tccutil reset All \(bid) >/dev/null 2>&1
        sleep 1
        while /bin/kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do sleep 0.3; done
        /usr/bin/defaults delete \(bid) >/dev/null 2>&1
        /bin/rm -f "$HOME/Library/Preferences/\(bid).plist"
        [ -d "\(app)" ] && /bin/rm -rf "\(app)"
        """
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", script]
        try? p.run()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { NSApp.terminate(nil) }
    }
}
