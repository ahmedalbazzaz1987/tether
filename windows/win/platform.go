//go:build windows

package win

import (
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"
	"unsafe"

	"golang.org/x/sys/windows"
	"golang.org/x/sys/windows/registry"

	"tether/core/proto"
	"tether/core/session"
	"tether/core/video"
)

// ---------- clipboard ----------

type clipboard struct {
	mu       sync.Mutex
	hwnd     func() uintptr
	cacheSeq uint64
	cache    string
}

func openClip(hwnd uintptr) bool {
	for i := 0; i < 10; i++ {
		if r, _, _ := pOpenClipboard.Call(hwnd); r != 0 {
			return true
		}
		time.Sleep(15 * time.Millisecond)
	}
	return false
}

func (c *clipboard) GetText() (string, uint64) {
	s, _, _ := pGetClipboardSequenceNumber.Call()
	seq := uint64(s)
	c.mu.Lock()
	defer c.mu.Unlock()
	if seq == c.cacheSeq {
		return c.cache, seq
	}
	if !openClip(0) {
		return c.cache, c.cacheSeq
	}
	defer pCloseClipboard.Call()
	text := ""
	if h, _, _ := pGetClipboardData.Call(13 /*CF_UNICODETEXT*/); h != 0 {
		if p, _, _ := pGlobalLock.Call(h); p != 0 {
			text = windows.UTF16PtrToString((*uint16)(unsafe.Pointer(p)))
			pGlobalUnlock.Call(h)
		}
	}
	c.cache, c.cacheSeq = text, seq
	return text, seq
}

