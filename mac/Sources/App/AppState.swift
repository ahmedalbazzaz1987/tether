import Foundation
import AppKit
import Network
import ServiceManagement
import Combine

struct ChatLine: Identifiable, Equatable {
    let id = UUID()
    var remote: Bool
    var text: String
}

struct ViewState: Equatable {
    var state = "idle" // idle, connecting, connected
    var target = ""
    var error = ""
    var keyChanged = false
    var remoteName = ""
    var remoteOS = ""
    var displays: [DisplayInfo] = []
    var display = 0
    var kind = ""
    var fingerprint = ""
}

struct HostState: Equatable {
    var viewer: String
    var kind: String
}

/// Central controller: identity, host service (relay + LAN), sessions and UI state.
final class AppState: ObservableObject {
    static let shared = AppState()

    let store = ConfigStore()
    @Published var config: Config
    @Published var otp = "········"
    @Published var relayOnline = false
    @Published var relayStatus = "Starting…"
    @Published var lanActive = false
    @Published var host: HostState?
    @Published var view = ViewState()
    @Published var chat: [ChatLine] = []
    @Published var files: [FileProgress] = []
    @Published var ping = 0
    @Published var update: UpdateInfo?
    @Published var updateMessage = ""
    @Published var updating = false
    @Published var screenPermission = ScreenPermission.granted
    @Published var accessibilityPermission = Injector.trusted
    @Published var toast = ""

    private let otpLock = NSLock()
    private var otpKPWStorage = Data()
    private var otpKPW: Data {
        get { otpLock.lock(); defer { otpLock.unlock() }; return otpKPWStorage }
        set { otpLock.lock(); otpKPWStorage = newValue; otpLock.unlock() }
    }
    private let limiter = Limiter()
    private var relayHost: RelayHost?
    private var listener: NWListener?
    private let discovery = DiscoveryResponder()
    private var hostSession: HostSession?
    private(set) var viewerSession: ViewerSession?
    private var dialTask: Task<Void, Never>?
    let machineName = Host.current().localizedName ?? "Mac"

    var onViewerStart: (ViewerSession) -> Void = { _ in }
    var onViewerEnd: () -> Void = {}
    var onHostStart: () -> Void = {}

    static let downloads: URL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Tether", isDirectory: true)

    private init() {
        config = store.current()
        newOTP()
    }

    private func ui(_ f: @escaping () -> Void) {
        if Thread.isMainThread { f() } else { DispatchQueue.main.async(execute: f) }
    }

    func showToast(_ t: String) {
        ui {
            self.toast = t
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { if self.toast == t { self.toast = "" } }
        }
    }

    func start() {
        restartHost()
        refreshPermissions()
        if config.autoUpdate {
            DispatchQueue.main.asyncAfter(deadline: .now() + 8) { self.checkUpdate(manual: false) }
        }
    }

    func refreshPermissions() {
        ui {
            self.screenPermission = ScreenPermission.granted
            self.accessibilityPermission = Injector.trusted
        }
    }

    func newOTP() {
        let p = oneTimePassword()
        let salt = store.saltData
        DispatchQueue.global(qos: .userInitiated).async {
            let k = Proto.deriveKPW(p, salt: salt, iters: Proto.kdfIters)
            DispatchQueue.main.async {
                self.otp = p
                self.otpKPW = k
            }
        }
    }

    private func candidates() -> [Data] {
        var out: [Data] = [otpKPW]
        if let p = store.permKPW { out.append(p) }
        return out.filter { !$0.isEmpty }
    }

    func updateConfig(_ f: (inout Config) -> Void) {
        store.update(f)
        let c = store.current()
        ui { self.config = c }
    }

    // MARK: - Host service

    func lanAddrs() -> [String] {
        guard let port = listener?.port?.rawValue else { return [] }
        return localIPv4().map { "\($0):\(port)" }
    }

    func restartHost() {
        relayHost?.stop(); relayHost = nil
        listener?.cancel(); listener = nil
        discovery.stop()
        let c = store.current()
        ui { self.lanActive = false }
        if c.acceptIncoming && c.allowLan { startListener(port: UInt16(c.lanPort), fallback: true) }
        if c.acceptIncoming && !c.relayUrl.trimmingCharacters(in: .whitespaces).isEmpty {
            let h = RelayHost(relay: c.relayUrl, id: c.id, secret: c.secret, lan: { [weak self] in self?.lanAddrs() ?? [] },
                              onIncoming: { [weak self] t in self?.handleIncoming(t) },
                              onStatus: { [weak self] on, msg in self?.ui { self?.relayOnline = on; self?.relayStatus = msg } })
            relayHost = h
            ui { self.relayOnline = false; self.relayStatus = "Connecting to relay…" }
            // give the LAN listener a moment so its port is advertised
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { h.start() }
        } else {
            ui {
                self.relayOnline = false
                self.relayStatus = c.acceptIncoming ? "No relay set – only local network connections" : "Incoming connections are turned off"
            }
        }
    }

