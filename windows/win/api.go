//go:build windows

// Package win contains the Windows-specific parts of Tether: screen capture,
// input injection, clipboard, tray, main window (WebView2) and housekeeping.
package win

import (
	"syscall"
	"unsafe"

	"golang.org/x/sys/windows"
)

var (
	user32   = windows.NewLazySystemDLL("user32.dll")
	gdi32    = windows.NewLazySystemDLL("gdi32.dll")
	kernel32 = windows.NewLazySystemDLL("kernel32.dll")
	shell32  = windows.NewLazySystemDLL("shell32.dll")
	comdlg32 = windows.NewLazySystemDLL("comdlg32.dll")
	ole32    = windows.NewLazySystemDLL("ole32.dll")
	dwmapi   = windows.NewLazySystemDLL("dwmapi.dll")

	pGetDC                      = user32.NewProc("GetDC")
	pReleaseDC                  = user32.NewProc("ReleaseDC")
	pEnumDisplayMonitors        = user32.NewProc("EnumDisplayMonitors")
	pGetMonitorInfoW            = user32.NewProc("GetMonitorInfoW")
	pGetCursorInfo              = user32.NewProc("GetCursorInfo")
	pGetIconInfo                = user32.NewProc("GetIconInfo")
	pDrawIconEx                 = user32.NewProc("DrawIconEx")
	pSendInput                  = user32.NewProc("SendInput")
	pGetSystemMetrics           = user32.NewProc("GetSystemMetrics")
	pOpenClipboard              = user32.NewProc("OpenClipboard")
	pCloseClipboard             = user32.NewProc("CloseClipboard")
	pEmptyClipboard             = user32.NewProc("EmptyClipboard")
	pGetClipboardData           = user32.NewProc("GetClipboardData")
	pSetClipboardData           = user32.NewProc("SetClipboardData")
	pGetClipboardSequenceNumber = user32.NewProc("GetClipboardSequenceNumber")
	pRegisterClassExW           = user32.NewProc("RegisterClassExW")
	pCreateWindowExW            = user32.NewProc("CreateWindowExW")
	pDefWindowProcW             = user32.NewProc("DefWindowProcW")
	pDestroyWindow              = user32.NewProc("DestroyWindow")
	pShowWindow                 = user32.NewProc("ShowWindow")
	pSetForegroundWindow        = user32.NewProc("SetForegroundWindow")
	pGetMessageW                = user32.NewProc("GetMessageW")
	pTranslateMessage           = user32.NewProc("TranslateMessage")
	pDispatchMessageW           = user32.NewProc("DispatchMessageW")
	pPostMessageW               = user32.NewProc("PostMessageW")
	pPostQuitMessage            = user32.NewProc("PostQuitMessage")
	pLoadImageW                 = user32.NewProc("LoadImageW")
	pLoadCursorW                = user32.NewProc("LoadCursorW")
	pCreatePopupMenu            = user32.NewProc("CreatePopupMenu")
	pAppendMenuW                = user32.NewProc("AppendMenuW")
	pTrackPopupMenu             = user32.NewProc("TrackPopupMenu")
	pDestroyMenu                = user32.NewProc("DestroyMenu")
	pGetCursorPos               = user32.NewProc("GetCursorPos")
	pRegisterWindowMessageW     = user32.NewProc("RegisterWindowMessageW")
	pFindWindowW                = user32.NewProc("FindWindowW")
	pGetWindowLongPtrW          = user32.NewProc("GetWindowLongPtrW")
	pSetWindowLongPtrW          = user32.NewProc("SetWindowLongPtrW")
	pSetWindowPos               = user32.NewProc("SetWindowPos")
	pGetWindowPlacement         = user32.NewProc("GetWindowPlacement")
	pSetWindowPlacement         = user32.NewProc("SetWindowPlacement")
	pMonitorFromWindow          = user32.NewProc("MonitorFromWindow")
	pMessageBoxW                = user32.NewProc("MessageBoxW")
	pIsWindowVisible            = user32.NewProc("IsWindowVisible")
	pIsIconic                   = user32.NewProc("IsIconic")
	pSetProcessDpiAwarenessCtx  = user32.NewProc("SetProcessDpiAwarenessContext")
	pGetDpiForWindow            = user32.NewProc("GetDpiForWindow")
	pSetWindowTextW             = user32.NewProc("SetWindowTextW")
	pMapVirtualKeyW             = user32.NewProc("MapVirtualKeyW")
	pMapVirtualKeyExW           = user32.NewProc("MapVirtualKeyExW")
	pGetForegroundWindow        = user32.NewProc("GetForegroundWindow")
	pGetWindowThreadProcessId   = user32.NewProc("GetWindowThreadProcessId")
	pGetKeyboardLayout          = user32.NewProc("GetKeyboardLayout")

	pCreateCompatibleDC = gdi32.NewProc("CreateCompatibleDC")
	pCreateDIBSection   = gdi32.NewProc("CreateDIBSection")
	pSelectObject       = gdi32.NewProc("SelectObject")
	pDeleteObject       = gdi32.NewProc("DeleteObject")
	pDeleteDC           = gdi32.NewProc("DeleteDC")
	pBitBlt             = gdi32.NewProc("BitBlt")
	pStretchBlt         = gdi32.NewProc("StretchBlt")
	pSetStretchBltMode  = gdi32.NewProc("SetStretchBltMode")
	pSetBrushOrgEx      = gdi32.NewProc("SetBrushOrgEx")
	pGdiFlush           = gdi32.NewProc("GdiFlush")

	pGlobalAlloc      = kernel32.NewProc("GlobalAlloc")
	pGlobalFree       = kernel32.NewProc("GlobalFree")
	pGlobalLock       = kernel32.NewProc("GlobalLock")
	pGlobalUnlock     = kernel32.NewProc("GlobalUnlock")
	pGetModuleHandleW = kernel32.NewProc("GetModuleHandleW")

	pShellNotifyIconW = shell32.NewProc("Shell_NotifyIconW")
	pShellExecuteW    = shell32.NewProc("ShellExecuteW")

	pGetOpenFileNameW = comdlg32.NewProc("GetOpenFileNameW")
	pCoInitializeEx   = ole32.NewProc("CoInitializeEx")

	pDwmSetWindowAttribute = dwmapi.NewProc("DwmSetWindowAttribute")
)

