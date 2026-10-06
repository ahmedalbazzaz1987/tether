// Package app is the platform-neutral heart of the Tether desktop app:
// identity, host service (relay + LAN), viewer sessions and UI state.
package app

import (
	"context"
	"crypto/ed25519"
	"encoding/hex"
	"errors"
	"fmt"
	"log"
	"net"
	"os"
	"strconv"
	"strings"
	"sync"
	"time"

	"tether/core/proto"
	"tether/core/relay"
	"tether/core/session"
)

type Hooks struct {
	OSName       string
	SetAutostart func(bool) error
	PickFiles    func() []string
	OpenPath     func(string)
	Notify       func(title, body string)
	ShowWindow   func()
	Quit         func()
	Uninstall    func() error
	ApplyUpdate  func(u *UpdateInfo) error
	UpdateAsset  string
	Fullscreen   func(on bool)
}

type ChatLine struct {
	Remote bool   `json:"remote"`
	Text   string `json:"text"`
	TS     int64  `json:"ts"`
}

type App struct {
	Store *Store
	Plat  session.HostPlatform
	Hooks Hooks
	Hub   *Hub

	mu          sync.Mutex
	otp         string
	otpKPW      []byte
	limiter     proto.Limiter
	relayHost   *relay.Host
	relayOnline bool
	relayStatus string
	lanLn       net.Listener
	discovery   relay.Responder
	lanErr      string

	hostSess   *session.Host
	viewSess   *session.Viewer
	view       ViewState
	cancelDial context.CancelFunc
	chat       []ChatLine
	files      []session.FileProgress
	ping       int
	update     *UpdateInfo
	updBusy    bool
	updMsg     string
}

type ViewState struct {
	State       string          `json:"state"` // idle, connecting, connected
	Target      string          `json:"target"`
	RemoteName  string          `json:"remoteName"`
	RemoteOS    string          `json:"remoteOS"`
	Displays    []proto.Display `json:"displays"`
	Display     int             `json:"display"`
	Kind        string          `json:"kind"`
	Error       string          `json:"error"`
	KeyChanged  bool            `json:"keyChanged"`
	Fingerprint string          `json:"fingerprint"`
}

var errIdentity = errors.New("identity changed")

func New(store *Store, plat session.HostPlatform, hooks Hooks) *App {
	a := &App{Store: store, Plat: plat, Hooks: hooks}
	a.view.State = "idle"
	a.Hub = newHub(a)
	a.newOTP()
	return a
}

// Start launches the host service.
func (a *App) Start() {
	a.restartHost()
	if a.Store.Get().AutoUpdate {
		go func() {
			time.Sleep(8 * time.Second)
			a.checkUpdate(false)
		}()
	}
}

func (a *App) newOTP() {
	p := OneTimePassword()
	k := proto.DeriveKPW(p, a.Store.SaltBytes(), proto.KDFIters)
	a.mu.Lock()
	a.otp, a.otpKPW = p, k
	a.mu.Unlock()
}

func (a *App) candidates() [][]byte {
	a.mu.Lock()
	defer a.mu.Unlock()
	out := [][]byte{a.otpKPW}
	if p := a.Store.PermKPW(); p != nil {
		out = append(out, p)
	}
	return out
}

func (a *App) lanAddrs() []string {
	a.mu.Lock()
	ln := a.lanLn
	a.mu.Unlock()
	if ln == nil {
		return nil
	}
	port := ln.Addr().(*net.TCPAddr).Port
	var out []string
	for _, ip := range relay.LocalIPv4() {
		out = append(out, net.JoinHostPort(ip, strconv.Itoa(port)))
	}
	return out
}

