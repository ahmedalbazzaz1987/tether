import AppKit
import SwiftUI
import Combine

/// Toolbar shown above the remote screen.
struct ViewerToolbar: View {
    @ObservedObject var app = AppState.shared
    var onKeys: ([UInt16]) -> Void
    var onToggleChat: () -> Void
    var onFullScreen: () -> Void
    @Binding var chatOpen: Bool
    var unread: Int

    var body: some View {
        HStack(spacing: 10) {
            Text(app.view.kind == "direct" ? "Direct" : "Relay")
                .font(.system(size: 11, weight: .semibold))
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(Capsule().fill((app.view.kind == "direct" ? Color.green : Color.tetherAccent).opacity(0.18)))
                .foregroundColor(app.view.kind == "direct" ? .green : .tetherAccent)
            Text(app.view.remoteName).fontWeight(.semibold).lineLimit(1)
            if app.ping > 0 { Text("\(app.ping) ms").font(.caption).foregroundColor(.secondary) }
            Spacer()
            if app.view.displays.count > 1 {
                Picker("", selection: Binding(get: { app.view.display }, set: { d in
                    app.view.display = d
                    app.viewerSession?.selectDisplay(d)
                })) {
                    ForEach(app.view.displays) { d in Text("\(d.name) (\(d.w)×\(d.h))").tag(d.id) }
                }
                .labelsHidden().frame(width: 190)
            }
            Picker("", selection: Binding(get: { app.config.quality }, set: { app.setQuality($0) })) {
                Text("Fast").tag("fast")
                Text("Balanced").tag("balanced")
                Text("Best quality").tag("best")
            }
            .labelsHidden().frame(width: 120)
            Menu("Keys") {
                if app.view.remoteOS == "mac" {
                    Button("⌘ + Tab") { onKeys([0xE3, 0x2B]) }
                    Button("⌘ + Space") { onKeys([0xE3, 0x2C]) }
                    Button("Force Quit (⌥⌘⎋)") { onKeys([0xE2, 0xE3, 0x29]) }
                    Button("Lock screen (⌃⌘Q)") { onKeys([0xE0, 0xE3, 0x14]) }
                } else {
                    Button("Alt + Tab") { onKeys([0xE2, 0x2B]) }
                    Button("Alt + F4") { onKeys([0xE2, 0x3D]) }
                    Button("Windows key") { onKeys([0xE3]) }
                    Button("Ctrl + Shift + Esc (Task Manager)") { onKeys([0xE0, 0xE1, 0x29]) }
                    Button("Lock (Win + L)") { onKeys([0xE3, 0x0F]) }
                    Button("Show desktop (Win + D)") { onKeys([0xE3, 0x07]) }
                }
                Divider()
                Toggle("Map ⌘ to Ctrl", isOn: Binding(get: { app.config.swapCmdCtrl }, set: { v in app.updateConfig { $0.swapCmdCtrl = v } }))
            }
            .frame(width: 70)
            Button(action: onFullScreen) { Image(systemName: "arrow.up.left.and.arrow.down.right") }.help("Full screen")
            Button(action: onToggleChat) {
                HStack(spacing: 4) {
                    Image(systemName: "bubble.left.and.bubble.right")
                    Text("Chat & files")
                    if unread > 0 {
                        Text("\(unread)").font(.caption2).padding(.horizontal, 5).background(Capsule().fill(Color.red)).foregroundColor(.white)
                    }
                }
            }
            Button("Disconnect") { app.disconnectViewer() }.tint(.red).buttonStyle(.borderedProminent)
        }
        .padding(.horizontal, 12).padding(.vertical, 7)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

/// One window per remote session.
final class ViewerWindowController: NSWindowController, NSWindowDelegate {
    let remoteView = RemoteView(frame: NSRect(x: 0, y: 0, width: 1280, height: 800))
    private let session: ViewerSession
    private var chatHost: NSHostingView<AnyView>!
    private var toolbarHost: NSHostingView<AnyView>!
    private var chatOpen = false
    private var unread = 0
    private var lastChatCount = 0
    private var observer: Any?
    private let waiting = NSTextField(labelWithString: "Waiting for the first picture…")

    init(session: ViewerSession) {
        self.session = session
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 840),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        w.collectionBehavior = [.fullScreenPrimary]
        w.minSize = NSSize(width: 640, height: 420)
        w.isReleasedWhenClosed = false
        w.title = "Tether – \(session.remote.name)"
        w.tabbingMode = .disallowed
        super.init(window: w)
        w.delegate = self
        remoteView.session = session
        remoteView.swapCmdCtrl = { [weak session] in
            AppState.shared.config.swapCmdCtrl && (session?.remoteOS ?? "windows") != "mac"
        }
        remoteView.onFirstFrame = { [weak self] in self?.waiting.isHidden = true }
        session.onFrame = { [weak self] f in DispatchQueue.main.async { self?.remoteView.apply(f) } }
        buildUI()
        observer = AppState.shared.$chat.receive(on: DispatchQueue.main).sink { [weak self] lines in
            guard let self = self else { return }
            let newRemote = lines.dropFirst(min(self.lastChatCount, lines.count)).filter { $0.remote }.count
            self.lastChatCount = lines.count
            if !self.chatOpen && newRemote > 0 { self.unread += newRemote; self.rebuildToolbar() }
        }
        w.center()
        w.setFrameAutosaveName("TetherViewer")
    }

    required init?(coder: NSCoder) { fatalError() }

    private func buildUI() {
        guard let w = window else { return }
        let root = NSView()
        toolbarHost = NSHostingView(rootView: AnyView(EmptyView()))
        rebuildToolbar()
        chatHost = NSHostingView(rootView: AnyView(ChatFilesPanel().background(Color(nsColor: .controlBackgroundColor))))
        chatHost.isHidden = true
        waiting.textColor = .secondaryLabelColor
        for v in [toolbarHost!, remoteView, chatHost!, waiting] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(v)
        }
        NSLayoutConstraint.activate([
            toolbarHost.topAnchor.constraint(equalTo: root.topAnchor),
            toolbarHost.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            toolbarHost.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            remoteView.topAnchor.constraint(equalTo: toolbarHost.bottomAnchor),
            remoteView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            remoteView.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            remoteView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            chatHost.topAnchor.constraint(equalTo: toolbarHost.bottomAnchor),
            chatHost.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            chatHost.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            chatHost.widthAnchor.constraint(equalToConstant: 330),
            waiting.centerXAnchor.constraint(equalTo: remoteView.centerXAnchor),
            waiting.centerYAnchor.constraint(equalTo: remoteView.centerYAnchor),
        ])
        w.contentView = root
        w.makeFirstResponder(remoteView)
    }

    private func rebuildToolbar() {
        let chatBinding = Binding<Bool>(get: { [weak self] in self?.chatOpen ?? false }, set: { [weak self] v in self?.chatOpen = v })
        toolbarHost.rootView = AnyView(ViewerToolbar(
            onKeys: { [weak self] keys in self?.remoteView.sendCombo(keys); self?.window?.makeFirstResponder(self?.remoteView) },
            onToggleChat: { [weak self] in self?.toggleChat() },
            onFullScreen: { [weak self] in self?.window?.toggleFullScreen(nil) },
            chatOpen: chatBinding, unread: unread))
    }

    private func toggleChat() {
        chatOpen.toggle()
        chatHost.isHidden = !chatOpen
        if chatOpen { unread = 0 }
        rebuildToolbar()
        if !chatOpen { window?.makeFirstResponder(remoteView) }
    }

    func windowWillClose(_ notification: Notification) {
        remoteView.releaseAll()
        if !session.isEnded { session.disconnect() }
    }

    func windowDidResignKey(_ notification: Notification) { remoteView.releaseAll() }

    func close(reason: String) {
        window?.delegate = nil
        window?.close()
    }
}