    private func startListener(port: UInt16, fallback: Bool) {
        let params = TCPTransport.parameters()
        params.allowLocalEndpointReuse = true
        let l: NWListener
        do {
            if let p = NWEndpoint.Port(rawValue: port) { l = try NWListener(using: params, on: p) }
            else { l = try NWListener(using: params) }
        } catch {
            if fallback { startListener(port: 0, fallback: false) }
            return
        }
        l.newConnectionHandler = { [weak self] conn in
            let t = TCPTransport(conn)
            Task {
                do { try await t.start(timeout: 10) } catch { return }
                self?.handleIncoming(t)
            }
        }
        l.stateUpdateHandler = { [weak self] st in
            switch st {
            case .ready:
                self?.ui { self?.lanActive = true }
                if let me = self {
                    me.discovery.start(id: me.store.current().id, tcpPort: { [weak l] in l?.port?.rawValue })
                }
            case .failed:
                l.cancel()
                self?.ui { self?.lanActive = false }
                if fallback, port != 0 { self?.startListener(port: 0, fallback: false) }
            default: break
            }
        }
        l.start(queue: .global(qos: .userInitiated))
        listener = l
    }

    func handleIncoming(_ t: Transport) {
        guard store.current().acceptIncoming else { t.close(); return }
        let params = HostParams(key: store.hostKey, name: machineName, os: Proto.osMac, salt: store.saltData,
                                iters: Proto.kdfIters, candidates: { [weak self] in self?.candidates() ?? [] },
                                limiter: limiter, busy: { [weak self] in self?.hostSession != nil })
        Task.detached { [weak self] in
            guard let self = self else { return }
            let timeout = Task { try? await Task.sleep(nanoseconds: 25_000_000_000); if !Task.isCancelled { t.close() } }
            let result: (SecureChannel, String)
            do { result = try await serverHandshake(t, params) } catch {
                timeout.cancel()
                t.close()
                return
            }
            timeout.cancel()
            let (ch, vname) = result
            let s = HostSession(ch: ch, viewerName: vname, events: self.sessionEvents(), downloads: AppState.downloads)
            s.clipboardOn = self.store.current().clipboardSync
            self.hostSession = s
            self.ui {
                self.host = HostState(viewer: vname, kind: s.kind)
                self.chat = []
                self.files = []
                self.onHostStart()
            }
            Notifier.post(title: "Tether", body: "\(vname) is now controlling this Mac")
            await s.run()
            if self.hostSession === s { self.hostSession = nil }
            self.newOTP() // one-time password rotates after every session
            self.ui { self.host = nil }
            Notifier.post(title: "Tether", body: "Remote session ended")
        }
    }

    private func sessionEvents() -> SessionEvents {
        SessionEvents(
            onChat: { [weak self] remote, text in
                self?.ui {
                    self?.chat.append(ChatLine(remote: remote, text: text))
                    if remote { NSApp.requestUserAttention(.informationalRequest) }
                }
            },
            onFile: { [weak self] p in
                self?.ui {
                    guard let self = self else { return }
                    if let i = self.files.firstIndex(where: { $0.id == p.id }) { self.files[i] = p } else { self.files.append(p) }
                    if self.files.count > 30 { self.files.removeFirst(self.files.count - 30) }
                }
                if p.incoming && p.state == "done" { Notifier.post(title: "File received", body: p.name) }
            },
            onEnded: { _ in },
            onPing: { [weak self] ms in self?.ui { self?.ping = ms } }
        )
    }

    func endHostSession() { hostSession?.disconnect() }
    private var activeSession: SessionCore? {
        if let v = viewerSession { return v }
        return hostSession
    }

    func sendChat(_ text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        activeSession?.chat(t)
    }

    // MARK: - Viewer

