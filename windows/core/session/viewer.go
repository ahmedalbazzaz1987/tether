package session

import (
	"context"
	"errors"
	"regexp"
	"strings"
	"time"

	"tether/core/proto"
	"tether/core/relay"
)

type ViewerEvents struct {
	Events
	OnHello func(proto.Control)
	OnVideo func(payload []byte) // must eventually call Ack
}

type Viewer struct {
	common
	vev      ViewerEvents
	Remote   proto.ServerInfo
	RemoteOS string
}

var idRe = regexp.MustCompile(`^\d{9}$`)

// NormalizeTarget strips spaces from IDs. Returns (value, isID).
func NormalizeTarget(s string) (string, bool) {
	s = strings.TrimSpace(s)
	compact := strings.NewReplacer(" ", "", "-", "").Replace(s)
	if idRe.MatchString(compact) {
		return compact, true
	}
	return s, false
}

// Dial opens a transport to target (9-digit ID via relay, or host[:port] directly).
func Dial(ctx context.Context, target, relayURL string) (proto.Transport, error) {
	t, isID := NormalizeTarget(target)
	if isID {
		// Same network? Find it directly first — no relay needed.
		if addr, ok := relay.Discover(t, 900*time.Millisecond); ok {
			if tr, err := relay.DialDirect(addr); err == nil {
				return tr, nil
			}
		}
		if strings.TrimSpace(relayURL) == "" {
			return nil, errors.New("couldn't find that ID on your local network. To connect over the internet, add your relay address in Settings — or enter the computer's IP address instead")
		}
		return relay.DialID(ctx, relayURL, t)
	}
	return relay.DialDirect(t)
}

// Connect authenticates over t. verify implements host-key pinning.
func Connect(t proto.Transport, myName, password string, verify func(proto.ServerInfo) error,
	clip Clipboard, downloads string, ev ViewerEvents) (*Viewer, error) {
	ch, info, err := proto.ClientHandshake(t, myName, password, verify)
	if err != nil {
		t.Close()
		return nil, err
	}
	v := &Viewer{vev: ev, Remote: *info}
	v.common = newCommon(ch, ev.Events, clip, downloads, 1_000_000)
	return v, nil
}

func (v *Viewer) Kind() string { return v.ch.Kind() }

// Run blocks until the session ends.
func (v *Viewer) Run(myOS, myName string) {
	v.ch.SendJSON(proto.Control{T: "hello", OS: myOS, Name: myName, Version: AppVersion})
	go v.clipLoop()
	go v.pingLoop()
	for {
		typ, b, err := v.ch.Recv()
		if err != nil {
			v.end("Connection lost")
			return
		}
		switch typ {
		case proto.MsgVideo:
			if v.vev.OnVideo != nil {
				v.vev.OnVideo(b)
			}
		case proto.MsgJSON:
			m, err := proto.ParseJSON(b)
			if err != nil {
				continue
			}
			if v.handleCommon(typ, b, &m) {
				continue
			}
			if m.T == "hello" {
				v.RemoteOS = m.OS
				if v.vev.OnHello != nil {
					v.vev.OnHello(m)
				}
			}
		default:
			v.handleCommon(typ, b, nil)
		}
	}
}

func (v *Viewer) Ack(seq uint32)           { v.ch.Send(proto.MsgAck, proto.EncodeU32(seq)) }
func (v *Viewer) Mouse(m proto.MouseEvent) { v.ch.Send(proto.MsgMouse, m.Encode()) }
func (v *Viewer) Key(k proto.KeyEvent)     { v.ch.Send(proto.MsgKey, k.Encode()) }
func (v *Viewer) Refresh()                 { v.ch.SendJSON(proto.Control{T: "refresh"}) }
func (v *Viewer) SetQuality(q string)      { v.ch.SendJSON(proto.Control{T: "quality", Q: q}) }
func (v *Viewer) SelectDisplay(id int) {
	v.ch.SendJSON(proto.Control{T: "display", ID: proto.I64Ptr(int64(id))})
}
