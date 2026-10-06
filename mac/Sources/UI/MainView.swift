import SwiftUI
import AppKit

extension Color {
    static let tetherAccent = Color(red: 0.23, green: 0.45, blue: 0.96)
    static let tetherViolet = Color(red: 0.49, green: 0.23, blue: 0.93)
}

struct Card<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title).font(.system(size: 14, weight: .semibold)).padding(.bottom, 12)
            content
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color(nsColor: .separatorColor).opacity(0.6)))
    }
}

struct FieldLabel: View {
    let text: String
    var body: some View {
        Text(text.uppercased()).font(.system(size: 11, weight: .medium)).foregroundColor(.secondary)
            .padding(.top, 12).padding(.bottom, 5)
    }
}

struct LogoMark: View {
    var size: CGFloat = 24
    var body: some View {
        Group {
            if let img = NSImage(named: "AppIcon") {
                Image(nsImage: img).resizable().interpolation(.high)
            } else {
                Image(systemName: "link.circle.fill").resizable().foregroundColor(.tetherAccent)
            }
        }
        .frame(width: size, height: size)
    }
}

func copyToPasteboard(_ s: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(s, forType: .string)
}

final class MainForm: ObservableObject {
    static let shared = MainForm()
    @Published var target = ""
    @Published var password = ""
    @Published var showSettings = false
}

final class PanelForm: ObservableObject {
    static let shared = PanelForm()
    @Published var tab = 0
    @Published var message = ""
    @Published var dropHover = false
}

final class SettingsForm: ObservableObject {
    static let shared = SettingsForm()
    @Published var relay = ""
    @Published var perm = ""
    @Published var confirmUninstall = false
}

struct MainView: View {
    @ObservedObject var app = AppState.shared
    // Plain ObservableObject instead of @State: @State is a compiler macro on
    // recent SDKs and a bare swiftc (no Xcode) cannot always load its plugin.
    @ObservedObject var form = MainForm.shared

    var body: some View {
        ZStack {
            if let h = app.host {
                HostingView(host: h)
            } else {
                home
            }
            if !app.toast.isEmpty {
                VStack {
                    Spacer()
                    Text(app.toast).padding(.horizontal, 16).padding(.vertical, 10)
                        .background(Capsule().fill(Color.black.opacity(0.85))).foregroundColor(.white)
                        .padding(.bottom, 20)
                }.transition(.opacity)
            }
        }
        .frame(minWidth: 720, minHeight: 500)
        .sheet(isPresented: $form.showSettings) { SettingsView(isPresented: $form.showSettings) }
    }

    private var statusColor: Color {
        if !app.config.acceptIncoming { return .gray }
        return app.relayOnline || (app.config.relayUrl.isEmpty && app.lanActive) ? .green : .orange
    }

    private var statusText: String {
        if app.config.acceptIncoming && app.config.relayUrl.isEmpty && app.lanActive {
            let ips = localIPv4()
            return "Local network ready" + (ips.isEmpty ? "" : " (\(ips.joined(separator: ", ")))")
        }
        return app.relayStatus
    }

    var home: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                LogoMark()
                Text("Tether").font(.system(size: 16, weight: .semibold))
                Spacer()
                Button { form.showSettings = true } label: { Image(systemName: "gearshape").font(.system(size: 15)) }
                    .buttonStyle(.borderless).help("Settings")
            }
            .padding(.horizontal, 20).padding(.vertical, 12)

            if let u = app.update {
                HStack {
                    Text(app.updating ? app.updateMessage : "Tether \(u.version) is available.")
                    Spacer()
                    Button("Update now") { app.applyUpdate() }.disabled(app.updating)
                }
                .padding(10).background(RoundedRectangle(cornerRadius: 10).fill(Color.tetherAccent.opacity(0.12)))
                .padding(.horizontal, 20).padding(.bottom, 10)
            }

            HStack(alignment: .top, spacing: 16) {
                Card(title: "This Mac") {
                    FieldLabel(text: "Your ID")
                    HStack {
                        Text(formatID(app.config.id)).font(.system(size: 30, weight: .semibold, design: .monospaced)).textSelection(.enabled)
                        Spacer()
                        Button { copyToPasteboard(app.config.id); app.showToast("ID copied") } label: { Image(systemName: "doc.on.doc") }
                            .buttonStyle(.borderless).help("Copy ID")
                    }
                    FieldLabel(text: "One-time password")
                    HStack {
                        Text(app.otp).font(.system(size: 30, weight: .semibold, design: .monospaced)).kerning(3).textSelection(.enabled)
                        Spacer()
                        Button { copyToPasteboard(app.otp); app.showToast("Password copied") } label: { Image(systemName: "doc.on.doc") }
                            .buttonStyle(.borderless).help("Copy password")
                        Button { app.newOTP() } label: { Image(systemName: "arrow.clockwise") }
                            .buttonStyle(.borderless).help("New password")
                    }
                    Text("The password changes after every session. Set a permanent one in Settings for unattended access.")
                        .font(.caption).foregroundColor(.secondary).padding(.top, 6)
                    if !app.screenPermission || !app.accessibilityPermission {
                        PermissionHint().padding(.top, 12)
                    }
                    Spacer(minLength: 12)
                    HStack(spacing: 8) {
                        Circle().fill(statusColor).frame(width: 9, height: 9)
                        Text(statusText).font(.callout).foregroundColor(.secondary).lineLimit(2)
                    }
                }
                Card(title: "Control a remote computer") {
                    FieldLabel(text: "Partner ID or IP address")
                    TextField("123 456 789", text: $form.target)
                        .textFieldStyle(.roundedBorder).font(.system(size: 17, design: .monospaced))
                        .onChange(of: form.target) { _ in if !app.view.error.isEmpty { app.view.error = ""; app.view.keyChanged = false } }
                    FieldLabel(text: "Password")
                    SecureField("Password", text: $form.password).textFieldStyle(.roundedBorder).font(.system(size: 14, design: .monospaced))
                        .onSubmit(connect)
                    if app.view.keyChanged {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Identity changed").bold()
                            Text(app.view.error).font(.callout)
                            Button("Trust the new identity") { app.forgetHost(app.view.target) }
                        }
                        .padding(10).background(RoundedRectangle(cornerRadius: 9).fill(Color.orange.opacity(0.14)))
                        .padding(.top, 10)
                    } else if !app.view.error.isEmpty {
                        Text(app.view.error).foregroundColor(.red).font(.callout).padding(.top, 8)
                    }
                    HStack {
                        Button(action: connect) {
                            Text(app.view.state == "connecting" ? "Connecting…" : "Connect").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent).controlSize(.large).keyboardShortcut(.defaultAction)
                        .disabled(app.view.state != "idle")
                        if app.view.state == "connecting" {
                            Button("Cancel") { app.cancelConnect() }.controlSize(.large)
                        }
                    }
                    .padding(.top, 12)
                    FieldLabel(text: "Recent").padding(.top, 10)
                    RecentList(target: $form.target, password: $form.password)
                }
            }
            .padding(.horizontal, 20).padding(.bottom, 20)
        }
    }

    func connect() {
        guard !form.target.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        app.connect(target: form.target, password: form.password)
    }
}

