// Package relay talks to the Tether Cloudflare relay (PROTOCOL §5) and handles direct LAN dialing.
package relay

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"net/url"
	"strings"
	"sync"
	"time"

	"github.com/coder/websocket"

	"tether/core/proto"
)

// BaseURL normalises what the user typed into a wss:// base URL.
func BaseURL(s string) (string, error) {
	s = strings.TrimSpace(s)
	s = strings.TrimRight(s, "/")
	if s == "" {
		return "", errors.New("no relay configured – add your relay address in Settings")
	}
	switch {
	case strings.HasPrefix(s, "https://"):
		s = "wss://" + s[8:]
	case strings.HasPrefix(s, "http://"):
		s = "ws://" + s[7:]
	case strings.HasPrefix(s, "wss://"), strings.HasPrefix(s, "ws://"):
	default:
		s = "wss://" + s
	}
	if _, err := url.Parse(s); err != nil {
		return "", err
	}
	return s, nil
}

type notice struct {
	T      string   `json:"t"`
	SID    string   `json:"sid"`
	LAN    []string `json:"lan"`
	Reason string   `json:"reason"`
}

func dial(ctx context.Context, u string) (*websocket.Conn, error) {
	ctx, cancel := context.WithTimeout(ctx, 12*time.Second)
	defer cancel()
	c, resp, err := websocket.Dial(ctx, u, nil)
	if err != nil {
		if resp != nil && resp.StatusCode == 403 {
			return nil, errors.New("relay refused this ID (it belongs to another computer)")
		}
		return nil, err
	}
	return c, nil
}

// ---------------- host ----------------

type Host struct {
	Relay      string
	ID         string
	Secret     string
	LAN        func() []string
	OnIncoming func(proto.Transport)
	OnStatus   func(online bool, msg string)

	mu     sync.Mutex
	cancel context.CancelFunc
}

func (h *Host) Start() {
	h.mu.Lock()
	defer h.mu.Unlock()
	if h.cancel != nil {
		h.cancel()
	}
	ctx, cancel := context.WithCancel(context.Background())
	h.cancel = cancel
	go h.loop(ctx)
}

func (h *Host) Stop() {
	h.mu.Lock()
	defer h.mu.Unlock()
	if h.cancel != nil {
		h.cancel()
		h.cancel = nil
	}
}

func (h *Host) status(on bool, msg string) {
	if h.OnStatus != nil {
		h.OnStatus(on, msg)
	}
}

func (h *Host) loop(ctx context.Context) {
	backoff := time.Second
	for ctx.Err() == nil {
		base, err := BaseURL(h.Relay)
		if err != nil {
			h.status(false, err.Error())
			return
		}
		q := url.Values{"id": {h.ID}, "secret": {h.Secret}}
		if h.LAN != nil {
			q.Set("lan", strings.Join(h.LAN(), ","))
		}
		c, err := dial(ctx, base+"/host?"+q.Encode())
		if err != nil {
			h.status(false, "Relay unreachable: "+short(err))
			select {
			case <-ctx.Done():
				return
			case <-time.After(backoff):
			}
			backoff = min(backoff*2, 30*time.Second)
			continue
		}
		backoff = time.Second
		h.status(true, "Ready for connections")
		h.serve(ctx, c, base)
		if ctx.Err() == nil {
			h.status(false, "Reconnecting to relay…")
			time.Sleep(time.Second)
		}
	}
}

func (h *Host) serve(ctx context.Context, c *websocket.Conn, base string) {
	defer c.CloseNow()
	cctx, cancel := context.WithCancel(ctx)
	defer cancel()
	go func() {
		t := time.NewTicker(25 * time.Second)
		defer t.Stop()
		for {
			select {
			case <-cctx.Done():
				return
			case <-t.C:
				wctx, wc := context.WithTimeout(cctx, 10*time.Second)
				err := c.Write(wctx, websocket.MessageText, []byte("ping"))
				wc()
				if err != nil {
					cancel()
					return
				}
			}
		}
	}()
	for {
		rctx, rc := context.WithTimeout(cctx, 75*time.Second)
		typ, b, err := c.Read(rctx)
		rc()
		if err != nil {
			return
		}
		if typ != websocket.MessageText {
			continue
		}
		var n notice
		if json.Unmarshal(b, &n) != nil {
			continue
		}
		if n.T == "incoming" && n.SID != "" {
			go h.accept(ctx, base, n.SID)
		}
	}
}

