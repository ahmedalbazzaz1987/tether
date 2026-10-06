package proto

import (
	"bytes"
	"crypto/aes"
	"crypto/cipher"
	"crypto/ecdh"
	"crypto/ed25519"
	"crypto/hkdf"
	"crypto/hmac"
	"crypto/pbkdf2"
	"crypto/rand"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/binary"
	"errors"
	"strings"
	"sync"
	"time"
	"unicode"
)

const (
	Version        = 1
	OSMac     byte = 1
	OSWindows byte = 2
	KDFIters       = 150000
)

var (
	ErrBadPassword = errors.New("wrong password")
	ErrLocked      = errors.New("too many attempts – the remote computer is temporarily locked")
	ErrBusy        = errors.New("the remote computer is busy")
	ErrProtocol    = errors.New("protocol error")
)

// NormalizePassword removes all whitespace.
func NormalizePassword(p string) string {
	return strings.Map(func(r rune) rune {
		if unicode.IsSpace(r) {
			return -1
		}
		return r
	}, p)
}

// DeriveKPW computes the password key (PROTOCOL §2).
func DeriveKPW(password string, salt []byte, iters int) []byte {
	k, _ := pbkdf2.Key(sha256.New, NormalizePassword(password), salt, iters, 32)
	return k
}

func hk(ikm, th []byte, info string) []byte {
	k, _ := hkdf.Key(sha256.New, ikm, th, info, 32)
	return k
}

func mac(key []byte, msg string) []byte {
	m := hmac.New(sha256.New, key)
	m.Write([]byte(msg))
	return m.Sum(nil)
}

func transcript(p1, p2body []byte) []byte {
	h := sha256.New()
	h.Write([]byte("tether-v1"))
	h.Write(p1)
	h.Write(p2body)
	return h.Sum(nil)
}

func putName(b *bytes.Buffer, name string) {
	n := []byte(name)
	if len(n) > 64 {
		n = n[:64]
	}
	b.WriteByte(byte(len(n)))
	b.Write(n)
}

// ServerInfo is what the viewer learns from P2.
type ServerInfo struct {
	HostPub ed25519.PublicKey
	OS      byte
	Name    string
}

// ---- viewer side ----

// ClientHandshake runs the viewer side. verify is called with the host's
// long-term key before any password-derived data is sent.
func ClientHandshake(t Transport, viewerName, password string, verify func(ServerInfo) error) (*Channel, *ServerInfo, error) {
	eph, err := ecdh.X25519().GenerateKey(rand.Reader)
	if err != nil {
		return nil, nil, err
	}
	var p1 bytes.Buffer
	p1.WriteString("TTH1")
	p1.WriteByte(Version)
	p1.Write(eph.PublicKey().Bytes())
	putName(&p1, viewerName)
	if err := t.Send(p1.Bytes()); err != nil {
		return nil, nil, err
	}
	p2, err := t.Recv()
	if err != nil {
		return nil, nil, err
	}
	// parse P2
	if len(p2) < 4+1+32+32+16+4+1+1+64 || string(p2[:4]) != "TTS1" {
		return nil, nil, ErrProtocol
	}
	o := 5
	hostEph := p2[o : o+32]
	o += 32
	hostPub := ed25519.PublicKey(append([]byte(nil), p2[o:o+32]...))
	o += 32
	salt := p2[o : o+16]
	o += 16
	iters := int(binary.BigEndian.Uint32(p2[o:]))
	o += 4
	osb := p2[o]
	o++
	nl := int(p2[o])
	o++
	if len(p2) != o+nl+64 {
		return nil, nil, ErrProtocol
	}
	name := string(p2[o : o+nl])
	o += nl
	body, sig := p2[:o], p2[o:]
	th := transcript(p1.Bytes(), body)
	if !ed25519.Verify(hostPub, th, sig) {
		return nil, nil, errors.New("host signature invalid")
	}
	if iters < 10000 || iters > 5000000 {
		return nil, nil, ErrProtocol
	}
	info := &ServerInfo{HostPub: hostPub, OS: osb, Name: name}
	if verify != nil {
		if err := verify(*info); err != nil {
			return nil, nil, err
		}
	}
	pub, err := ecdh.X25519().NewPublicKey(hostEph)
	if err != nil {
		return nil, nil, ErrProtocol
	}
	shared, err := eph.ECDH(pub)
	if err != nil {
		return nil, nil, err
	}
	kpw := DeriveKPW(password, salt, iters)
	ikm := append(append([]byte{}, shared...), kpw...)
	p3 := append([]byte("TTP1"), mac(hk(ikm, th, "tether proof v"), "viewer")...)
	if err := t.Send(p3); err != nil {
		return nil, nil, err
	}
	p4, err := t.Recv()
	if err != nil {
		return nil, nil, err
	}
	if len(p4) == 5 && string(p4[:4]) == "TTNO" {
		switch p4[4] {
		case 2:
			return nil, nil, ErrLocked
		case 3:
			return nil, nil, ErrBusy
		default:
			return nil, nil, ErrBadPassword
		}
	}
	if len(p4) != 36 || string(p4[:4]) != "TTOK" {
		return nil, nil, ErrProtocol
	}
	if !hmac.Equal(p4[4:], mac(hk(ikm, th, "tether proof h"), "host")) {
		return nil, nil, errors.New("host could not prove the password")
	}
	ch, err := newChannel(t, hk(ikm, th, "tether key v2h"), hk(ikm, th, "tether key h2v"))
	return ch, info, err
}