func (a *App) restartHost() {
	cfg := a.Store.Get()
	a.mu.Lock()
	if a.relayHost != nil {
		a.relayHost.Stop()
		a.relayHost = nil
	}
	if a.lanLn != nil {
		a.lanLn.Close()
		a.lanLn = nil
	}
	a.discovery.Stop()
	a.lanErr = ""
	a.mu.Unlock()

	if cfg.AcceptIncoming && cfg.AllowLAN {
		ln, err := net.Listen("tcp", fmt.Sprintf(":%d", cfg.LANPort))
		if err != nil {
			ln, err = net.Listen("tcp", ":0")
		}
		if err != nil {
			a.mu.Lock()
			a.lanErr = err.Error()
			a.mu.Unlock()
		} else {
			a.mu.Lock()
			a.lanLn = ln
			a.mu.Unlock()
			port := ln.Addr().(*net.TCPAddr).Port
			if err := a.discovery.Start(cfg.ID, func() int { return port }); err != nil {
				log.Printf("LAN discovery unavailable: %v", err)
			}
			go func() {
				for {
					c, err := ln.Accept()
					if err != nil {
						return
					}
					go a.handleIncoming(proto.NewTCP(c))
				}
			}()
		}
	}
	if cfg.AcceptIncoming && strings.TrimSpace(cfg.RelayURL) != "" {
		h := &relay.Host{Relay: cfg.RelayURL, ID: cfg.ID, Secret: a.Store.RelaySecret(), LAN: a.lanAddrs,
			OnIncoming: a.handleIncoming,
			OnStatus: func(on bool, msg string) {
				a.mu.Lock()
				a.relayOnline, a.relayStatus = on, msg
				a.mu.Unlock()
				a.push()
			}}
		a.mu.Lock()
		a.relayHost = h
		a.relayOnline, a.relayStatus = false, "Connecting to relay…"
		a.mu.Unlock()
		h.Start()
	} else {
		a.mu.Lock()
		a.relayOnline = false
		if !cfg.AcceptIncoming {
			a.relayStatus = "Incoming connections are turned off"
		} else {
			a.relayStatus = "No relay set – only local network connections"
		}
		a.mu.Unlock()
	}
	a.push()
}

func (a *App) handleIncoming(t proto.Transport) {
	if !a.Store.Get().AcceptIncoming {
		t.Close()
		return
	}
	timer := time.AfterFunc(25*time.Second, func() { t.Close() })
	ch, vname, err := proto.ServerHandshake(t, proto.HostParams{
		Key: a.Store.HostKey(), Name: a.Plat.MachineName(), OS: osByte(a.Hooks.OSName),
		Salt: a.Store.SaltBytes(), Iters: proto.KDFIters, Candidates: a.candidates, Limiter: &a.limiter,
		Busy: func() bool { a.mu.Lock(); defer a.mu.Unlock(); return a.hostSess != nil },
	})
	timer.Stop()
	if err != nil {
		t.Close()
		if errors.Is(err, proto.ErrBadPassword) && vname != "" {
			log.Printf("rejected %q: wrong password", vname)
		}
		return
	}
	var s *session.Host
	s = session.NewHost(ch, vname, a.Plat, session.Events{
		OnChat:  func(remote bool, text string) { a.addChat(remote, text) },
		OnFile:  a.fileEvent,
		OnEnded: func(reason string) {},
		OnPing:  func(ms int) {},
	})
	s.SetClipboardSync(a.Store.Get().ClipboardSync)
	a.mu.Lock()
	a.hostSess = s
	a.chat = nil
	a.mu.Unlock()
	a.push()
	if a.Hooks.Notify != nil {
		a.Hooks.Notify("Tether", vname+" is now controlling this computer")
	}
	if a.Hooks.ShowWindow != nil {
		a.Hooks.ShowWindow()
	}
	s.Run()
	<-s.Done()
	a.mu.Lock()
	if a.hostSess == s {
		a.hostSess = nil
	}
	a.mu.Unlock()
	a.newOTP() // one-time password: rotate after every session
	a.push()
	if a.Hooks.Notify != nil {
		a.Hooks.Notify("Tether", "Remote session ended")
	}
}

func osByte(s string) byte {
	if s == "mac" {
		return proto.OSMac
	}
	return proto.OSWindows
}

