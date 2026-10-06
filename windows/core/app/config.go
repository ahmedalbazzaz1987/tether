package app

import (
	"crypto/ed25519"
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"math/big"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"
)

type Recent struct {
	Target string    `json:"target"`
	Name   string    `json:"name"`
	OS     string    `json:"os"`
	When   time.Time `json:"when"`
}

// Config is persisted to <dataDir>/config.json. Secrets are wrapped with Protect.
type Config struct {
	ID             string            `json:"id"`
	Secret         string            `json:"secret"`   // relay ownership secret (protected, hex)
	HostSeed       string            `json:"hostSeed"` // Ed25519 seed (protected, hex)
	Salt           string            `json:"salt"`
	PermKPW        string            `json:"permKpw,omitempty"` // protected, hex
	RelayURL       string            `json:"relayUrl"`
	AllowLAN       bool              `json:"allowLan"`
	LANPort        int               `json:"lanPort"`
	Quality        string            `json:"quality"`
	LaunchAtLogin  bool              `json:"launchAtLogin"`
	ClipboardSync  bool              `json:"clipboardSync"`
	AcceptIncoming bool              `json:"acceptIncoming"`
	AutoUpdate     bool              `json:"autoUpdate"`
	KnownHosts     map[string]string `json:"knownHosts"`
	Recent         []Recent          `json:"recent"`
}

type Store struct {
	mu        sync.Mutex
	path      string
	C         Config
	protect   func([]byte) ([]byte, error)
	unprotect func([]byte) ([]byte, error)
}

func randHex(n int) string {
	b := make([]byte, n)
	rand.Read(b)
	return hex.EncodeToString(b)
}

func newID() string {
	n, _ := rand.Int(rand.Reader, big.NewInt(900000000))
	return fmt.Sprintf("%09d", n.Int64()+100000000)
}

func OpenStore(dir string, protect, unprotect func([]byte) ([]byte, error)) (*Store, error) {
	if protect == nil {
		protect = func(b []byte) ([]byte, error) { return b, nil }
		unprotect = protect
	}
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return nil, err
	}
	s := &Store{path: filepath.Join(dir, "config.json"), protect: protect, unprotect: unprotect}
	b, err := os.ReadFile(s.path)
	fresh := err != nil
	if !fresh {
		if json.Unmarshal(b, &s.C) != nil {
			fresh = true
		}
	}
	if fresh || s.C.ID == "" {
		seed := make([]byte, 32)
		rand.Read(seed)
		s.C = Config{ID: newID(), Salt: randHex(16), AllowLAN: true, LANPort: 47800,
			Quality: "balanced", ClipboardSync: true, AcceptIncoming: true, AutoUpdate: true,
			KnownHosts: map[string]string{}}
		s.setSecret(&s.C.Secret, []byte(randHex(32)))
		s.setSecret(&s.C.HostSeed, seed)
		if err := s.saveLocked(); err != nil {
			return nil, err
		}
	}
	if s.C.KnownHosts == nil {
		s.C.KnownHosts = map[string]string{}
	}
	if s.C.LANPort == 0 {
		s.C.LANPort = 47800
	}
	return s, nil
}

func (s *Store) setSecret(dst *string, v []byte) {
	p, err := s.protect(v)
	if err != nil {
		p = v
	}
	*dst = hex.EncodeToString(p)
}

func (s *Store) getSecret(v string) []byte {
	b, err := hex.DecodeString(v)
	if err != nil {
		return nil
	}
	out, err := s.unprotect(b)
	if err != nil {
		return nil
	}
	return out
}

func (s *Store) Save() error {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.saveLocked()
}

func (s *Store) saveLocked() error {
	b, _ := json.MarshalIndent(s.C, "", "  ")
	tmp := s.path + ".tmp"
	if err := os.WriteFile(tmp, b, 0o600); err != nil {
		return err
	}
	return os.Rename(tmp, s.path)
}

func (s *Store) Update(f func(c *Config)) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	f(&s.C)
	return s.saveLocked()
}

func (s *Store) Get() Config {
	s.mu.Lock()
	defer s.mu.Unlock()
	c := s.C
	return c
}

func (s *Store) HostKey() ed25519.PrivateKey {
	s.mu.Lock()
	defer s.mu.Unlock()
	seed := s.getSecret(s.C.HostSeed)
	if len(seed) != 32 {
		seed = make([]byte, 32)
		rand.Read(seed)
		s.setSecret(&s.C.HostSeed, seed)
		s.saveLocked()
	}
	return ed25519.NewKeyFromSeed(seed)
}

func (s *Store) RelaySecret() string {
	s.mu.Lock()
	defer s.mu.Unlock()
	return string(s.getSecret(s.C.Secret))
}

func (s *Store) SaltBytes() []byte {
	b, _ := hex.DecodeString(s.Get().Salt)
	return b
}

func (s *Store) PermKPW() []byte {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.C.PermKPW == "" {
		return nil
	}
	return s.getSecret(s.C.PermKPW)
}

func (s *Store) SetPermKPW(k []byte) error {
	return s.Update(func(c *Config) {
		if k == nil {
			c.PermKPW = ""
		} else {
			s.setSecret(&c.PermKPW, k)
		}
	})
}

// Fingerprint renders a public key as groups for humans.
func Fingerprint(pub []byte) string {
	h := sha256.Sum256(pub)
	x := strings.ToUpper(hex.EncodeToString(h[:8]))
	return x[0:4] + " " + x[4:8] + " " + x[8:12] + " " + x[12:16]
}

// OneTimePassword makes an 8-character password from an unambiguous alphabet.
func OneTimePassword() string {
	const a = "abcdefghjkmnpqrstuvwxyz23456789"
	b := make([]byte, 8)
	for i := range b {
		n, _ := rand.Int(rand.Reader, big.NewInt(int64(len(a))))
		b[i] = a[n.Int64()]
	}
	return string(b)
}