// ---- host side ----

// Limiter throttles password guesses host-wide.
type Limiter struct {
	mu       sync.Mutex
	fails    []time.Time
	lockTill time.Time
}

func (l *Limiter) Locked() bool {
	l.mu.Lock()
	defer l.mu.Unlock()
	return time.Now().Before(l.lockTill)
}

func (l *Limiter) Fail() {
	l.mu.Lock()
	defer l.mu.Unlock()
	now := time.Now()
	keep := l.fails[:0]
	for _, f := range l.fails {
		if now.Sub(f) < 5*time.Minute {
			keep = append(keep, f)
		}
	}
	l.fails = append(keep, now)
	if len(l.fails) >= 5 {
		l.lockTill = now.Add(5 * time.Minute)
		l.fails = nil
	}
}

func (l *Limiter) Success() {
	l.mu.Lock()
	l.fails = nil
	l.mu.Unlock()
}

// HostParams configure ServerHandshake.
type HostParams struct {
	Key        ed25519.PrivateKey
	Name       string
	OS         byte
	Salt       []byte // 16 bytes
	Iters      int
	Candidates func() [][]byte // current accepted kpw values
	Limiter    *Limiter
	Busy       func() bool
}

// ServerHandshake runs the host side and returns the channel and viewer name.
func ServerHandshake(t Transport, hp HostParams) (*Channel, string, error) {
	p1, err := t.Recv()
	if err != nil {
		return nil, "", err
	}
	if len(p1) < 4+1+32+1 || string(p1[:4]) != "TTH1" {
		return nil, "", ErrProtocol
	}
	vEph := p1[5:37]
	nl := int(p1[37])
	if len(p1) != 38+nl {
		return nil, "", ErrProtocol
	}
	vname := string(p1[38 : 38+nl])

	eph, err := ecdh.X25519().GenerateKey(rand.Reader)
	if err != nil {
		return nil, "", err
	}
	var b bytes.Buffer
	b.WriteString("TTS1")
	b.WriteByte(Version)
	b.Write(eph.PublicKey().Bytes())
	b.Write(hp.Key.Public().(ed25519.PublicKey))
	b.Write(hp.Salt)
	var it [4]byte
	binary.BigEndian.PutUint32(it[:], uint32(hp.Iters))
	b.Write(it[:])
	b.WriteByte(hp.OS)
	putName(&b, hp.Name)
	body := append([]byte(nil), b.Bytes()...)
	th := transcript(p1, body)
	sig := ed25519.Sign(hp.Key, th)
	if err := t.Send(append(body, sig...)); err != nil {
		return nil, "", err
	}
	p3, err := t.Recv()
	if err != nil {
		return nil, "", err
	}
	if len(p3) != 36 || string(p3[:4]) != "TTP1" {
		return nil, "", ErrProtocol
	}
	fail := func(reason byte, e error) (*Channel, string, error) {
		t.Send([]byte{'T', 'T', 'N', 'O', reason})
		return nil, vname, e
	}
	if hp.Limiter != nil && hp.Limiter.Locked() {
		return fail(2, ErrLocked)
	}
	if hp.Busy != nil && hp.Busy() {
		return fail(3, ErrBusy)
	}
	pub, err := ecdh.X25519().NewPublicKey(vEph)
	if err != nil {
		return nil, "", ErrProtocol
	}
	shared, err := eph.ECDH(pub)
	if err != nil {
		return nil, "", err
	}
	var ikm []byte
	matched := false
	for _, kpw := range hp.Candidates() {
		cand := append(append([]byte{}, shared...), kpw...)
		if subtle.ConstantTimeCompare(p3[4:], mac(hk(cand, th, "tether proof v"), "viewer")) == 1 {
			ikm = cand
			matched = true
		}
	}
	if !matched {
		if hp.Limiter != nil {
			hp.Limiter.Fail()
		}
		time.Sleep(700 * time.Millisecond)
		return fail(1, ErrBadPassword)
	}
	if hp.Limiter != nil {
		hp.Limiter.Success()
	}
	if err := t.Send(append([]byte("TTOK"), mac(hk(ikm, th, "tether proof h"), "host")...)); err != nil {
		return nil, "", err
	}
	ch, err := newChannel(t, hk(ikm, th, "tether key h2v"), hk(ikm, th, "tether key v2h"))
	return ch, vname, err
}

