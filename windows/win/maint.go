//go:build windows

package win

import (
	"bytes"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"strings"
	"syscall"
	"time"

	"golang.org/x/sys/windows"
	"golang.org/x/sys/windows/registry"

	"tether/core/app"
)

func openRegKey(path string) (registry.Key, error) {
	return registry.OpenKey(registry.CURRENT_USER, path, registry.QUERY_VALUE)
}

// SingleInstance returns false if another Tether is already running.
// When waiting is true (after an update) it waits up to 15 s for the old one to exit.
func SingleInstance(waiting bool) bool {
	name, _ := windows.UTF16PtrFromString(`Local\TetherSingleInstance`)
	deadline := time.Now().Add(15 * time.Second)
	for {
		h, err := windows.CreateMutex(nil, false, name)
		if err == nil {
			_ = h // held for the life of the process
			return true
		}
		if h != 0 {
			windows.CloseHandle(h)
		}
		if !waiting || time.Now().After(deadline) {
			return false
		}
		time.Sleep(300 * time.Millisecond)
	}
}

// CleanupOldBinary removes the previous exe left behind by an update.
func CleanupOldBinary() {
	exe, err := os.Executable()
	if err != nil {
		return
	}
	for i := 0; i < 20; i++ {
		if err := os.Remove(exe + ".old"); err == nil || os.IsNotExist(err) {
			return
		}
		time.Sleep(500 * time.Millisecond)
	}
}

// ApplyUpdate downloads the new exe, swaps it in and restarts.
func ApplyUpdate(u *app.UpdateInfo, quit func()) error {
	exe, err := os.Executable()
	if err != nil {
		return err
	}
	tmp := exe + ".new"
	if err := app.Download(u.AssetURL, tmp); err != nil {
		return err
	}
	b := make([]byte, 2)
	f, err := os.Open(tmp)
	if err == nil {
		f.Read(b)
		f.Close()
	}
	st, _ := os.Stat(tmp)
	if !bytes.Equal(b, []byte("MZ")) || st == nil || st.Size() < 1<<20 || (u.Size > 0 && st.Size() != u.Size) {
		os.Remove(tmp)
		return errors.New("downloaded file is not valid")
	}
	os.Remove(exe + ".old")
	if err := os.Rename(exe, exe+".old"); err != nil {
		os.Remove(tmp)
		return err
	}
	if err := os.Rename(tmp, exe); err != nil {
		os.Rename(exe+".old", exe)
		return err
	}
	cmd := exec.Command(exe, "--updated")
	if err := cmd.Start(); err != nil {
		os.Rename(exe, tmp)
		os.Rename(exe+".old", exe)
		return err
	}
	quit()
	return nil
}

// Uninstall removes every trace of Tether: sign-in entry, settings, WebView2 cache,
// firewall rules (asks for admin once) and finally the exe itself.
func Uninstall(quit func()) error {
	exe, err := os.Executable()
	if err != nil {
		return err
	}
	SetAutostart(false)
	// Firewall rules are only created if Windows asked about network access; removing them needs admin.
	shellRunAs("netsh.exe", fmt.Sprintf(`advfirewall firewall delete rule name=all program="%s"`, exe))
	data := DataDir()
	script := fmt.Sprintf(`ping -n 4 127.0.0.1 >NUL & rmdir /s /q "%s" & ping -n 2 127.0.0.1 >NUL & rmdir /s /q "%s" & del /f /q "%s" & del /f /q "%s.old"`,
		data, data, exe, exe)
	cmd := exec.Command("cmd.exe")
	cmd.SysProcAttr = &syscall.SysProcAttr{HideWindow: true, CreationFlags: 0x08000000, /*CREATE_NO_WINDOW*/
		CmdLine: `cmd.exe /c "` + script + `"`}
	cmd.Dir = os.TempDir()
	if err := cmd.Start(); err != nil {
		return err
	}
	quit()
	return nil
}

var _ = strings.TrimSpace
