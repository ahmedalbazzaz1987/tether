// Package session implements the host and viewer halves of a Tether session.
package session

import (
	"encoding/binary"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"tether/core/proto"
)

const AppVersion = "1.0.1"

// Clipboard abstracts the local clipboard (text only).
type Clipboard interface {
	GetText() (text string, seq uint64)
	SetText(string)
}

// FileProgress reports a transfer to the UI.
type FileProgress struct {
	ID       int64  `json:"id"`
	Name     string `json:"name"`
	Size     int64  `json:"size"`
	Done     int64  `json:"done"`
	Incoming bool   `json:"incoming"`
	State    string `json:"state"` // active, done, failed
	Path     string `json:"path,omitempty"`
}

// Events are delivered to the UI layer.
type Events struct {
	OnChat  func(fromRemote bool, text string)
	OnFile  func(FileProgress)
	OnEnded func(reason string)
	OnPing  func(ms int)
}

// common holds what host and viewer sessions share: files, clipboard, chat.
type common struct {
	ch        *proto.Channel
	ev        Events
	clip      Clipboard
	clipOn    bool
	downloads string

	mu         sync.Mutex
	lastRemote string
	lastSeq    uint64
	nextID     int64
	incoming   map[int64]*inFile
	outgoing   map[int64]*outFile
	done       chan struct{}
	endOnce    sync.Once
	endReason  string
}

type inFile struct {
	f    *os.File
	p    FileProgress
	path string
	last int64
}

type outFile struct {
	p      FileProgress
	acked  int64
	cond   *sync.Cond
	cancel bool
}

func newCommon(ch *proto.Channel, ev Events, clip Clipboard, downloads string, idBase int64) common {
	return common{ch: ch, ev: ev, clip: clip, clipOn: clip != nil, downloads: downloads,
		nextID: idBase, incoming: map[int64]*inFile{}, outgoing: map[int64]*outFile{}, done: make(chan struct{})}
}

func (c *common) end(reason string) {
	c.endOnce.Do(func() {
		c.endReason = reason
		close(c.done)
		c.ch.Close()
		c.mu.Lock()
		for _, f := range c.incoming {
			f.f.Close()
			os.Remove(f.path)
			f.p.State = "failed"
			c.emitFile(f.p)
		}
		for _, o := range c.outgoing {
			o.cancel = true
			o.cond.Broadcast()
		}
		c.mu.Unlock()
		if c.ev.OnEnded != nil {
			c.ev.OnEnded(reason)
		}
	})
}

func (c *common) emitFile(p FileProgress) {
	if c.ev.OnFile != nil {
		c.ev.OnFile(p) // must not block or call back into the session
	}
}

// Disconnect ends the session politely.
func (c *common) Disconnect() {
	c.ch.SendJSON(proto.Control{T: "bye"})
	time.Sleep(100 * time.Millisecond)
	c.end("Disconnected")
}

func (c *common) Done() <-chan struct{} { return c.done }

// Chat sends a chat line.
func (c *common) Chat(text string) error {
	return c.ch.SendJSON(proto.Control{T: "chat", Text: text})
}

// SetClipboardSync toggles clipboard sharing.
func (c *common) SetClipboardSync(on bool) {
	c.mu.Lock()
	c.clipOn = on && c.clip != nil
	c.mu.Unlock()
}

func (c *common) clipLoop() {
	if c.clip == nil {
		return
	}
	_, c.lastSeq = c.clip.GetText()
	t := time.NewTicker(500 * time.Millisecond)
	defer t.Stop()
	for {
		select {
		case <-c.done:
			return
		case <-t.C:
		}
		text, seq := c.clip.GetText()
		c.mu.Lock()
		on := c.clipOn
		changed := seq != c.lastSeq
		c.lastSeq = seq
		dup := text == c.lastRemote
		c.mu.Unlock()
		if on && changed && !dup && text != "" && len(text) < 4<<20 {
			c.mu.Lock()
			c.lastRemote = text
			c.mu.Unlock()
			c.ch.SendJSON(proto.Control{T: "clip", Text: text})
		}
	}
}

func (c *common) pingLoop() {
	t := time.NewTicker(3 * time.Second)
	defer t.Stop()
	for {
		select {
		case <-c.done:
			return
		case <-t.C:
			c.ch.SendJSON(proto.Control{T: "ping", TS: time.Now().UnixMilli()})
		}
	}
}

// handleCommon processes shared messages; returns true if handled.
func (c *common) handleCommon(typ byte, b []byte, m *proto.Control) bool {
	if typ == proto.MsgFile {
		c.fileData(b)
		return true
	}
	if m == nil {
		return false
	}
	switch m.T {
	case "bye":
		c.end("The other side ended the session")
	case "chat":
		if c.ev.OnChat != nil {
			c.ev.OnChat(true, m.Text)
		}
	case "clip":
		c.mu.Lock()
		on := c.clipOn
		if on {
			c.lastRemote = m.Text
		}
		c.mu.Unlock()
		if on {
			c.clip.SetText(m.Text)
		}
	case "ping":
		c.ch.SendJSON(proto.Control{T: "pong", TS: m.TS})
	case "pong":
		if c.ev.OnPing != nil {
			c.ev.OnPing(int(time.Now().UnixMilli() - m.TS))
		}
	case "file.offer":
		c.fileOffer(m)
	case "file.end":
		c.fileEnd(m, false)
	case "file.cancel":
		c.fileEnd(m, true)
		c.cancelOutgoing(m)
	case "file.ack":
		c.mu.Lock()
		if m.ID != nil {
			if o := c.outgoing[*m.ID]; o != nil {
				o.acked = m.Bytes
				o.cond.Broadcast()
			}
		}
		c.mu.Unlock()
	default:
		return false
	}
	return true
}