func (h *Host) accept(ctx context.Context, base, sid string) {
	q := url.Values{"id": {h.ID}, "secret": {h.Secret}, "sid": {sid}}
	c, err := dial(ctx, base+"/accept?"+q.Encode())
	if err != nil {
		return
	}
	if h.OnIncoming != nil {
		h.OnIncoming(proto.NewWS(c))
	}
}

// ---------------- viewer ----------------

// DialID connects to a host by ID through the relay, preferring a direct LAN path.
func DialID(ctx context.Context, relayURL, id string) (proto.Transport, error) {
	base, err := BaseURL(relayURL)
	if err != nil {
		return nil, err
	}
	c, err := dial(ctx, base+"/connect?"+url.Values{"id": {id}}.Encode())
	if err != nil {
		return nil, fmt.Errorf("cannot reach relay: %s", short(err))
	}
	fail := func(e error) (proto.Transport, error) { c.CloseNow(); return nil, e }
	read := func(d time.Duration) (notice, error) {
		rctx, cancel := context.WithTimeout(ctx, d)
		defer cancel()
		for {
			typ, b, err := c.Read(rctx)
			if err != nil {
				return notice{}, err
			}
			if typ == websocket.MessageText {
				var n notice
				if json.Unmarshal(b, &n) == nil {
					return n, nil
				}
			}
		}
	}
	n, err := read(10 * time.Second)
	if err != nil {
		return fail(errors.New("relay did not answer"))
	}
	if n.T == "error" {
		if n.Reason == "offline" {
			return fail(errors.New("that computer is offline or the ID is wrong"))
		}
		return fail(errors.New(n.Reason))
	}
	if len(n.LAN) > 0 {
		if t := TryLAN(n.LAN, 900*time.Millisecond); t != nil {
			c.Close(websocket.StatusNormalClosure, "direct")
			return t, nil
		}
	}
	wctx, wc := context.WithTimeout(ctx, 5*time.Second)
	err = c.Write(wctx, websocket.MessageText, []byte(`{"t":"relay"}`))
	wc()
	if err != nil {
		return fail(err)
	}
	n, err = read(15 * time.Second)
	if err != nil || n.T != "ready" {
		return fail(errors.New("the remote computer did not respond"))
	}
	return proto.NewWS(c), nil
}

// TryLAN dials all candidates in parallel and returns the first that connects.
func TryLAN(addrs []string, timeout time.Duration) proto.Transport {
	type res struct{ c net.Conn }
	ch := make(chan res, len(addrs))
	for _, a := range addrs {
		go func(a string) {
			c, err := net.DialTimeout("tcp", a, timeout)
			if err != nil {
				ch <- res{}
				return
			}
			ch <- res{c}
		}(a)
	}
	var win net.Conn
	for range addrs {
		r := <-ch
		if r.c != nil {
			if win == nil {
				win = r.c
			} else {
				r.c.Close()
			}
		}
	}
	if win == nil {
		return nil
	}
	return proto.NewTCP(win)
}

// DialDirect connects to host:port (default port 47800).
func DialDirect(addr string) (proto.Transport, error) {
	if _, _, err := net.SplitHostPort(addr); err != nil {
		addr = net.JoinHostPort(addr, "47800")
	}
	c, err := net.DialTimeout("tcp", addr, 6*time.Second)
	if err != nil {
		return nil, fmt.Errorf("cannot reach %s", addr)
	}
	return proto.NewTCP(c), nil
}

// LocalIPv4 lists private IPv4 addresses of this machine.
func LocalIPv4() []string {
	var out []string
	ifs, _ := net.Interfaces()
	for _, i := range ifs {
		if i.Flags&net.FlagUp == 0 || i.Flags&net.FlagLoopback != 0 {
			continue
		}
		addrs, _ := i.Addrs()
		for _, a := range addrs {
			if ipn, ok := a.(*net.IPNet); ok {
				if ip4 := ipn.IP.To4(); ip4 != nil && ip4.IsPrivate() {
					out = append(out, ip4.String())
				}
			}
		}
	}
	return out
}

func short(err error) string {
	s := err.Error()
	if len(s) > 90 {
		s = s[:90] + "…"
	}
	return s
}