    func connect(target raw: String, password: String) {
        let target: String = Dialer.isID(raw) ?? raw.trimmingCharacters(in: .whitespaces)
        guard !target.isEmpty, view.state == "idle" else { return }
        let c = store.current()
        if target == c.id { view = ViewState(target: target, error: "That is this computer's own ID"); return }
        view = ViewState(state: "connecting", target: target)
        chat = []
        files = []
        dialTask = Task.detached { [weak self] in
            guard let self = self else { return }
            do {
                let t = try await Dialer.dial(target, relay: c.relayUrl)
                if Task.isCancelled { t.close(); return }
                var newPin = ""
                let known = self.store.current().knownHosts[target]
                let (ch, info) = try await clientHandshake(t, viewerName: self.machineName, password: password) { info in
                    let pub = info.hostPub.hex
                    if let k = known, !k.isEmpty, k != pub { throw TetherError.identityChanged }
                    newPin = pub
                }
                if Task.isCancelled { ch.close(); return }
                self.updateConfig { cfg in
                    cfg.knownHosts[target] = newPin
                    let rec = RecentEntry(target: target, name: info.name, os: info.os == Proto.osMac ? "mac" : "windows", when: Date())
                    cfg.recent = [rec] + cfg.recent.filter { $0.target != target }.prefix(11)
                }
                let s = ViewerSession(ch: ch, remote: info, events: self.sessionEvents(), downloads: AppState.downloads)
                s.clipboardOn = c.clipboardSync
                s.onHello = { [weak self] m in
                    self?.ui {
                        self?.view.remoteOS = m.os ?? ""
                        self?.view.displays = m.displays ?? []
                        self?.view.display = m.display ?? 0
                        if let n = m.name, !n.isEmpty { self?.view.remoteName = n }
                    }
                }
                self.viewerSession = s
                await MainActor.run {
                    self.view.state = "connected"
                    self.view.remoteName = info.name
                    self.view.remoteOS = info.os == Proto.osMac ? "mac" : "windows"
                    self.view.kind = s.kind
                    self.view.fingerprint = fingerprint(info.hostPub)
                    self.onViewerStart(s)
                }
                if c.quality != "balanced" { s.setQuality(c.quality) }
                await s.run()
                await MainActor.run {
                    if self.viewerSession === s { self.viewerSession = nil }
                    self.view = ViewState(target: target)
                    self.onViewerEnd()
                }
            } catch TetherError.identityChanged {
                self.ui {
                    self.view = ViewState(target: target, error: "This computer's identity key has changed since your last connection. If you did not reinstall Tether on it, someone may be intercepting the connection.", keyChanged: true)
                }
            } catch {
                if Task.isCancelled { return }
                self.ui { self.view = ViewState(target: target, error: error.localizedDescription) }
            }
        }
    }

    func cancelConnect() {
        dialTask?.cancel()
        if view.state == "connecting" { view = ViewState(target: view.target) }
    }

    func disconnectViewer() { viewerSession?.disconnect() }

    func forgetHost(_ target: String) {
        updateConfig { $0.knownHosts[target] = nil }
        view.keyChanged = false
        view.error = ""
    }

    func removeRecent(_ target: String) { updateConfig { $0.recent.removeAll { $0.target == target } } }

    func sendFiles() {
        guard let s = activeSession else { return }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.message = "Choose files to send"
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK { for u in panel.urls { s.sendFile(u) } }
    }

    func sendFiles(_ urls: [URL]) {
        guard let s = activeSession else { return }
        for u in urls { s.sendFile(u) }
    }

    func openDownloads() {
        try? FileManager.default.createDirectory(at: Self.downloads, withIntermediateDirectories: true)
        NSWorkspace.shared.open(Self.downloads)
    }

    // MARK: - Settings

    func setPermanentPassword(_ p: String) {
        let n = Proto.normalizePassword(p)
        guard n.count >= 8 else { showToast("Use at least 8 characters"); return }
        let salt = store.saltData
        DispatchQueue.global(qos: .userInitiated).async {
            let k = Proto.deriveKPW(n, salt: salt, iters: Proto.kdfIters)
            self.updateConfig { $0.permKpw = k.base64EncodedString() }
            self.showToast("Unattended password saved")
        }
    }

    func clearPermanentPassword() { updateConfig { $0.permKpw = nil } }

    func setRelay(_ url: String) {
        let u = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard u != store.current().relayUrl else { return }
        updateConfig { $0.relayUrl = u }
        restartHost()
    }

    func setAcceptIncoming(_ on: Bool) { updateConfig { $0.acceptIncoming = on }; restartHost() }
    func setAllowLan(_ on: Bool) { updateConfig { $0.allowLan = on }; restartHost() }

    func setClipboard(_ on: Bool) {
        updateConfig { $0.clipboardSync = on }
        viewerSession?.clipboardOn = on
        hostSession?.clipboardOn = on
    }

    func setQuality(_ q: String) {
        updateConfig { $0.quality = q }
        viewerSession?.setQuality(q)
    }

    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            updateConfig { $0.launchAtLogin = on }
        } catch {
            showToast("Could not change login item: \(error.localizedDescription)")
            updateConfig { $0.launchAtLogin = SMAppService.mainApp.status == .enabled }
        }
    }

    func quit() {
        viewerSession?.disconnect()
        hostSession?.disconnect()
        relayHost?.stop()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { NSApp.terminate(nil) }
    }
}