// ---- encrypted channel ----

const (
	MsgJSON  byte = 0x01
	MsgVideo byte = 0x02
	MsgMouse byte = 0x03
	MsgKey   byte = 0x04
	MsgAck   byte = 0x05
	MsgFile  byte = 0x06
	MsgFrag  byte = 0x7F

	fragSize = 512 << 10
)

type Channel struct {
	t        Transport
	send     cipher.AEAD
	recv     cipher.AEAD
	sendCtr  uint64
	recvCtr  uint64
	wmu      sync.Mutex
	fragType byte
	fragBuf  []byte
	closed   sync.Once
}

func newChannel(t Transport, sendKey, recvKey []byte) (*Channel, error) {
	mk := func(k []byte) (cipher.AEAD, error) {
		b, err := aes.NewCipher(k)
		if err != nil {
			return nil, err
		}
		return cipher.NewGCM(b)
	}
	s, err := mk(sendKey)
	if err != nil {
		return nil, err
	}
	r, err := mk(recvKey)
	if err != nil {
		return nil, err
	}
	return &Channel{t: t, send: s, recv: r}, nil
}

func nonce(ctr uint64) []byte {
	n := make([]byte, 12)
	binary.BigEndian.PutUint64(n[4:], ctr)
	return n
}

func (c *Channel) Kind() string { return c.t.Kind() }

func (c *Channel) sealSend(pt []byte) error {
	ct := c.send.Seal(nil, nonce(c.sendCtr), pt, nil)
	c.sendCtr++
	return c.t.Send(ct)
}

// Send transmits one message, fragmenting if needed.
func (c *Channel) Send(typ byte, payload []byte) error {
	c.wmu.Lock()
	defer c.wmu.Unlock()
	if len(payload) <= fragSize {
		pt := make([]byte, 1+len(payload))
		pt[0] = typ
		copy(pt[1:], payload)
		return c.sealSend(pt)
	}
	for off := 0; off < len(payload); off += fragSize {
		end := off + fragSize
		last := byte(0)
		if end >= len(payload) {
			end = len(payload)
			last = 1
		}
		pt := make([]byte, 3+end-off)
		pt[0], pt[1], pt[2] = MsgFrag, typ, last
		copy(pt[3:], payload[off:end])
		if err := c.sealSend(pt); err != nil {
			return err
		}
	}
	return nil
}

// Recv returns the next complete message.
func (c *Channel) Recv() (byte, []byte, error) {
	for {
		ct, err := c.t.Recv()
		if err != nil {
			return 0, nil, err
		}
		pt, err := c.recv.Open(nil, nonce(c.recvCtr), ct, nil)
		if err != nil {
			return 0, nil, errors.New("decryption failed")
		}
		c.recvCtr++
		if len(pt) == 0 {
			continue
		}
		if pt[0] != MsgFrag {
			return pt[0], pt[1:], nil
		}
		if len(pt) < 3 {
			return 0, nil, ErrProtocol
		}
		c.fragType = pt[1]
		c.fragBuf = append(c.fragBuf, pt[3:]...)
		if len(c.fragBuf) > 64<<20 {
			return 0, nil, ErrProtocol
		}
		if pt[2] == 1 {
			out := c.fragBuf
			c.fragBuf = nil
			return c.fragType, out, nil
		}
	}
}

func (c *Channel) Close() {
	c.closed.Do(func() { c.t.Close() })
}
