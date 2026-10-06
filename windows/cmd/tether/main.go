//go:build windows

// Tether for Windows — a small, portable remote desktop app.
package main

import (
	"log"
	"os"
	"path/filepath"
	"runtime"

	"tether/core/app"
	"tether/win"
)

func init() { runtime.LockOSThread() }

func main() {
	background, updated := false, false
	for _, a := range os.Args[1:] {
		switch a {
		case "--background":
			background = true
		case "--updated":
			updated = true
		}
	}
	win.EnableDPIAwareness()
	if !win.SingleInstance(updated) {
		win.SignalExisting()
		return
	}
	if updated {
		go win.CleanupOldBinary()
	}
	dir := win.DataDir()
	os.MkdirAll(dir, 0o700)
	if f, err := os.OpenFile(filepath.Join(dir, "tether.log"), os.O_CREATE|os.O_WRONLY|os.O_TRUNC, 0o600); err == nil {
		log.SetOutput(f)
	}

	store, err := app.OpenStore(dir, win.Protect, win.Unprotect)
	if err != nil {
		log.Fatal(err)
	}
	shell := &win.Shell{}
	plat := win.NewPlatform(shell.HWND)
	var a *app.App
	quit := func() { shell.Quit() }
	a = app.New(store, plat, app.Hooks{
		OSName:       "windows",
		SetAutostart: win.SetAutostart,
		PickFiles:    shell.PickFiles,
		OpenPath:     win.ShellOpen,
		Notify:       shell.Notify,
		ShowWindow:   shell.Show,
		Quit:         quit,
		Uninstall:    func() error { return win.Uninstall(quit) },
		ApplyUpdate:  func(u *app.UpdateInfo) error { return win.ApplyUpdate(u, quit) },
		UpdateAsset:  "Tether-Windows-" + map[string]string{"amd64": "x64", "arm64": "arm64"}[runtime.GOARCH] + ".exe",
		Fullscreen:   func(on bool) { shell.Dispatch(func() { shell.SetFullscreen(on) }) },
	})
	url, err := a.Hub.Serve()
	if err != nil {
		log.Fatal(err)
	}
	shell.URL = url
	if f := os.Getenv("TETHER_DEBUG_URL_FILE"); f != "" { // used by automated tests only
		os.WriteFile(f, []byte(url), 0o600)
	}
	shell.OnQuit = func() { a.Handle(app.Cmd{Cmd: "quit"}) }
	shell.TrayTip = func() string {
		s := a.State()
		return "Tether – ID " + s["idFmt"].(string)
	}
	// Keep the sign-in entry in sync with the setting (and with the exe's current path).
	if store.Get().LaunchAtLogin {
		win.SetAutostart(true)
	}
	shell.Run(!background, func() { a.Start() })
}
