//go:build windows

package win

import (
	"os"
	"path/filepath"
	"runtime"
	"sync"
	"unsafe"

	"github.com/jchv/go-webview2/pkg/edge"
	"golang.org/x/sys/windows"
)

const (
	wmTray     = WM_APP + 1
	wmShow     = WM_APP + 2
	wmDispatch = WM_APP + 3

	MainClass = "TetherMainWindow"

	idOpen = 1001
	idQuit = 1002
)

// Shell owns the main window, the WebView2 control and the tray icon.
// All of it lives on the locked main OS thread.
type Shell struct {
	URL     string
	OnQuit  func()
	TrayTip func() string

	hwnd       uintptr
	chromium   *edge.Chromium
	webFailed  bool
	taskbarMsg uint32
	trayAdded  bool
	iconBig    uintptr
	iconSmall  uintptr

	mu    sync.Mutex
	queue []func()

	full       bool
	savedStyle uintptr
	savedPlace windowPlacement
}

type windowPlacement struct {
	Length         uint32
	Flags          uint32
	ShowCmd        uint32
	MinPosition    POINT
	MaxPosition    POINT
	NormalPosition RECT
	Device         RECT
}

type minMaxInfo struct {
	Reserved     POINT
	MaxSize      POINT
	MaxPosition  POINT
	MinTrackSize POINT
	MaxTrackSize POINT
}

type notifyIconData struct {
	Size            uint32
	Wnd             uintptr
	ID              uint32
	Flags           uint32
	CallbackMessage uint32
	Icon            uintptr
	Tip             [128]uint16
	State           uint32
	StateMask       uint32
	Info            [256]uint16
	Version         uint32
	InfoTitle       [64]uint16
	InfoFlags       uint32
	GuidItem        windows.GUID
	BalloonIcon     uintptr
}

var theShell *Shell

func (s *Shell) HWND() uintptr { return s.hwnd }

// Dispatch runs f on the UI thread.
func (s *Shell) Dispatch(f func()) {
	s.mu.Lock()
	s.queue = append(s.queue, f)
	s.mu.Unlock()
	pPostMessageW.Call(s.hwnd, wmDispatch, 0, 0)
}

// DispatchWait runs f on the UI thread and waits for it.
func (s *Shell) DispatchWait(f func()) {
	done := make(chan struct{})
	s.Dispatch(func() { f(); close(done) })
	<-done
}

func wndProc(hwnd, msg, wp, lp uintptr) uintptr {
	s := theShell
	if s != nil {
		if r, handled := s.handle(hwnd, uint32(msg), wp, lp); handled {
			return r
		}
	}
	r, _, _ := pDefWindowProcW.Call(hwnd, msg, wp, lp)
	return r
}

func (s *Shell) handle(hwnd uintptr, msg uint32, wp, lp uintptr) (uintptr, bool) {
	switch msg {
	case WM_SIZE:
		if s.chromium != nil {
			s.chromium.Resize()
		}
		return 0, true
	case WM_MOVE:
		if s.chromium != nil {
			s.chromium.NotifyParentWindowPositionChanged()
		}
	case WM_ACTIVATE:
		if wp&0xFFFF != 0 && s.chromium != nil {
			s.chromium.Focus()
		}
	case WM_GETMINMAXINFO:
		mmi := (*minMaxInfo)(unsafe.Pointer(lp))
		dpi := uintptr(96)
		if pGetDpiForWindow.Find() == nil {
			if d, _, _ := pGetDpiForWindow.Call(hwnd); d != 0 {
				dpi = d
			}
		}
		mmi.MinTrackSize = POINT{int32(720 * dpi / 96), int32(500 * dpi / 96)}
		return 0, true
	case WM_CLOSE:
		if s.full {
			s.SetFullscreen(false)
		}
		pShowWindow.Call(hwnd, SW_HIDE) // keep running in the tray
		return 0, true
	case WM_DESTROY:
		pPostQuitMessage.Call(0)
		return 0, true
	case wmShow:
		s.show()
		return 0, true
	case wmDispatch:
		s.mu.Lock()
		q := s.queue
		s.queue = nil
		s.mu.Unlock()
		for _, f := range q {
			f()
		}
		return 0, true
	case wmTray:
		switch uint32(lp & 0xFFFF) {
		case WM_LBUTTONUP, WM_LBUTTONDBLCLK:
			s.show()
		case WM_RBUTTONUP:
			s.trayMenu()
		}
		return 0, true
	case WM_COMMAND:
		switch wp & 0xFFFF {
		case idOpen:
			s.show()
		case idQuit:
			if s.OnQuit != nil {
				go s.OnQuit()
			}
		}
		return 0, true
	}
	if s.taskbarMsg != 0 && msg == s.taskbarMsg {
		s.trayAdded = false
		s.addTray()
		return 0, true
	}
	return 0, false
}