func (c *common) cancelOutgoing(m *proto.Control) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if m.ID != nil {
		if o := c.outgoing[*m.ID]; o != nil {
			o.cancel = true
			o.cond.Broadcast()
		}
	}
}

func safeName(n string) string {
	n = filepath.Base(strings.ReplaceAll(n, "\\", "/"))
	n = strings.Map(func(r rune) rune {
		if r < 32 || strings.ContainsRune(`<>:"/\|?*`, r) {
			return '_'
		}
		return r
	}, n)
	n = strings.TrimSpace(strings.Trim(n, "."))
	if n == "" {
		n = "file"
	}
	return n
}

func uniquePath(dir, name string) string {
	p := filepath.Join(dir, name)
	ext := filepath.Ext(name)
	stem := strings.TrimSuffix(name, ext)
	for i := 2; ; i++ {
		if _, err := os.Stat(p); os.IsNotExist(err) {
			if _, err := os.Stat(p + ".part"); os.IsNotExist(err) {
				return p
			}
		}
		p = filepath.Join(dir, fmt.Sprintf("%s (%d)%s", stem, i, ext))
	}
}

func (c *common) fileOffer(m *proto.Control) {
	if m.ID == nil {
		return
	}
	id := *m.ID
	os.MkdirAll(c.downloads, 0o755)
	final := uniquePath(c.downloads, safeName(m.Name))
	f, err := os.Create(final + ".part")
	if err != nil {
		c.ch.SendJSON(proto.Control{T: "file.cancel", ID: proto.I64Ptr(id)})
		return
	}
	in := &inFile{f: f, path: final + ".part", p: FileProgress{ID: id, Name: filepath.Base(final), Size: m.Size, Incoming: true, State: "active", Path: final}}
	c.mu.Lock()
	c.incoming[id] = in
	c.mu.Unlock()
	c.emitFile(in.p)
}

func (c *common) fileData(b []byte) {
	if len(b) < 4 {
		return
	}
	id := int64(binary.BigEndian.Uint32(b))
	c.mu.Lock()
	in := c.incoming[id]
	c.mu.Unlock()
	if in == nil {
		return
	}
	if _, err := in.f.Write(b[4:]); err != nil {
		c.ch.SendJSON(proto.Control{T: "file.cancel", ID: proto.I64Ptr(id)})
		c.fileEnd(&proto.Control{ID: proto.I64Ptr(id)}, true)
		return
	}
	in.p.Done += int64(len(b) - 4)
	if in.p.Done-in.last >= 1<<20 || in.p.Done == in.p.Size {
		in.last = in.p.Done
		c.ch.SendJSON(proto.Control{T: "file.ack", ID: proto.I64Ptr(id), Bytes: in.p.Done})
		c.emitFile(in.p)
	}
}

func (c *common) fileEnd(m *proto.Control, cancelled bool) {
	if m.ID == nil {
		return
	}
	c.mu.Lock()
	in := c.incoming[*m.ID]
	delete(c.incoming, *m.ID)
	c.mu.Unlock()
	if in == nil {
		return
	}
	in.f.Close()
	if cancelled || in.p.Done != in.p.Size {
		os.Remove(in.path)
		in.p.State = "failed"
	} else {
		os.Rename(in.path, in.p.Path)
		in.p.State = "done"
	}
	c.emitFile(in.p)
}

// SendFile streams a local file to the peer (runs in the background).
func (c *common) SendFile(path string) error {
	f, err := os.Open(path)
	if err != nil {
		return err
	}
	st, err := f.Stat()
	if err != nil || st.IsDir() {
		f.Close()
		return fmt.Errorf("only files can be sent")
	}
	c.mu.Lock()
	c.nextID++
	id := c.nextID
	o := &outFile{p: FileProgress{ID: id, Name: filepath.Base(path), Size: st.Size(), State: "active"}}
	o.cond = sync.NewCond(&c.mu)
	c.outgoing[id] = o
	c.mu.Unlock()
	if err := c.ch.SendJSON(proto.Control{T: "file.offer", ID: proto.I64Ptr(id), Name: o.p.Name, Size: o.p.Size}); err != nil {
		f.Close()
		return err
	}
	c.emitFile(o.p)
	go func() {
		defer f.Close()
		buf := make([]byte, 4+256<<10)
		binary.BigEndian.PutUint32(buf, uint32(id))
		var sent int64
		lastEmit := time.Now()
		fail := func() {
			o.p.State = "failed"
			c.emitFile(o.p)
			c.mu.Lock()
			delete(c.outgoing, id)
			c.mu.Unlock()
		}
		for {
			c.mu.Lock()
			for !o.cancel && sent-o.acked > 4<<20 {
				o.cond.Wait()
			}
			cancel := o.cancel
			c.mu.Unlock()
			if cancel {
				fail()
				return
			}
			n, err := f.Read(buf[4:])
			if n > 0 {
				if c.ch.Send(proto.MsgFile, buf[:4+n]) != nil {
					fail()
					return
				}
				sent += int64(n)
				o.p.Done = sent
				if time.Since(lastEmit) > 200*time.Millisecond {
					lastEmit = time.Now()
					c.emitFile(o.p)
				}
			}
			if err == io.EOF {
				break
			}
			if err != nil {
				c.ch.SendJSON(proto.Control{T: "file.cancel", ID: proto.I64Ptr(id)})
				fail()
				return
			}
		}
		c.ch.SendJSON(proto.Control{T: "file.end", ID: proto.I64Ptr(id)})
		o.p.State = "done"
		c.emitFile(o.p)
		c.mu.Lock()
		delete(c.outgoing, id)
		c.mu.Unlock()
	}()
	return nil
}