struct RecentList: View {
    @ObservedObject var app = AppState.shared
    @Binding var target: String
    @Binding var password: String

    var body: some View {
        if app.config.recent.isEmpty {
            Text("No recent connections").font(.callout).foregroundColor(.secondary)
        } else {
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(app.config.recent, id: \.target) { r in
                        HStack(spacing: 10) {
                            Image(systemName: r.os == "mac" ? "laptopcomputer" : "pc")
                                .frame(width: 30, height: 30)
                                .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .windowBackgroundColor)))
                            VStack(alignment: .leading, spacing: 1) {
                                Text(r.name.isEmpty ? formatID(r.target) : r.name).fontWeight(.medium).lineLimit(1)
                                Text(formatID(r.target)).font(.system(size: 11, design: .monospaced)).foregroundColor(.secondary)
                            }
                            Spacer()
                            Button { app.removeRecent(r.target) } label: { Image(systemName: "xmark") }
                                .buttonStyle(.borderless).foregroundColor(.secondary).help("Remove")
                        }
                        .padding(.horizontal, 8).padding(.vertical, 6)
                        .contentShape(Rectangle())
                        .onTapGesture { target = formatID(r.target); password = "" }
                    }
                }
            }
        }
    }
}

struct PermissionHint: View {
    @ObservedObject var app = AppState.shared
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("To be controlled, this Mac needs permission:").font(.callout).bold()
            if !app.screenPermission {
                HStack { Text("• Screen Recording").font(.callout); Spacer(); Button("Allow…") { ScreenPermission.request(); openPrivacy("Privacy_ScreenCapture") } }
            }
            if !app.accessibilityPermission {
                HStack { Text("• Accessibility (mouse & keyboard)").font(.callout); Spacer(); Button("Allow…") { Injector.requestTrust(); openPrivacy("Privacy_Accessibility") } }
            }
            Text("Controlling other computers needs no permission.").font(.caption).foregroundColor(.secondary)
        }
        .padding(10).background(RoundedRectangle(cornerRadius: 9).fill(Color.orange.opacity(0.12)))
    }
}

func openPrivacy(_ pane: String) {
    if let u = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") { NSWorkspace.shared.open(u) }
}

struct HostingView: View {
    @ObservedObject var app = AppState.shared
    let host: HostState
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                LogoMark()
                Text("Tether").font(.system(size: 16, weight: .semibold)).foregroundColor(.white)
                Spacer()
                Button("Disconnect") { app.endHostSession() }.controlSize(.large)
            }
            .padding(.horizontal, 20).padding(.vertical, 12)
            .background(Color.red)
            HStack(spacing: 14) {
                Circle().fill(Color.red).frame(width: 14, height: 14)
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(host.viewer) is controlling this Mac").font(.system(size: 18, weight: .semibold))
                    Text(host.kind == "direct" ? "Direct connection on your local network · end-to-end encrypted"
                                               : "Connected through your relay · end-to-end encrypted")
                        .font(.callout).foregroundColor(.secondary)
                }
                Spacer()
            }
            .padding(20)
            ChatFilesPanel()
                .background(RoundedRectangle(cornerRadius: 14).fill(Color(nsColor: .controlBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color(nsColor: .separatorColor).opacity(0.6)))
                .padding([.horizontal, .bottom], 20)
        }
    }
}