func (a *App) addChat(remote bool, text string) {
	a.mu.Lock()
	a.chat = append(a.chat, ChatLine{remote, text, time.Now().UnixMilli()})
	if len(a.chat) > 200 {
		a.chat = a.chat[len(a.chat)-200:]
	}
	a.mu.Unlock()
	a.Hub.Event(map[string]any{"ev": "chat", "remote": remote, "text": text})
	a.push()
}

func (a *App) fileEvent(p session.FileProgress) {
	a.mu.Lock()
	found := false
	for i := range a.files {
		if a.files[i].ID == p.ID && a.files[i].Incoming == p.Incoming {
			a.files[i] = p
			found = true
		}
	}
	if !found {
		a.files = append(a.files, p)
		if len(a.files) > 30 {
			a.files = a.files[len(a.files)-30:]
		}
	}
	a.mu.Unlock()
	a.Hub.Event(map[string]any{"ev": "file", "file": p})
	if p.State == "done" && p.Incoming && a.Hooks.Notify != nil {
		a.Hooks.Notify("File received", p.Name)
	}
}

// ---------- viewer ----------

func (a *App) connect(target, password string) {
	t, isID := session.NormalizeTarget(target)
	if t == "" {
		return
	}
	cfg := a.Store.Get()
	if isID && t == cfg.ID {
		a.setViewError(t, "That is this computer's own ID")
		return
	}
	a.mu.Lock()
	if a.view.State != "idle" {
		a.mu.Unlock()
		return
	}
	ctx, cancel := context.WithCancel(context.Background())
	a.cancelDial = cancel
	a.view = ViewState{State: "connecting", Target: t}
	a.chat = nil
	a.mu.Unlock()
	a.push()
	go func() {
		defer cancel()
		tr, err := session.Dial(ctx, t, cfg.RelayURL)
		if err != nil {
			a.setViewError(t, err.Error())
			return
		}
		var newPin string
		verify := func(info proto.ServerInfo) error {
			pub := hex.EncodeToString(info.HostPub)
			old := a.Store.Get().KnownHosts[t]
			if old != "" && old != pub {
				return errIdentity
			}
			newPin = pub
			return nil
		}
		v, err := session.Connect(tr, a.Plat.MachineName(), password, verify, a.Plat.Clipboard(),
			a.Plat.DownloadsDir(), session.ViewerEvents{
				Events: session.Events{
					OnChat: func(remote bool, text string) { a.addChat(remote, text) },
					OnFile: a.fileEvent,
					OnPing: func(ms int) {
						a.mu.Lock()
						a.ping = ms
						a.mu.Unlock()
						a.Hub.Event(map[string]any{"ev": "ping", "ms": ms})
					},
				},
				OnHello: func(m proto.Control) {
					a.mu.Lock()
					a.view.RemoteOS = m.OS
					a.view.Displays = m.Displays
					if m.Display != nil {
						a.view.Display = *m.Display
					}
					if m.Name != "" {
						a.view.RemoteName = m.Name
					}
					a.mu.Unlock()
					a.push()
				},
				OnVideo: func(p []byte) { a.Hub.Binary(p) },
			})
		if ctx.Err() != nil {
			if v != nil {
				v.Disconnect()
			}
			return
		}
		if err != nil {
			if errors.Is(err, errIdentity) {
				a.mu.Lock()
				a.view = ViewState{State: "idle", Target: t, KeyChanged: true,
					Error: "This computer's identity key has changed since your last connection. If you did not reinstall Tether on it, someone may be intercepting the connection."}
				a.mu.Unlock()
				a.push()
				return
			}
			a.setViewError(t, err.Error())
			return
		}
		a.Store.Update(func(c *Config) {
			c.KnownHosts[t] = newPin
			rec := Recent{Target: t, Name: v.Remote.Name, OS: map[byte]string{1: "mac", 2: "windows"}[v.Remote.OS], When: time.Now()}
			out := []Recent{rec}
			for _, r := range c.Recent {
				if r.Target != t && len(out) < 12 {
					out = append(out, r)
				}
			}
			c.Recent = out
		})
		v.SetClipboardSync(cfg.ClipboardSync)
		a.mu.Lock()
		a.viewSess = v
		a.view.State = "connected"
		a.view.RemoteName = v.Remote.Name
		a.view.Kind = v.Kind()
		a.view.Fingerprint = Fingerprint(v.Remote.HostPub)
		a.mu.Unlock()
		a.push()
		if cfg.Quality != "" && cfg.Quality != "balanced" {
			v.SetQuality(cfg.Quality)
		}
		v.Run(a.Hooks.OSName, a.Plat.MachineName())
		a.mu.Lock()
		if a.viewSess == v {
			a.viewSess = nil
			a.view = ViewState{State: "idle", Target: t}
		}
		a.mu.Unlock()
		a.Hub.Event(map[string]any{"ev": "ended", "reason": "Session ended"})
		a.push()
	}()
}

