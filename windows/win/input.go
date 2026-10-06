//go:build windows

package win

import (
	"sync"
	"unsafe"

	"tether/core/keys"
	"tether/core/proto"
)

// INPUT layouts for 64-bit Windows (amd64 / arm64): 40 bytes each.
type mouseInput struct {
	Type      uint32
	_         uint32
	Dx, Dy    int32
	MouseData uint32
	Flags     uint32
	Time      uint32
	_         uint32
	Extra     uintptr
}

type keybdInput struct {
	Type  uint32
	_     uint32
	Vk    uint16
	Scan  uint16
	Flags uint32
	Time  uint32
	_     uint32
	Extra uintptr
	_     [8]byte
}

const (
	inputMouse    = 0
	inputKeyboard = 1

	mMove       = 0x0001
	mLeftDown   = 0x0002
	mLeftUp     = 0x0004
	mRightDown  = 0x0008
	mRightUp    = 0x0010
	mMiddleDown = 0x0020
	mMiddleUp   = 0x0040
	mWheel      = 0x0800
	mHWheel     = 0x1000
	mVirtual    = 0x4000
	mAbsolute   = 0x8000

	kExtended = 0x0001
	kUp       = 0x0002
	kScan     = 0x0008
)

// Numeric keypad keys are sent as VK_NUMPADx so they type digits regardless of NumLock handling.
var numpadVK = map[uint16]uint16{
	0x54: 0x6F, 0x55: 0x6A, 0x56: 0x6D, 0x57: 0x6B,
	0x59: 0x61, 0x5A: 0x62, 0x5B: 0x63, 0x5C: 0x64, 0x5D: 0x65, 0x5E: 0x66, 0x5F: 0x67,
	0x60: 0x68, 0x61: 0x69, 0x62: 0x60, 0x63: 0x6E,
}

type injector struct {
	mu      sync.Mutex
	pressed map[uint16]bool
	buttons map[byte]bool
}

func newInjector() *injector {
	return &injector{pressed: map[uint16]bool{}, buttons: map[byte]bool{}}
}

func sysMetric(i int) int32 {
	r, _, _ := pGetSystemMetrics.Call(uintptr(i))
	return int32(r)
}

func sendMouse(in mouseInput) {
	in.Type = inputMouse
	pSendInput.Call(1, uintptr(unsafe.Pointer(&in)), unsafe.Sizeof(in))
}

func sendKey(in keybdInput) {
	in.Type = inputKeyboard
	pSendInput.Call(1, uintptr(unsafe.Pointer(&in)), unsafe.Sizeof(in))
}

func (j *injector) Mouse(display int, ev proto.MouseEvent) {
	r, ok := monitorRect(display)
	if !ok {
		return
	}
	mw, mh := int64(r.Right-r.Left), int64(r.Bottom-r.Top)
	px := int64(r.Left) + int64(ev.X)*(mw-1)/65535
	py := int64(r.Top) + int64(ev.Y)*(mh-1)/65535
	vx, vy := int64(sysMetric(76)), int64(sysMetric(77))
	vw, vh := int64(sysMetric(78)), int64(sysMetric(79))
	if vw < 2 || vh < 2 {
		return
	}
	ax := int32((px - vx) * 65535 / (vw - 1))
	ay := int32((py - vy) * 65535 / (vh - 1))
	base := mouseInput{Dx: ax, Dy: ay, Flags: mMove | mAbsolute | mVirtual}
	switch ev.Kind {
	case proto.MouseMove:
		sendMouse(base)
	case proto.MouseDown, proto.MouseUp:
		down := ev.Kind == proto.MouseDown
		var f uint32
		switch ev.Button {
		case 1:
			f = map[bool]uint32{true: mRightDown, false: mRightUp}[down]
		case 2:
			f = map[bool]uint32{true: mMiddleDown, false: mMiddleUp}[down]
		default:
			f = map[bool]uint32{true: mLeftDown, false: mLeftUp}[down]
		}
		base.Flags |= f
		sendMouse(base)
		j.mu.Lock()
		j.buttons[ev.Button] = down
		j.mu.Unlock()
	case proto.MouseWheel:
		sendMouse(base)
		if ev.DY != 0 {
			sendMouse(mouseInput{Flags: mWheel, MouseData: uint32(int32(ev.DY))})
		}
		if ev.DX != 0 {
			sendMouse(mouseInput{Flags: mHWheel, MouseData: uint32(int32(ev.DX))})
		}
	}
}

func (j *injector) Key(ev proto.KeyEvent) {
	w, ok := keys.HIDToWin[ev.HID]
	if !ok {
		return
	}
	var in keybdInput
	if vk, ok := numpadVK[ev.HID]; ok {
		w = keys.Win{VK: vk, Scan: w.Scan, Ext: w.Ext}
	}
	if w.VK != 0 {
		in.Vk = w.VK
		if w.Scan != 0 {
			in.Scan = w.Scan
		} else {
			sc, _, _ := pMapVirtualKeyW.Call(uintptr(w.VK), 0)
			in.Scan = uint16(sc)
		}
		if w.Ext {
			in.Flags |= kExtended
		}
	} else {
		// Send the scan code together with the virtual key that the foreground
		// window's keyboard layout assigns to it (works everywhere, incl. Wine).
		sc := uintptr(w.Scan)
		if w.Ext {
			sc |= 0xE000
		}
		fg, _, _ := pGetForegroundWindow.Call()
		tid, _, _ := pGetWindowThreadProcessId.Call(fg, 0)
		hkl, _, _ := pGetKeyboardLayout.Call(tid)
		vk, _, _ := pMapVirtualKeyExW.Call(sc, 3 /*MAPVK_VSC_TO_VK_EX*/, hkl)
		in.Scan = w.Scan
		if vk != 0 {
			in.Vk = uint16(vk)
		} else {
			in.Flags |= kScan
		}
		if w.Ext {
			in.Flags |= kExtended
		}
	}
	if !ev.Down {
		in.Flags |= kUp
	}
	sendKey(in)
	j.mu.Lock()
	if ev.Down {
		j.pressed[ev.HID] = true
	} else {
		delete(j.pressed, ev.HID)
	}
	j.mu.Unlock()
}

// ReleaseAll lifts any key or button still held when a session ends.
func (j *injector) ReleaseAll() {
	j.mu.Lock()
	var ks []uint16
	for k := range j.pressed {
		ks = append(ks, k)
	}
	var bs []byte
	for b, d := range j.buttons {
		if d {
			bs = append(bs, b)
		}
	}
	j.pressed = map[uint16]bool{}
	j.buttons = map[byte]bool{}
	j.mu.Unlock()
	for _, k := range ks {
		j.Key(proto.KeyEvent{Down: false, HID: k})
	}
	for _, b := range bs {
		f := map[byte]uint32{0: mLeftUp, 1: mRightUp, 2: mMiddleUp}[b]
		sendMouse(mouseInput{Flags: f})
	}
}
