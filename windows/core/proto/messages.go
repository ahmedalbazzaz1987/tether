package proto

import (
	"encoding/binary"
	"encoding/json"
)

// Display describes one monitor of the host.
type Display struct {
	ID      int    `json:"id"`
	Name    string `json:"name"`
	W       int    `json:"w"`
	H       int    `json:"h"`
	Primary bool   `json:"primary,omitempty"`
}

// Control is the union of all JSON messages (PROTOCOL §4).
type Control struct {
	T        string    `json:"t"`
	OS       string    `json:"os,omitempty"`
	Name     string    `json:"name,omitempty"`
	Version  string    `json:"version,omitempty"`
	Displays []Display `json:"displays,omitempty"`
	Display  *int      `json:"display,omitempty"`
	ID       *int64    `json:"id,omitempty"`
	Q        string    `json:"q,omitempty"`
	Text     string    `json:"text,omitempty"`
	Size     int64     `json:"size,omitempty"`
	Bytes    int64     `json:"bytes,omitempty"`
	TS       int64     `json:"ts,omitempty"`
}

func IntPtr(i int) *int     { return &i }
func I64Ptr(i int64) *int64 { return &i }

func (c *Channel) SendJSON(m Control) error {
	b, err := json.Marshal(m)
	if err != nil {
		return err
	}
	return c.Send(MsgJSON, b)
}

func ParseJSON(b []byte) (Control, error) {
	var m Control
	err := json.Unmarshal(b, &m)
	return m, err
}

// Mouse event kinds / buttons
const (
	MouseMove  = 0
	MouseDown  = 1
	MouseUp    = 2
	MouseWheel = 3
)

type MouseEvent struct {
	Kind, Button byte
	X, Y         uint16
	DX, DY       int16
}

func (m MouseEvent) Encode() []byte {
	b := make([]byte, 10)
	b[0], b[1] = m.Kind, m.Button
	binary.BigEndian.PutUint16(b[2:], m.X)
	binary.BigEndian.PutUint16(b[4:], m.Y)
	binary.BigEndian.PutUint16(b[6:], uint16(m.DX))
	binary.BigEndian.PutUint16(b[8:], uint16(m.DY))
	return b
}

func DecodeMouse(b []byte) (MouseEvent, bool) {
	if len(b) < 10 {
		return MouseEvent{}, false
	}
	return MouseEvent{b[0], b[1], binary.BigEndian.Uint16(b[2:]), binary.BigEndian.Uint16(b[4:]),
		int16(binary.BigEndian.Uint16(b[6:])), int16(binary.BigEndian.Uint16(b[8:]))}, true
}

type KeyEvent struct {
	Down bool
	HID  uint16
}

func (k KeyEvent) Encode() []byte {
	b := make([]byte, 3)
	if k.Down {
		b[0] = 1
	}
	binary.BigEndian.PutUint16(b[1:], k.HID)
	return b
}

func DecodeKey(b []byte) (KeyEvent, bool) {
	if len(b) < 3 {
		return KeyEvent{}, false
	}
	return KeyEvent{b[0] == 1, binary.BigEndian.Uint16(b[1:])}, true
}

func EncodeU32(v uint32) []byte {
	b := make([]byte, 4)
	binary.BigEndian.PutUint32(b, v)
	return b
}