func (a *App) setViewError(t, msg string) {
	a.mu.Lock()
	a.view = ViewState{State: "idle", Target: t, Error: msg}
	a.mu.Unlock()
	a.push()
}

// ---------- state for UI ----------

func formatID(id string) string {
	if len(id) != 9 {
		return id
	}
	return id[0:3] + " " + id[3:6] + " " + id[6:9]
}

func (a *App) State() map[string]any {
	cfg := a.Store.Get()
	a.mu.Lock()
	defer a.mu.Unlock()
	var host any
	if a.hostSess != nil {
		host = map[string]any{"viewer": a.hostSess.ViewerName, "kind": a.hostSess.Kind()}
	}
	var upd any
	if a.update != nil {
		upd = map[string]any{"version": a.update.Version, "notes": a.update.Notes}
	}
	ips := relay.LocalIPv4()
	if ips == nil {
		ips = []string{}
	}
	return map[string]any{
		"ev": "state", "version": session.AppVersion, "os": a.Hooks.OSName,
		"id": cfg.ID, "idFmt": formatID(cfg.ID), "otp": a.otp, "machine": a.Plat.MachineName(),
		"relayOnline": a.relayOnline, "relayStatus": a.relayStatus, "relayUrl": cfg.RelayURL,
		"allowLan": cfg.AllowLAN, "lanActive": a.lanLn != nil, "lanError": a.lanErr, "lanIPs": ips,
		"lanPort": cfg.LANPort,
		"quality": cfg.Quality, "launchAtLogin": cfg.LaunchAtLogin, "clipboardSync": cfg.ClipboardSync,
		"acceptIncoming": cfg.AcceptIncoming, "autoUpdate": cfg.AutoUpdate,
		"hasPermPassword": cfg.PermKPW != "", "fingerprint": Fingerprint(a.Store.HostKey().Public().(ed25519.PublicKey)),
		"recent": cfg.Recent, "host": host, "view": a.view, "chat": a.chat, "files": a.files,
		"ping": a.ping, "update": upd, "updBusy": a.updBusy, "updMsg": a.updMsg,
		"downloads": a.Plat.DownloadsDir(),
	}
}

func (a *App) push() {
	if a.Hub != nil {
		a.Hub.Event(a.State())
	}
}

// ---------- commands from UI ----------

type Cmd struct {
	Cmd      string         `json:"cmd"`
	Target   string         `json:"target"`
	Password string         `json:"password"`
	Text     string         `json:"text"`
	Settings map[string]any `json:"settings"`
	K        int            `json:"k"`
	B        int            `json:"b"`
	X        int            `json:"x"`
	Y        int            `json:"y"`
	DX       int            `json:"dx"`
	DY       int            `json:"dy"`
	D        bool           `json:"d,omitempty"`
	H        int            `json:"h,omitempty"`
	Seq      uint32         `json:"seq,omitempty"`
	ID       int            `json:"id,omitempty"`
	Q        string         `json:"q,omitempty"`
	Keys     []int          `json:"keys,omitempty"`
}

