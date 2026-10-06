package app

import (
	"context"
	"crypto/rand"
	"embed"
	"encoding/hex"
	"encoding/json"
	"io/fs"
	"net"
	"net/http"
	"strings"
	"sync"
	"time"

	"github.com/coder/websocket"
)

//go:embed web
var webFS embed.FS

// Hub serves the local UI (127.0.0.1 only, random port, secret token) and
// pushes state, events and video frames to it over a WebSocket.
type Hub struct {
	app   *App
	token string
	addr  string

	mu      sync.Mutex
	clients map[*client]struct{}
}

type client struct {
	c    *websocket.Conn
	text chan []byte
	bin  chan []byte
}

func newHub(a *App) *Hub {
	b := make([]byte, 16)
	rand.Read(b)
	return &Hub{app: a, token: hex.EncodeToString(b), clients: map[*client]struct{}{}}
}

// Serve starts the HTTP server and returns the URL for the webview.
func (h *Hub) Serve() (string, error) {
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		return "", err
	}
	h.addr = ln.Addr().String()
	sub, _ := fs.Sub(webFS, "web")
	files := http.FileServer(http.FS(sub))
	mux := http.NewServeMux()
	mux.HandleFunc("/ws", h.ws)
	mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		if !h.hostOK(r) {
			http.Error(w, "forbidden", 403)
			return
		}
		w.Header().Set("Cache-Control", "no-store")
		w.Header().Set("Content-Security-Policy", "default-src 'self'; connect-src 'self' ws://"+h.addr+"; img-src 'self' blob: data:; style-src 'self' 'unsafe-inline'")
		files.ServeHTTP(w, r)
	})
	go http.Serve(ln, mux)
	return "http://" + h.addr + "/index.html#" + h.token, nil
}

func (h *Hub) hostOK(r *http.Request) bool {
	return r.Host == h.addr
}

func (h *Hub) ws(w http.ResponseWriter, r *http.Request) {
	if !h.hostOK(r) || r.URL.Query().Get("token") != h.token {
		http.Error(w, "forbidden", 403)
		return
	}
	c, err := websocket.Accept(w, r, &websocket.AcceptOptions{OriginPatterns: []string{h.addr}})
	if err != nil {
		return
	}
	c.SetReadLimit(1 << 20)
	cl := &client{c: c, text: make(chan []byte, 256), bin: make(chan []byte, 4)}
	h.mu.Lock()
	h.clients[cl] = struct{}{}
	h.mu.Unlock()
	ctx, cancel := context.WithCancel(context.Background())
	defer func() {
		cancel()
		h.mu.Lock()
		delete(h.clients, cl)
		h.mu.Unlock()
		c.CloseNow()
	}()
	go func() {
		for {
			var msg []byte
			typ := websocket.MessageText
			select {
			case <-ctx.Done():
				return
			case msg = <-cl.text:
			case msg = <-cl.bin:
				typ = websocket.MessageBinary
			}
			wctx, wc := context.WithTimeout(ctx, 10*time.Second)
			err := c.Write(wctx, typ, msg)
			wc()
			if err != nil {
				cancel()
				return
			}
		}
	}()
	if st, err := json.Marshal(h.app.State()); err == nil {
		cl.text <- st
	}
	for {
		_, b, err := c.Read(ctx)
		if err != nil {
			return
		}
		var cmd Cmd
		if json.Unmarshal(b, &cmd) == nil {
			h.app.Handle(cmd)
		}
	}
}

// Event broadcasts a JSON event (drops if a client is badly behind).
func (h *Hub) Event(v any) {
	b, err := json.Marshal(v)
	if err != nil {
		return
	}
	h.mu.Lock()
	defer h.mu.Unlock()
	for cl := range h.clients {
		select {
		case cl.text <- b:
		default:
		}
	}
}

// Binary sends a video payload. Blocks briefly so frames are not dropped
// (the host only sends when the viewer has acknowledged earlier frames).
func (h *Hub) Binary(b []byte) {
	h.mu.Lock()
	cls := make([]*client, 0, len(h.clients))
	for cl := range h.clients {
		cls = append(cls, cl)
	}
	h.mu.Unlock()
	for _, cl := range cls {
		select {
		case cl.bin <- b:
		case <-time.After(2 * time.Second):
		}
	}
}

var _ = strings.TrimSpace