func (c *clipboard) SetText(s string) {
	u, err := windows.UTF16FromString(strings.ReplaceAll(strings.ReplaceAll(s, "\r\n", "\n"), "\n", "\r\n"))
	if err != nil {
		return
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	if !openClip(c.hwnd()) {
		return
	}
	defer pCloseClipboard.Call()
	pEmptyClipboard.Call()
	size := uintptr(len(u) * 2)
	h, _, _ := pGlobalAlloc.Call(0x0002 /*GMEM_MOVEABLE*/, size)
	if h == 0 {
		return
	}
	p, _, _ := pGlobalLock.Call(h)
	if p == 0 {
		pGlobalFree.Call(h)
		return
	}
	copy(unsafe.Slice((*uint16)(unsafe.Pointer(p)), len(u)), u)
	pGlobalUnlock.Call(h)
	if r, _, _ := pSetClipboardData.Call(13, h); r == 0 {
		pGlobalFree.Call(h)
	}
}

// ---------- platform ----------

// Platform implements session.HostPlatform for Windows.
type Platform struct {
	cap  gdiCapturer
	inj  *injector
	clip *clipboard
	name string
}

func NewPlatform(hwnd func() uintptr) *Platform {
	name, _ := os.Hostname()
	if name == "" {
		name = "Windows PC"
	}
	return &Platform{inj: newInjector(), clip: &clipboard{hwnd: hwnd}, name: name}
}

func (p *Platform) OSName() string                     { return "windows" }
func (p *Platform) MachineName() string                { return p.name }
func (p *Platform) Displays() []proto.Display          { return displays() }
func (p *Platform) Capture(d int) (video.Frame, error) { return p.cap.Capture(d) }
func (p *Platform) Mouse(d int, ev proto.MouseEvent)   { p.inj.Mouse(d, ev) }
func (p *Platform) Key(ev proto.KeyEvent)              { p.inj.Key(ev) }
func (p *Platform) ReleaseAll()                        { p.inj.ReleaseAll() }
func (p *Platform) Clipboard() session.Clipboard       { return p.clip }
func (p *Platform) DownloadsDir() string {
	d, err := windows.KnownFolderPath(windows.FOLDERID_Downloads, 0)
	if err != nil || d == "" {
		d = filepath.Join(os.Getenv("USERPROFILE"), "Downloads")
	}
	return filepath.Join(d, "Tether")
}

// ---------- data dir, DPAPI ----------

func DataDir() string {
	return filepath.Join(os.Getenv("APPDATA"), "Tether")
}

func Protect(b []byte) ([]byte, error) {
	if len(b) == 0 {
		return b, nil
	}
	in := windows.DataBlob{Size: uint32(len(b)), Data: &b[0]}
	var out windows.DataBlob
	if err := windows.CryptProtectData(&in, nil, nil, 0, nil, 0x1 /*UI_FORBIDDEN*/, &out); err != nil {
		return nil, err
	}
	defer windows.LocalFree(windows.Handle(unsafe.Pointer(out.Data)))
	return append([]byte(nil), unsafe.Slice(out.Data, out.Size)...), nil
}

func Unprotect(b []byte) ([]byte, error) {
	if len(b) == 0 {
		return b, nil
	}
	in := windows.DataBlob{Size: uint32(len(b)), Data: &b[0]}
	var out windows.DataBlob
	if err := windows.CryptUnprotectData(&in, nil, nil, 0, nil, 0x1, &out); err != nil {
		return nil, err
	}
	defer windows.LocalFree(windows.Handle(unsafe.Pointer(out.Data)))
	return append([]byte(nil), unsafe.Slice(out.Data, out.Size)...), nil
}

// ---------- launch at login ----------

const runKey = `Software\Microsoft\Windows\CurrentVersion\Run`

func SetAutostart(on bool) error {
	k, err := registry.OpenKey(registry.CURRENT_USER, runKey, registry.SET_VALUE)
	if err != nil {
		return err
	}
	defer k.Close()
	if !on {
		err := k.DeleteValue("Tether")
		if err == registry.ErrNotExist {
			return nil
		}
		return err
	}
	exe, err := os.Executable()
	if err != nil {
		return err
	}
	return k.SetStringValue("Tether", `"`+exe+`" --background`)
}

// ---------- file picker ----------

type openFileName struct {
	StructSize    uint32
	Owner         uintptr
	Instance      uintptr
	Filter        *uint16
	CustomFilter  *uint16
	MaxCustFilter uint32
	FilterIndex   uint32
	File          *uint16
	MaxFile       uint32
	FileTitle     *uint16
	MaxFileTitle  uint32
	InitialDir    *uint16
	Title         *uint16
	Flags         uint32
	FileOffset    uint16
	FileExtension uint16
	DefExt        *uint16
	CustData      uintptr
	FnHook        uintptr
	TemplateName  *uint16
	Reserved      uintptr
	Reserved2     uint32
	FlagsEx       uint32
}

// pickFiles must run on the UI thread.
func pickFiles(owner uintptr) []string {
	buf := make([]uint16, 65536)
	filter, _ := windows.UTF16FromString("All files\x00*.*\x00")
	filter = append(filter, 0)
	ofn := openFileName{StructSize: uint32(unsafe.Sizeof(openFileName{})), Owner: owner,
		Filter: &filter[0], File: &buf[0], MaxFile: uint32(len(buf)), Title: str16("Send files with Tether"),
		Flags: 0x00080000 | 0x00000200 | 0x00001000 | 0x00000008 /*EXPLORER|ALLOWMULTISELECT|FILEMUSTEXIST|NOCHANGEDIR*/}
	if r, _, _ := pGetOpenFileNameW.Call(uintptr(unsafe.Pointer(&ofn))); r == 0 {
		return nil
	}
	var parts []string
	start := 0
	for i := 0; i < len(buf); i++ {
		if buf[i] == 0 {
			if i == start {
				break
			}
			parts = append(parts, windows.UTF16ToString(buf[start:i]))
			start = i + 1
		}
	}
	if len(parts) == 1 {
		return parts
	}
	var out []string
	for _, f := range parts[1:] {
		out = append(out, filepath.Join(parts[0], f))
	}
	return out
}