func (a *App) activeCommon() interface {
	Chat(string) error
	SendFile(string) error
} {
	a.mu.Lock()
	defer a.mu.Unlock()
	if a.viewSess != nil {
		return a.viewSess
	}
	if a.hostSess != nil {
		return a.hostSess
	}
	return nil
}

func clamp16(v int) uint16 {
	if v < 0 {
		return 0
	}
	if v > 65535 {
		return 65535
	}
	return uint16(v)
}

func clampI16(v int) int16 {
	if v < -32768 {
		return -32768
	}
	if v > 32767 {
		return 32767
	}
	return int16(v)
}

func (a *App) Handle(c Cmd) {
	a.mu.Lock()
	v := a.viewSess
	a.mu.Unlock()
	switch c.Cmd {
	case "state":
		a.push()
	case "mouse":
		if v != nil {
			v.Mouse(proto.MouseEvent{Kind: byte(c.K), Button: byte(c.B), X: clamp16(c.X), Y: clamp16(c.Y), DX: clampI16(c.DX), DY: clampI16(c.DY)})
		}
	case "key":
		if v != nil {
			v.Key(proto.KeyEvent{Down: c.D, HID: uint16(c.H)})
		}
	case "combo":
		if v != nil {
			for _, k := range c.Keys {
				v.Key(proto.KeyEvent{Down: true, HID: uint16(k)})
			}
			for i := len(c.Keys) - 1; i >= 0; i-- {
				v.Key(proto.KeyEvent{Down: false, HID: uint16(c.Keys[i])})
			}
		}
	case "ack":
		if v != nil {
			v.Ack(c.Seq)
		}
	case "display":
		if v != nil {
			v.SelectDisplay(c.ID)
			a.mu.Lock()
			a.view.Display = c.ID
			a.mu.Unlock()
			a.push()
		}
	case "quality":
		if v != nil {
			v.SetQuality(c.Q)
		}
		a.Store.Update(func(cf *Config) { cf.Quality = c.Q })
		a.push()
	case "refresh":
		if v != nil {
			v.Refresh()
		}
	case "connect":
		a.connect(c.Target, c.Password)
	case "cancelConnect":
		a.mu.Lock()
		if a.cancelDial != nil {
			a.cancelDial()
		}
		if a.view.State == "connecting" {
			a.view = ViewState{State: "idle", Target: a.view.Target}
		}
		a.mu.Unlock()
		a.push()
	case "disconnect":
		if v != nil {
			go v.Disconnect()
		}
	case "endHost":
		a.mu.Lock()
		h := a.hostSess
		a.mu.Unlock()
		if h != nil {
			go h.Disconnect()
		}
	case "newOtp":
		a.newOTP()
		a.push()
	case "chat":
		if s := a.activeCommon(); s != nil && strings.TrimSpace(c.Text) != "" {
			if s.Chat(c.Text) == nil {
				a.addChat(false, c.Text)
			}
		}
	case "sendFile":
		s := a.activeCommon()
		if s == nil || a.Hooks.PickFiles == nil {
			return
		}
		go func() {
			for _, p := range a.Hooks.PickFiles() {
				if err := s.SendFile(p); err != nil {
					a.Hub.Event(map[string]any{"ev": "toast", "text": err.Error()})
				}
			}
		}()
	case "openDownloads":
		os.MkdirAll(a.Plat.DownloadsDir(), 0o755)
		if a.Hooks.OpenPath != nil {
			a.Hooks.OpenPath(a.Plat.DownloadsDir())
		}
	case "openPath":
		if a.Hooks.OpenPath != nil && c.Text != "" {
			a.Hooks.OpenPath(c.Text)
		}
	case "setPermPassword":
		p := proto.NormalizePassword(c.Password)
		if len(p) < 8 {
			a.Hub.Event(map[string]any{"ev": "toast", "text": "Use at least 8 characters"})
			return
		}
		a.Store.SetPermKPW(proto.DeriveKPW(p, a.Store.SaltBytes(), proto.KDFIters))
		a.Hub.Event(map[string]any{"ev": "toast", "text": "Unattended password saved"})
		a.push()
	case "clearPermPassword":
		a.Store.SetPermKPW(nil)
		a.push()
	case "forgetHost":
		a.Store.Update(func(cf *Config) { delete(cf.KnownHosts, c.Target) })
		a.mu.Lock()
		a.view.KeyChanged = false
		a.view.Error = ""
		a.mu.Unlock()
		a.push()
	case "removeRecent":
		a.Store.Update(func(cf *Config) {
			out := cf.Recent[:0]
			for _, r := range cf.Recent {
				if r.Target != c.Target {
					out = append(out, r)
				}
			}
			cf.Recent = out
		})
		a.push()
	case "clearError":
		a.mu.Lock()
		a.view.Error = ""
		a.view.KeyChanged = false
		a.mu.Unlock()
		a.push()
	case "settings":
		a.applySettings(c.Settings)
	case "checkUpdate":
		go a.checkUpdate(true)
	case "applyUpdate":
		go a.applyUpdate()
	case "uninstall":
		if a.Hooks.Uninstall != nil {
			a.stopAll()
			if err := a.Hooks.Uninstall(); err != nil {
				a.Hub.Event(map[string]any{"ev": "toast", "text": err.Error()})
			}
		}
	case "fullscreen":
		if a.Hooks.Fullscreen != nil {
			a.Hooks.Fullscreen(c.D)
		}
	case "quit":
		a.stopAll()
		if a.Hooks.Quit != nil {
			a.Hooks.Quit()
		}
	}
}

