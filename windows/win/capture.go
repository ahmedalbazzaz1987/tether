//go:build windows

package win

import (
	"errors"
	"fmt"
	"sync"
	"unsafe"

	"golang.org/x/sys/windows"

	"tether/core/proto"
	"tether/core/video"
)

type monitor struct {
	rect    RECT
	primary bool
	device  string
}

type monitorInfoEx struct {
	Size    uint32
	Monitor RECT
	Work    RECT
	Flags   uint32
	Device  [32]uint16
}

var (
	monMu     sync.Mutex
	monList   []monitor
	monEnumCB = windows.NewCallback(func(hmon, hdc uintptr, r *RECT, lp uintptr) uintptr {
		var mi monitorInfoEx
		mi.Size = uint32(unsafe.Sizeof(mi))
		pGetMonitorInfoW.Call(hmon, uintptr(unsafe.Pointer(&mi)))
		monList = append(monList, monitor{rect: mi.Monitor, primary: mi.Flags&1 != 0, device: windows.UTF16ToString(mi.Device[:])})
		return 1
	})
)

func monitors() []monitor {
	monMu.Lock()
	defer monMu.Unlock()
	monList = nil
	pEnumDisplayMonitors.Call(0, 0, monEnumCB, 0)
	out := append([]monitor(nil), monList...)
	return out
}

func displays() []proto.Display {
	var out []proto.Display
	for i, m := range monitors() {
		out = append(out, proto.Display{ID: i, Name: fmt.Sprintf("Display %d", i+1),
			W: int(m.rect.Right - m.rect.Left), H: int(m.rect.Bottom - m.rect.Top), Primary: m.primary})
	}
	return out
}

func monitorRect(i int) (RECT, bool) {
	ms := monitors()
	if len(ms) == 0 {
		return RECT{}, false
	}
	if i < 0 || i >= len(ms) {
		i = 0
	}
	return ms[i].rect, true
}

type bitmapInfoHeader struct {
	Size          uint32
	Width         int32
	Height        int32
	Planes        uint16
	BitCount      uint16
	Compression   uint32
	SizeImage     uint32
	XPelsPerMeter int32
	YPelsPerMeter int32
	ClrUsed       uint32
	ClrImportant  uint32
}

type cursorInfo struct {
	Size    uint32
	Flags   uint32
	Cursor  uintptr
	ScreenX int32
	ScreenY int32
}

type iconInfo struct {
	FIcon    int32
	XHotspot uint32
	YHotspot uint32
	HbmMask  uintptr
	HbmColor uintptr
}

// gdiCapturer grabs a monitor with BitBlt into a reusable DIB section.
type gdiCapturer struct {
	mu     sync.Mutex
	memDC  uintptr
	bmp    uintptr
	old    uintptr
	bits   unsafe.Pointer
	w, h   int
	scaled bool
}

const maxWidth = 2560 // larger monitors are scaled down by half for speed

func (c *gdiCapturer) ensure(screenDC uintptr, w, h int) error {
	if c.memDC != 0 && c.w == w && c.h == h {
		return nil
	}
	c.release()
	c.memDC, _, _ = pCreateCompatibleDC.Call(screenDC)
	if c.memDC == 0 {
		return errors.New("CreateCompatibleDC failed")
	}
	bi := bitmapInfoHeader{Size: 40, Width: int32(w), Height: -int32(h), Planes: 1, BitCount: 32}
	var bits unsafe.Pointer
	c.bmp, _, _ = pCreateDIBSection.Call(screenDC, uintptr(unsafe.Pointer(&bi)), 0, uintptr(unsafe.Pointer(&bits)), 0, 0)
	if c.bmp == 0 {
		pDeleteDC.Call(c.memDC)
		c.memDC = 0
		return errors.New("CreateDIBSection failed")
	}
	c.old, _, _ = pSelectObject.Call(c.memDC, c.bmp)
	c.bits, c.w, c.h = bits, w, h
	return nil
}

func (c *gdiCapturer) release() {
	if c.memDC != 0 {
		pSelectObject.Call(c.memDC, c.old)
		pDeleteObject.Call(c.bmp)
		pDeleteDC.Call(c.memDC)
		c.memDC, c.bmp = 0, 0
	}
}

func (c *gdiCapturer) Capture(display int) (video.Frame, error) {
	c.mu.Lock()
	defer c.mu.Unlock()
	r, ok := monitorRect(display)
	if !ok {
		return video.Frame{}, errors.New("no display")
	}
	mw, mh := int(r.Right-r.Left), int(r.Bottom-r.Top)
	w, h := mw, mh
	scale := 1
	if mw > maxWidth {
		scale = 2
		w, h = mw/2, mh/2
	}
	w &^= 1
	h &^= 1
	screenDC, _, _ := pGetDC.Call(0)
	if screenDC == 0 {
		return video.Frame{}, errors.New("GetDC failed")
	}
	defer pReleaseDC.Call(0, screenDC)
	if err := c.ensure(screenDC, w, h); err != nil {
		return video.Frame{}, err
	}
	const SRCCOPY = 0x00CC0020
	var ok2 uintptr
	if scale == 1 {
		ok2, _, _ = pBitBlt.Call(c.memDC, 0, 0, uintptr(w), uintptr(h), screenDC, uintptr(r.Left), uintptr(r.Top), SRCCOPY)
	} else {
		pSetStretchBltMode.Call(c.memDC, 4) // HALFTONE
		pSetBrushOrgEx.Call(c.memDC, 0, 0, 0)
		ok2, _, _ = pStretchBlt.Call(c.memDC, 0, 0, uintptr(w), uintptr(h), screenDC, uintptr(r.Left), uintptr(r.Top), uintptr(mw), uintptr(mh), SRCCOPY)
	}
	if ok2 == 0 {
		// Usually the secure desktop (UAC prompt / lock screen) is active.
		return video.Frame{}, errors.New("screen not accessible")
	}
	c.drawCursor(r, scale)
	pGdiFlush.Call()
	pix := unsafe.Slice((*byte)(c.bits), w*h*4)
	return video.Frame{W: w, H: h, Stride: w * 4, Pix: pix}, nil
}

func (c *gdiCapturer) drawCursor(r RECT, scale int) {
	ci := cursorInfo{Size: uint32(unsafe.Sizeof(cursorInfo{}))}
	if ret, _, _ := pGetCursorInfo.Call(uintptr(unsafe.Pointer(&ci))); ret == 0 || ci.Flags&1 == 0 || ci.Cursor == 0 {
		return
	}
	var ii iconInfo
	if ret, _, _ := pGetIconInfo.Call(ci.Cursor, uintptr(unsafe.Pointer(&ii))); ret == 0 {
		return
	}
	if ii.HbmMask != 0 {
		pDeleteObject.Call(ii.HbmMask)
	}
	if ii.HbmColor != 0 {
		pDeleteObject.Call(ii.HbmColor)
	}
	x := (int(ci.ScreenX)-int(r.Left))/scale - int(ii.XHotspot)
	y := (int(ci.ScreenY)-int(r.Top))/scale - int(ii.YHotspot)
	if x < -64 || y < -64 || x > c.w || y > c.h {
		return
	}
	pDrawIconEx.Call(c.memDC, uintptr(int32(x)), uintptr(int32(y)), ci.Cursor, 0, 0, 0, 0, 0x0003 /*DI_NORMAL*/)
}
