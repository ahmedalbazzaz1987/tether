import SwiftUI
import AppKit
import UniformTypeIdentifiers

func formatSize(_ n: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: n, countStyle: .file)
}

/// Chat + file transfer panel, used while hosting and in the viewer drawer.
struct ChatFilesPanel: View {
    @ObservedObject var app = AppState.shared
    @ObservedObject var form = PanelForm.shared

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $form.tab) {
                Text("Chat").tag(0)
                Text("Files").tag(1)
            }
            .pickerStyle(.segmented).labelsHidden().padding(12)
            Divider()
            if form.tab == 0 { chat } else { filesView }
        }
    }

    var chat: some View {
        VStack(spacing: 8) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        if app.chat.isEmpty {
                            Text("Messages are end-to-end encrypted.").font(.callout).foregroundColor(.secondary).padding(.top, 8)
                        }
                        ForEach(app.chat) { m in
                            HStack {
                                if !m.remote { Spacer(minLength: 40) }
                                Text(m.text).textSelection(.enabled)
                                    .padding(.horizontal, 11).padding(.vertical, 7)
                                    .background(RoundedRectangle(cornerRadius: 12).fill(m.remote ? Color(nsColor: .windowBackgroundColor) : Color.tetherAccent))
                                    .foregroundColor(m.remote ? .primary : .white)
                                if m.remote { Spacer(minLength: 40) }
                            }
                            .id(m.id)
                        }
                    }
                    .padding(12)
                }
                .onChange(of: app.chat.count) { _ in
                    if let last = app.chat.last { withAnimation { proxy.scrollTo(last.id, anchor: .bottom) } }
                }
            }
            HStack {
                TextField("Message…", text: $form.message).textFieldStyle(.roundedBorder).onSubmit(send)
                Button("Send", action: send).disabled(form.message.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding([.horizontal, .bottom], 12)
        }
    }

    func send() {
        app.sendChat(form.message)
        form.message = ""
    }

    var filesView: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Button("Send files…") { app.sendFiles() }.buttonStyle(.borderedProminent)
                Button("Open received") { app.openDownloads() }
            }
            Text("Tip: you can also drop files here.").font(.caption).foregroundColor(.secondary)
            ScrollView {
                VStack(spacing: 0) {
                    if app.files.isEmpty {
                        Text("No transfers yet").font(.callout).foregroundColor(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    ForEach(app.files.reversed()) { f in FileRow(f: f) }
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 10).stroke(Color.tetherAccent, lineWidth: form.dropHover ? 2 : 0))
        .onDrop(of: [UTType.fileURL], isTargeted: $form.dropHover) { providers in
            for p in providers {
                _ = p.loadObject(ofClass: URL.self) { url, _ in
                    if let u = url { DispatchQueue.main.async { app.sendFiles([u]) } }
                }
            }
            return true
        }
    }
}

struct FileRow: View {
    let f: FileProgress
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: f.incoming ? "arrow.down.circle" : "arrow.up.circle")
                Text(f.name).fontWeight(.medium).lineLimit(1).truncationMode(.middle)
                Spacer()
                if f.incoming && f.state == "done", let p = f.path {
                    Button("Show") { NSWorkspace.shared.activateFileViewerSelecting([p]) }.buttonStyle(.link)
                }
            }
            Text(f.state == "active" ? "\(formatSize(f.done)) of \(formatSize(f.size))"
                 : f.state == "done" ? "\(f.incoming ? "Received" : "Sent") · \(formatSize(f.size))" : "Failed")
                .font(.caption).foregroundColor(.secondary)
            ProgressView(value: f.size > 0 ? Double(f.done) / Double(f.size) : 1)
                .tint(f.state == "failed" ? .red : f.state == "done" ? .green : .tetherAccent)
        }
        .padding(.vertical, 8)
    }
}