func (a *App) stopAll() {
	a.mu.Lock()
	v, h, rh := a.viewSess, a.hostSess, a.relayHost
	a.mu.Unlock()
	if v != nil {
		v.Disconnect()
	}
	if h != nil {
		h.Disconnect()
	}
	if rh != nil {
		rh.Stop()
	}
}

func (a *App) applySettings(s map[string]any) {
	restart := false
	var autostart *bool
	a.Store.Update(func(c *Config) {
		for k, v := range s {
			switch k {
			case "relayUrl":
				if x, ok := v.(string); ok && x != c.RelayURL {
					c.RelayURL = strings.TrimSpace(x)
					restart = true
				}
			case "allowLan":
				if x, ok := v.(bool); ok && x != c.AllowLAN {
					c.AllowLAN = x
					restart = true
				}
			case "acceptIncoming":
				if x, ok := v.(bool); ok && x != c.AcceptIncoming {
					c.AcceptIncoming = x
					restart = true
				}
			case "clipboardSync":
				if x, ok := v.(bool); ok {
					c.ClipboardSync = x
				}
			case "autoUpdate":
				if x, ok := v.(bool); ok {
					c.AutoUpdate = x
				}
			case "launchAtLogin":
				if x, ok := v.(bool); ok {
					c.LaunchAtLogin = x
					autostart = &x
				}
			case "lanPort":
				if x, ok := v.(float64); ok && int(x) > 1024 && int(x) < 65536 && int(x) != c.LANPort {
					c.LANPort = int(x)
					restart = true
				}
			}
		}
	})
	if autostart != nil && a.Hooks.SetAutostart != nil {
		if err := a.Hooks.SetAutostart(*autostart); err != nil {
			a.Hub.Event(map[string]any{"ev": "toast", "text": "Could not change launch at login: " + err.Error()})
		}
	}
	cs := a.Store.Get().ClipboardSync
	a.mu.Lock()
	if a.viewSess != nil {
		a.viewSess.SetClipboardSync(cs)
	}
	if a.hostSess != nil {
		a.hostSess.SetClipboardSync(cs)
	}
	a.mu.Unlock()
	if restart {
		a.restartHost()
	} else {
		a.push()
	}
}
