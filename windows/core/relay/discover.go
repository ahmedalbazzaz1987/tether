package relay

import (
	"net"
	"strconv"
	"strings"
	"sync"
	"time"
)

// LAN discovery (PROTOCOL.md §6): a viewer broadcasts "TETHER-FIND <id>" on
// UDP 47800; the host with that ID answers "TETHER-HERE <id> <tcpPort>".
// This lets 9-digit IDs work on the same network without any relay.

const DiscoveryPort = 47800

// Responder answers discovery requests for one ID.
type Responder struct {
	mu   sync.Mutex
	conn *net.UDPConn
}

func (r *Responder) Start(id string, tcpPort func() int) error {
	r.Stop()
	c, err := net.ListenUDP("udp4", &net.UDPAddr{Port: DiscoveryPort})
	if err != nil {
		return err
	}
	r.mu.Lock()
	r.conn = c
	r.mu.Unlock()
	go func() {
		buf := make([]byte, 256)
		for {
			n, from, err := c.ReadFromUDP(buf)
			if err != nil {
				return
			}
			f := strings.Fields(string(buf[:n]))
			if len(f) == 2 && f[0] == "TETHER-FIND" && f[1] == id {
				if p := tcpPort(); p > 0 {
					c.WriteToUDP([]byte("TETHER-HERE "+id+" "+strconv.Itoa(p)), from)
				}
			}
		}
	}()
	return nil
}

func (r *Responder) Stop() {
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.conn != nil {
		r.conn.Close()
		r.conn = nil
	}
}

// broadcastAddrs returns 255.255.255.255 plus each interface's directed broadcast.
func broadcastAddrs() []net.IP {
	out := []net.IP{net.IPv4bcast}
	ifs, _ := net.Interfaces()
	for _, i := range ifs {
		if i.Flags&net.FlagUp == 0 || i.Flags&net.FlagLoopback != 0 || i.Flags&net.FlagBroadcast == 0 {
			continue
		}
		addrs, _ := i.Addrs()
		for _, a := range addrs {
			ipn, ok := a.(*net.IPNet)
			if !ok || ipn.IP.To4() == nil {
				continue
			}
			ip, m := ipn.IP.To4(), ipn.Mask
			if len(m) == 16 {
				m = m[12:]
			}
			b := make(net.IP, 4)
			for k := 0; k < 4; k++ {
				b[k] = ip[k] | ^m[k]
			}
			out = append(out, b)
		}
	}
	return out
}

// Discover looks for a computer with this ID on the local network and
// returns "ip:port" of its direct listener.
func Discover(id string, timeout time.Duration) (string, bool) {
	c, err := net.ListenUDP("udp4", &net.UDPAddr{})
	if err != nil {
		return "", false
	}
	defer c.Close()
	msg := []byte("TETHER-FIND " + id)
	deadline := time.Now().Add(timeout)
	buf := make([]byte, 256)
	for attempt := 0; attempt < 3 && time.Now().Before(deadline); attempt++ {
		for _, b := range broadcastAddrs() {
			c.WriteToUDP(msg, &net.UDPAddr{IP: b, Port: DiscoveryPort})
		}
		c.SetReadDeadline(minTime(deadline, time.Now().Add(timeout/3)))
		for {
			n, from, err := c.ReadFromUDP(buf)
			if err != nil {
				break
			}
			f := strings.Fields(string(buf[:n]))
			if len(f) == 3 && f[0] == "TETHER-HERE" && f[1] == id {
				if p, err := strconv.Atoi(f[2]); err == nil && p > 0 && p < 65536 {
					return net.JoinHostPort(from.IP.String(), f[2]), true
				}
			}
		}
	}
	return "", false
}

func minTime(a, b time.Time) time.Time {
	if a.Before(b) {
		return a
	}
	return b
}