// Run creates the window and tray and pumps messages until Quit. Must be called
// from main() on the main goroutine.
func (s *Shell) Run(visible bool, ready func()) {
	runtime.LockOSThread()
	theShell = s
	s.iconBig = loadAppIcon(32)
	s.iconSmall = loadAppIcon(16)
	cursor, _, _ := pLoadCursorW.Call(0, 32512)
	wc := WNDCLASSEXW{Size: uint32(unsafe.Sizeof(WNDCLASSEXW{})), WndProc: windows.NewCallback(wndProc),
		Instance: moduleHandle(), Icon: s.iconBig, IconSm: s.iconSmall, Cursor: cursor,
		ClassName: str16(MainClass), Background: 0}
	pRegisterClassExW.Call(uintptr(unsafe.Pointer(&wc)))
	const WS_OVERLAPPEDWINDOW = 0x00CF0000
	const CW_USEDEFAULT = 0x80000000
	dpi := uintptr(96)
	w, h := uintptr(1040), uintptr(680)
	s.hwnd, _, _ = pCreateWindowExW.Call(0, uintptr(unsafe.Pointer(str16(MainClass))), uintptr(unsafe.Pointer(str16("Tether"))),
		WS_OVERLAPPEDWINDOW, CW_USEDEFAULT, CW_USEDEFAULT, w, h, 0, 0, moduleHandle(), 0)
	if pGetDpiForWindow.Find() == nil {
		if d, _, _ := pGetDpiForWindow.Call(s.hwnd); d != 0 {
			dpi = d
		}
	}
	if dpi != 96 {
		pSetWindowPos.Call(s.hwnd, 0, 0, 0, w*dpi/96, h*dpi/96, 0x0002|0x0004|0x0010 /*NOMOVE|NOZORDER|NOACTIVATE*/)
	}
	// Dark title bar when Windows is in dark mode (best effort).
	if pDwmSetWindowAttribute.Find() == nil && systemDark() {
		v := int32(1)
		pDwmSetWindowAttribute.Call(s.hwnd, 20, uintptr(unsafe.Pointer(&v)), 4)
	}
	s.taskbarMsg = uint32(func() uintptr {
		r, _, _ := pRegisterWindowMessageW.Call(uintptr(unsafe.Pointer(str16("TaskbarCreated"))))
		return r
	}())
	s.addTray()
	if visible {
		s.show()
	}
	if ready != nil {
		ready()
	}
	var m MSG
	for {
		r, _, _ := pGetMessageW.Call(uintptr(unsafe.Pointer(&m)), 0, 0, 0)
		if int32(r) <= 0 {
			break
		}
		pTranslateMessage.Call(uintptr(unsafe.Pointer(&m)))
		pDispatchMessageW.Call(uintptr(unsafe.Pointer(&m)))
	}
	s.removeTray()
}

func systemDark() bool {
	k, err := openRegKey(`Software\Microsoft\Windows\CurrentVersion\Themes\Personalize`)
	if err != nil {
		return false
	}
	defer k.Close()
	v, _, err := k.GetIntegerValue("AppsUseLightTheme")
	return err == nil && v == 0
}

