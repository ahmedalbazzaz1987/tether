package proto

import (
	"bufio"
	"context"
	"encoding/binary"
	"errors"
	"io"
	"net"
	"sync"
	"time"

	"github.com/coder/websocket"
)

// Transport carries opaque packets (see PROTOCOL.md §1).
type Transport interface {
	Send(p []byte) error
	Recv() ([]byte, error)
	Close() error
	Kind() string // "direct" or "relay"
}

const maxPacket = 16 << 20

// ---- TCP ----

type tcpTransport struct {
	c   net.Conn
	r   *bufio.Reader
	wmu sync.Mutex
}

func NewTCP(c net.Conn) Transport {
	if tc, ok := c.(*net.TCPConn); ok {
		tc.SetNoDelay(true)
		tc.SetKeepAlive(true)
		tc.SetKeepAlivePeriod(15 * time.Second)
	}
	return &tcpTransport{c: c, r: bufio.NewReaderSize(c, 256<<10)}
}

func (t *tcpTransport) Send(p []byte) error {
	t.wmu.Lock()
	defer t.wmu.Unlock()
	var h [4]byte
	binary.BigEndian.PutUint32(h[:], uint32(len(p)))
	t.c.SetWriteDeadline(time.Now().Add(30 * time.Second))
	if _, err := t.c.Write(append(h[:], p...)); err != nil {
		return err
	}
	return nil
}

func (t *tcpTransport) Recv() ([]byte, error) {
	var h [4]byte
	if _, err := io.ReadFull(t.r, h[:]); err != nil {
		return nil, err
	}
	n := binary.BigEndian.Uint32(h[:])
	if n > maxPacket {
		return nil, errors.New("packet too large")
	}
	b := make([]byte, n)
	if _, err := io.ReadFull(t.r, b); err != nil {
		return nil, err
	}
	return b, nil
}

func (t *tcpTransport) Close() error { return t.c.Close() }
func (t *tcpTransport) Kind() string { return "direct" }

// ---- WebSocket ----

type wsTransport struct {
	c      *websocket.Conn
	ctx    context.Context
	cancel context.CancelFunc
	wmu    sync.Mutex
}

func NewWS(c *websocket.Conn) Transport {
	c.SetReadLimit(maxPacket + 1024)
	ctx, cancel := context.WithCancel(context.Background())
	return &wsTransport{c: c, ctx: ctx, cancel: cancel}
}

func (t *wsTransport) Send(p []byte) error {
	t.wmu.Lock()
	defer t.wmu.Unlock()
	ctx, cancel := context.WithTimeout(t.ctx, 30*time.Second)
	defer cancel()
	return t.c.Write(ctx, websocket.MessageBinary, p)
}

func (t *wsTransport) Recv() ([]byte, error) {
	for {
		typ, b, err := t.c.Read(t.ctx)
		if err != nil {
			return nil, err
		}
		if typ == websocket.MessageBinary {
			return b, nil
		}
		// text frames after pairing are relay notices; ignore
	}
}

func (t *wsTransport) Close() error {
	t.cancel()
	return t.c.Close(websocket.StatusNormalClosure, "")
}
func (t *wsTransport) Kind() string { return "relay" }