struct SettingsView: View {
    @ObservedObject var app = AppState.shared
    @Binding var isPresented: Bool
    @ObservedObject var form = SettingsForm.shared

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Settings").font(.headline)
                Spacer()
                Button("Done") { app.setRelay(form.relay); isPresented = false }.keyboardShortcut(.defaultAction)
            }
            .padding(16)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    section("Connection") {
                        Text("Relay address").font(.callout)
                        TextField("tether-relay.yourname.workers.dev", text: $form.relay, onCommit: { app.setRelay(form.relay) })
                            .textFieldStyle(.roundedBorder).font(.system(.body, design: .monospaced))
                        Text("Your private relay for connections over the internet. Leave empty for local network only.")
                            .font(.caption).foregroundColor(.secondary)
                        Toggle("Allow others to connect to this Mac", isOn: Binding(get: { app.config.acceptIncoming }, set: { app.setAcceptIncoming($0) }))
                        Toggle("Allow direct connections on the local network", isOn: Binding(get: { app.config.allowLan }, set: { app.setAllowLan($0) }))
                    }
                    section("Unattended access") {
                        Text(app.config.permKpw != nil ? "A permanent password is set. This Mac can be reached any time Tether is running."
                                                       : "No permanent password. Only the one-time password works.")
                            .font(.callout).foregroundColor(.secondary)
                        HStack {
                            SecureField("New permanent password (8+ characters)", text: $form.perm).textFieldStyle(.roundedBorder)
                            Button("Save") { app.setPermanentPassword(form.perm); form.perm = "" }
                            Button("Remove") { app.clearPermanentPassword() }.disabled(app.config.permKpw == nil)
                        }
                        Toggle("Start Tether when I log in", isOn: Binding(get: { app.config.launchAtLogin }, set: { app.setLaunchAtLogin($0) }))
                    }
                    section("Permissions (only needed to be controlled)") {
                        permRow("Screen Recording", ok: app.screenPermission) { ScreenPermission.request(); openPrivacy("Privacy_ScreenCapture") }
                        permRow("Accessibility (mouse & keyboard)", ok: app.accessibilityPermission) { Injector.requestTrust(); openPrivacy("Privacy_Accessibility") }
                        Button("Re-check") { app.refreshPermissions() }.buttonStyle(.link)
                    }
                    section("Session") {
                        Toggle("Share clipboard text", isOn: Binding(get: { app.config.clipboardSync }, set: { app.setClipboard($0) }))
                        Toggle("Map ⌘ Command to Ctrl when controlling Windows", isOn: Binding(get: { app.config.swapCmdCtrl }, set: { v in app.updateConfig { $0.swapCmdCtrl = v } }))
                        HStack {
                            Text("Received files go to Downloads/Tether").font(.callout)
                            Spacer()
                            Button("Open folder") { app.openDownloads() }
                        }
                    }
                    section("Security") {
                        Text("This Mac's identity fingerprint: \(fingerprint(app.store.hostKey.publicKey.rawRepresentation))")
                            .font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                        Text("Viewers remember it and warn if it ever changes. Sessions are end-to-end encrypted (X25519 + AES-256-GCM); the relay only forwards encrypted data.")
                            .font(.caption).foregroundColor(.secondary)
                    }
                    section("Updates") {
                        Toggle("Check for updates automatically", isOn: Binding(get: { app.config.autoUpdate }, set: { v in app.updateConfig { $0.autoUpdate = v } }))
                        HStack {
                            Text(app.updateMessage).font(.callout).foregroundColor(.secondary)
                            Spacer()
                            if app.update != nil { Button("Update now") { app.applyUpdate() }.disabled(app.updating) }
                            Button("Check now") { app.checkUpdate(manual: true) }
                        }
                        Text("Version \(appVersion)").font(.caption).foregroundColor(.secondary)
                    }
                    section("Remove") {
                        HStack {
                            Button("Quit Tether") { app.quit() }
                            Button("Uninstall Tether…") { form.confirmUninstall = true }.foregroundColor(.red)
                        }
                        Text("Uninstall removes Tether's settings, login item and permissions, and moves the app to the Trash. Files you received stay in Downloads.")
                            .font(.caption).foregroundColor(.secondary)
                    }
                }
                .padding(16)
            }
        }
        .frame(width: 560, height: 620)
        .onAppear { form.relay = app.config.relayUrl; app.refreshPermissions() }
        .alert("Uninstall Tether?", isPresented: $form.confirmUninstall) {
            Button("Cancel", role: .cancel) {}
            Button("Uninstall", role: .destructive) { app.uninstall() }
        } message: {
            Text("Tether and all of its settings will be removed from this Mac. Active sessions will end.")
        }
    }

    @ViewBuilder
    func section<C: View>(_ title: String, @ViewBuilder _ c: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 13, weight: .semibold))
            c()
        }
        Divider()
    }

    func permRow(_ name: String, ok: Bool, action: @escaping () -> Void) -> some View {
        HStack {
            Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.circle").foregroundColor(ok ? .green : .orange)
            Text(name).font(.callout)
            Spacer()
            if !ok { Button("Allow…", action: action) }
        }
    }
}