func (s *Shell) ensureWeb() {
	if s.chromium != nil || s.webFailed {
		return
	}
	c := edge.NewChromium()
	c.DataPath = filepath.Join(DataDir(), "WebView2")
	os.MkdirAll(c.DataPath, 0o700)
	c.SetPermission(edge.CoreWebView2PermissionKindClipboardRead, edge.CoreWebView2PermissionStateAllow)
	if !c.Embed(s.hwnd) {
		s.webFailed = true
		go func() {
			if messageBox("Tether", "Tether needs the Microsoft Edge WebView2 Runtime to show its window.\n\n"+
				"It is built into Windows 11 and most Windows 10 PCs. Open the download page now?\n\n"+
				"(Tether keeps running in the tray and can still be controlled remotely.)", 0x4|0x40) == 6 {
				ShellOpen("https://developer.microsoft.com/microsoft-edge/webview2/")
			}
		}()
		return
	}
	s.chromium = c
	if st, err := c.GetSettings(); err == nil {
		st.PutAreDevToolsEnabled(false)
		st.PutAreDefaultContextMenusEnabled(false)
		st.PutIsZoomControlEnabled(false)
		st.PutIsStatusBarEnabled(false)
		st.PutAreBrowserAcceleratorKeysEnabled(false)
		st.PutIsBuiltInErrorPageEnabled(false)
	}
	c.Resize()
	c.Navigate(s.URL)
}

func (s *Shell) show() {
	if r, _, _ := pIsIconic.Call(s.hwnd); r != 0 {
		pShowWindow.Call(s.hwnd, SW_RESTORE)
	} else {
		pShowWindow.Call(s.hwnd, SW_SHOW)
	}
	pSetForegroundWindow.Call(s.hwnd)
	s.ensureWeb()
	if s.chromium != nil {
		s.chromium.Resize()
		s.chromium.Focus()
	}
}

// Show brings the window to the front (any goroutine).
func (s *Shell) Show() { pPostMessageW.Call(s.hwnd, wmShow, 0, 0) }

// Quit destroys the window and ends Run (any goroutine).
func (s *Shell) Quit() {
	s.Dispatch(func() {
		s.removeTray()
		pDestroyWindow.Call(s.hwnd)
	})
}

func (s *Shell) tip() string {
	if s.TrayTip != nil {
		return s.TrayTip()
	}
	return "Tether"
}

func (s *Shell) addTray() {
	nid := notifyIconData{Size: uint32(unsafe.Sizeof(notifyIconData{})), Wnd: s.hwnd, ID: 1,
		Flags: 0x1 | 0x2 | 0x4, CallbackMessage: wmTray, Icon: s.iconSmall}
	copyUTF16(nid.Tip[:], s.tip())
	if r, _, _ := pShellNotifyIconW.Call(0 /*NIM_ADD*/, uintptr(unsafe.Pointer(&nid))); r != 0 {
		s.trayAdded = true
	}
}

func (s *Shell) removeTray() {
	if !s.trayAdded {
		return
	}
	nid := notifyIconData{Size: uint32(unsafe.Sizeof(notifyIconData{})), Wnd: s.hwnd, ID: 1}
	pShellNotifyIconW.Call(2 /*NIM_DELETE*/, uintptr(unsafe.Pointer(&nid)))
	s.trayAdded = false
}

// UpdateTip refreshes the tray tooltip (any goroutine).
func (s *Shell) UpdateTip() {
	s.Dispatch(func() {
		if !s.trayAdded {
			return
		}
		nid := notifyIconData{Size: uint32(unsafe.Sizeof(notifyIconData{})), Wnd: s.hwnd, ID: 1, Flags: 0x4}
		copyUTF16(nid.Tip[:], s.tip())
		pShellNotifyIconW.Call(1 /*NIM_MODIFY*/, uintptr(unsafe.Pointer(&nid)))
	})
}