type RECT struct{ Left, Top, Right, Bottom int32 }
type POINT struct{ X, Y int32 }

type MSG struct {
	Hwnd    uintptr
	Message uint32
	WParam  uintptr
	LParam  uintptr
	Time    uint32
	Pt      POINT
	_       uint32
}

type WNDCLASSEXW struct {
	Size       uint32
	Style      uint32
	WndProc    uintptr
	ClsExtra   int32
	WndExtra   int32
	Instance   uintptr
	Icon       uintptr
	Cursor     uintptr
	Background uintptr
	MenuName   *uint16
	ClassName  *uint16
	IconSm     uintptr
}

const (
	WM_DESTROY       = 0x0002
	WM_MOVE          = 0x0003
	WM_SIZE          = 0x0005
	WM_ACTIVATE      = 0x0006
	WM_CLOSE         = 0x0010
	WM_GETMINMAXINFO = 0x0024
	WM_NULL          = 0x0000
	WM_COMMAND       = 0x0111
	WM_LBUTTONUP     = 0x0202
	WM_LBUTTONDBLCLK = 0x0203
	WM_RBUTTONUP     = 0x0205
	WM_APP           = 0x8000
	WM_DPICHANGED    = 0x02E0

	SW_HIDE       = 0
	SW_SHOWNORMAL = 1
	SW_SHOW       = 5
	SW_RESTORE    = 9
)

func str16(s string) *uint16 {
	p, _ := windows.UTF16PtrFromString(s)
	return p
}

func moduleHandle() uintptr {
	h, _, _ := pGetModuleHandleW.Call(0)
	return h
}

func loadAppIcon(size int) uintptr {
	// Resource ID 1 is embedded by go-winres (see winres/winres.json).
	h, _, _ := pLoadImageW.Call(moduleHandle(), 1, 1 /*IMAGE_ICON*/, uintptr(size), uintptr(size), 0)
	if h == 0 {
		h, _, _ = pLoadImageW.Call(0, 32512 /*IDI_APPLICATION*/, 1, uintptr(size), uintptr(size), 0x8000 /*LR_SHARED*/)
	}
	return h
}

func messageBox(title, text string, flags uintptr) int {
	r, _, _ := pMessageBoxW.Call(0, uintptr(unsafe.Pointer(str16(text))), uintptr(unsafe.Pointer(str16(title))), flags)
	return int(r)
}

// ShellOpen opens a file, folder or URL with the default handler.
func ShellOpen(target string) {
	pShellExecuteW.Call(0, uintptr(unsafe.Pointer(str16("open"))), uintptr(unsafe.Pointer(str16(target))), 0, 0, SW_SHOWNORMAL)
}

func shellRunAs(file, args string) {
	pShellExecuteW.Call(0, uintptr(unsafe.Pointer(str16("runas"))), uintptr(unsafe.Pointer(str16(file))),
		uintptr(unsafe.Pointer(str16(args))), 0, SW_HIDE)
}

// EnableDPIAwareness must run before any window is created.
func EnableDPIAwareness() {
	if pSetProcessDpiAwarenessCtx.Find() == nil {
		pSetProcessDpiAwarenessCtx.Call(^uintptr(3)) // DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2 (-4)
	}
}

var _ = syscall.Syscall
