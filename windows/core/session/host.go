package session

import (
	"encoding/binary"
	"sync"
	"time"

	"tether/core/proto"
	"tether/core/video"
)

// HostPlatform is implemented per OS.
type HostPlatform interface {
	OSName() string
	MachineName() string
	Displays() []proto.Display
	Capture(display int) (video.Frame, error)
	Mouse(display int, ev proto.MouseEvent)
	Key(ev proto.KeyEvent)
	ReleaseAll()
	Clipboard() Clipboard
	DownloadsDir() string
}

type Host struct {
	common
	plat       HostPlatform
	ViewerName string

	vmu      sync.Mutex
	display  int
	enc      *video.Encoder
	inflight int
	lastAck  time.Time
	viewerOK bool
}

// NewHost wraps an authenticated channel.
func NewHost(ch *proto.Channel, viewerName string, plat HostPlatform, ev Events) *Host {
	h := &Host{plat: plat, ViewerName: viewerName, enc: video.NewEncoder("balanced")}
	h.common = newCommon(ch, ev, plat.Clipboard(), plat.DownloadsDir(), 0)
	for i, d := range plat.Displays() {
		if d.Primary {
			h.display = i
		}
	}
	return h
}

func (h *Host) Kind() string { return h.ch.Kind() }

// Run blocks until the session ends.
func (h *Host) Run() {
	disp := h.plat.Displays()
	err := h.ch.SendJSON(proto.Control{T: "hello", OS: h.plat.OSName(), Name: h.plat.MachineName(),
		Version: AppVersion, Displays: disp, Display: proto.IntPtr(h.display)})
	if err != nil {
		h.end("Connection lost")
		return
	}
	go h.clipLoop()
	go h.pingLoop()
	go h.videoLoop()
	for {
		typ, b, err := h.ch.Recv()
		if err != nil {
			h.end("Connection lost")
			break
		}
		switch typ {
		case proto.MsgMouse:
			if m, ok := proto.DecodeMouse(b); ok {
				h.vmu.Lock()
				d := h.display
				h.vmu.Unlock()
				h.plat.Mouse(d, m)
			}
		case proto.MsgKey:
			if k, ok := proto.DecodeKey(b); ok {
				h.plat.Key(k)
			}
		case proto.MsgAck:
			if len(b) >= 4 {
				_ = binary.BigEndian.Uint32(b)
				h.vmu.Lock()
				if h.inflight > 0 {
					h.inflight--
				}
				h.lastAck = time.Now()
				h.vmu.Unlock()
			}
		case proto.MsgJSON:
			m, err := proto.ParseJSON(b)
			if err != nil {
				continue
			}
			if h.handleCommon(typ, b, &m) {
				continue
			}
			switch m.T {
			case "hello":
				h.vmu.Lock()
				h.viewerOK = true
				h.vmu.Unlock()
			case "refresh":
				h.enc.Invalidate()
			case "quality":
				h.enc.SetQuality(m.Q)
			case "display":
				if m.ID != nil && int(*m.ID) >= 0 && int(*m.ID) < len(h.plat.Displays()) {
					h.vmu.Lock()
					h.display = int(*m.ID)
					h.vmu.Unlock()
					h.enc.Invalidate()
				}
			}
		default:
			h.handleCommon(typ, b, nil)
		}
	}
	h.plat.ReleaseAll()
}

func (h *Host) videoLoop() {
	const fps = 30
	t := time.NewTicker(time.Second / fps)
	defer t.Stop()
	for {
		select {
		case <-h.done:
			return
		case <-t.C:
		}
		h.vmu.Lock()
		ok := h.viewerOK
		if h.inflight >= 2 && time.Since(h.lastAck) > 4*time.Second {
			h.inflight = 0 // viewer stalled; resync
			h.enc.Invalidate()
		}
		busy := h.inflight >= 2
		d := h.display
		h.vmu.Unlock()
		if !ok || busy {
			continue
		}
		f, err := h.plat.Capture(d)
		if err != nil {
			time.Sleep(200 * time.Millisecond)
			continue
		}
		payload, _ := h.enc.Encode(f)
		if payload == nil {
			continue
		}
		h.vmu.Lock()
		if h.inflight == 0 {
			h.lastAck = time.Now()
		}
		h.inflight++
		h.vmu.Unlock()
		if err := h.ch.Send(proto.MsgVideo, payload); err != nil {
			h.end("Connection lost")
			return
		}
	}
}