// Notify shows a tray balloon / toast (any goroutine).
func (s *Shell) Notify(title, body string) {
	s.Dispatch(func() {
		if !s.trayAdded {
			return
		}
		nid := notifyIconData{Size: uint32(unsafe.Sizeof(notifyIconData{})), Wnd: s.hwnd, ID: 1, Flags: 0x10 /*NIF_INFO*/, InfoFlags: 0x1 /*NIIF_INFO*/}
		copyUTF16(nid.InfoTitle[:], title)
		copyUTF16(nid.Info[:], body)
		pShellNotifyIconW.Call(1, uintptr(unsafe.Pointer(&nid)))
	})
}

func (s *Shell) trayMenu() {
	m, _, _ := pCreatePopupMenu.Call()
	pAppendMenuW.Call(m, 0, idOpen, uintptr(unsafe.Pointer(str16("Open Tether"))))
	pAppendMenuW.Call(m, 0x800 /*MF_SEPARATOR*/, 0, 0)
	pAppendMenuW.Call(m, 0, idQuit, uintptr(unsafe.Pointer(str16("Quit Tether"))))
	var pt POINT
	pGetCursorPos.Call(uintptr(unsafe.Pointer(&pt)))
	pSetForegroundWindow.Call(s.hwnd)
	pTrackPopupMenu.Call(m, 0x0020 /*TPM_RIGHTBUTTON*/, uintptr(pt.X), uintptr(pt.Y), 0, s.hwnd, 0)
	pPostMessageW.Call(s.hwnd, WM_NULL, 0, 0)
	pDestroyMenu.Call(m)
}

// SetFullscreen toggles a borderless window covering the current monitor (UI thread).
func (s *Shell) SetFullscreen(on bool) {
	const GWL_STYLE = ^uintptr(15) // -16
	const WS_OVERLAPPEDWINDOW = 0x00CF0000
	if on == s.full {
		return
	}
	if on {
		style, _, _ := pGetWindowLongPtrW.Call(s.hwnd, GWL_STYLE)
		s.savedStyle = style
		s.savedPlace = windowPlacement{Length: uint32(unsafe.Sizeof(windowPlacement{}))}
		pGetWindowPlacement.Call(s.hwnd, uintptr(unsafe.Pointer(&s.savedPlace)))
		mon, _, _ := pMonitorFromWindow.Call(s.hwnd, 2 /*NEAREST*/)
		var mi monitorInfoEx
		mi.Size = uint32(unsafe.Sizeof(mi))
		pGetMonitorInfoW.Call(mon, uintptr(unsafe.Pointer(&mi)))
		pSetWindowLongPtrW.Call(s.hwnd, GWL_STYLE, style&^WS_OVERLAPPEDWINDOW)
		r := mi.Monitor
		pSetWindowPos.Call(s.hwnd, 0, uintptr(r.Left), uintptr(r.Top), uintptr(r.Right-r.Left), uintptr(r.Bottom-r.Top), 0x0020|0x0040 /*FRAMECHANGED|SHOWWINDOW*/)
	} else {
		pSetWindowLongPtrW.Call(s.hwnd, GWL_STYLE, s.savedStyle)
		pSetWindowPlacement.Call(s.hwnd, uintptr(unsafe.Pointer(&s.savedPlace)))
		pSetWindowPos.Call(s.hwnd, 0, 0, 0, 0, 0, 0x0001|0x0002|0x0004|0x0020 /*NOSIZE|NOMOVE|NOZORDER|FRAMECHANGED*/)
	}
	s.full = on
	if s.chromium != nil {
		s.chromium.Resize()
	}
}

// PickFiles shows the open-file dialog on the UI thread.
func (s *Shell) PickFiles() []string {
	var out []string
	s.DispatchWait(func() { out = pickFiles(s.hwnd) })
	return out
}

func copyUTF16(dst []uint16, s string) {
	u, _ := windows.UTF16FromString(s)
	if len(u) > len(dst) {
		u = u[:len(dst)]
		u[len(u)-1] = 0
	}
	copy(dst, u)
}

// SignalExisting asks an already running Tether to show its window.
func SignalExisting() bool {
	h, _, _ := pFindWindowW.Call(uintptr(unsafe.Pointer(str16(MainClass))), 0)
	if h == 0 {
		return false
	}
	pPostMessageW.Call(h, wmShow, 0, 0)
	return true
}
