// tethertest runs the Tether core with a synthetic screen on any OS, for testing.
// Usage: tethertest -dir /tmp/a -name Alpha   (prints the UI URL)
package main

import (
	"flag"
	"fmt"
	"log"
	"math"
	"os"
	"path/filepath"
	"sync"
	"time"

	"tether/core/app"
	"tether/core/proto"
	"tether/core/session"
	"tether/core/video"
)

type memClip struct {
	mu   sync.Mutex
	text string
	seq  uint64
}

func (c *memClip) GetText() (string, uint64) { c.mu.Lock(); defer c.mu.Unlock(); return c.text, c.seq }
func (c *memClip) SetText(s string) {
	c.mu.Lock()
	c.text = s
	c.seq++
	c.mu.Unlock()
	log.Printf("clipboard <- %q", s)
}

type fake struct {
	name string
	dir  string
	clip memClip
	mx   float64
	my   float64
	mu   sync.Mutex
	buf  []byte
}

func (f *fake) OSName() string      { return "windows" }
func (f *fake) MachineName() string { return f.name }
func (f *fake) Displays() []proto.Display {
	return []proto.Display{{ID: 0, Name: "Synthetic 1", W: 1280, H: 720, Primary: true}, {ID: 1, Name: "Synthetic 2", W: 800, H: 600}}
}
func (f *fake) Capture(d int) (video.Frame, error) {
	w, h := 1280, 720
	if d == 1 {
		w, h = 800, 600
	}
	f.mu.Lock()
	defer f.mu.Unlock()
	if len(f.buf) != w*h*4 {
		f.buf = make([]byte, w*h*4)
		for y := 0; y < h; y++ {
			for x := 0; x < w; x++ {
				i := (y*w + x) * 4
				f.buf[i] = byte(x * 255 / w)
				f.buf[i+1] = byte(y * 255 / h)
				f.buf[i+2] = 90
				f.buf[i+3] = 255
			}
		}
	}
	t := float64(time.Now().UnixMilli()) / 1000
	// moving box
	bx := int((math.Sin(t)*0.4 + 0.5) * float64(w-100))
	for y := 300 % h; y < 300%h+80 && y < h; y++ {
		for x := 0; x < w; x++ {
			i := (y*w + x) * 4
			if x >= bx && x < bx+100 {
				f.buf[i], f.buf[i+1], f.buf[i+2] = 255, 255, 255
			} else {
				f.buf[i], f.buf[i+1], f.buf[i+2] = byte(x*255/w), byte(y*255/h), 90
			}
		}
	}
	// cursor dot
	cx, cy := int(f.mx*float64(w)), int(f.my*float64(h))
	for y := cy - 4; y < cy+4; y++ {
		for x := cx - 4; x < cx+4; x++ {
			if x >= 0 && y >= 0 && x < w && y < h {
				i := (y*w + x) * 4
				f.buf[i], f.buf[i+1], f.buf[i+2] = 0, 0, 255
			}
		}
	}
	return video.Frame{W: w, H: h, Stride: w * 4, Pix: f.buf}, nil
}
func (f *fake) Mouse(d int, ev proto.MouseEvent) {
	f.mu.Lock()
	f.mx, f.my = float64(ev.X)/65535, float64(ev.Y)/65535
	f.mu.Unlock()
	if ev.Kind != proto.MouseMove {
		log.Printf("mouse %+v", ev)
	}
}
func (f *fake) Key(ev proto.KeyEvent)        { log.Printf("key %+v", ev) }
func (f *fake) ReleaseAll()                  {}
func (f *fake) Clipboard() session.Clipboard { return &f.clip }
func (f *fake) DownloadsDir() string         { return filepath.Join(f.dir, "Downloads") }

func main() {
	dir := flag.String("dir", "/tmp/tether-a", "data dir")
	name := flag.String("name", "Test PC", "machine name")
	port := flag.Int("port", 0, "LAN port override")
	relayURL := flag.String("relay", "", "relay URL")
	nolan := flag.Bool("nolan", false, "disable LAN listener")
	flag.Parse()
	os.MkdirAll(*dir, 0o755)
	st, err := app.OpenStore(*dir, nil, nil)
	if err != nil {
		log.Fatal(err)
	}
	st.Update(func(c *app.Config) {
		if *port != 0 {
			c.LANPort = *port
		}
		c.AllowLAN = !*nolan
		if *relayURL != "" {
			c.RelayURL = *relayURL
		}
	})
	f := &fake{name: *name, dir: *dir}
	a := app.New(st, f, app.Hooks{OSName: "windows",
		PickFiles: func() []string { return []string{os.Args[0]} },
		Notify:    func(t, b string) { log.Printf("notify: %s: %s", t, b) },
		OpenPath:  func(p string) { log.Printf("open %s", p) },
	})
	url, err := a.Hub.Serve()
	if err != nil {
		log.Fatal(err)
	}
	a.Start()
	s := a.State()
	fmt.Printf("URL %s\nID %s\nOTP %s\n", url, s["id"], s["otp"])
	os.WriteFile(filepath.Join(*dir, "info.txt"), []byte(fmt.Sprintf("%s\n%s\n%s\n", url, s["id"], s["otp"])), 0o644)
	select {}
}
