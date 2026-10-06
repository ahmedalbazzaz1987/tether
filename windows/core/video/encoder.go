// Package video implements the tile-diff JPEG screen encoder (PROTOCOL §3, type 0x02).
package video

import (
	"bytes"
	"encoding/binary"
	"image"
	"image/jpeg"
	"runtime"
	"sync"
	"time"
)

const Tile = 64

// Frame is a BGRA screen image.
type Frame struct {
	W, H, Stride int
	Pix          []byte
}

type Quality struct{ Low, High int }

var Qualities = map[string]Quality{
	"fast":     {45, 80},
	"balanced": {62, 88},
	"best":     {78, 94},
}

type rect struct{ x, y, w, h, q int }

type Encoder struct {
	mu        sync.Mutex
	w, h      int
	tw, th    int
	prev      []byte // BGRA, stride w*4
	sentQ     []int
	changedAt []time.Time
	seq       uint32
	Q         Quality
}

func NewEncoder(q string) *Encoder {
	e := &Encoder{}
	e.SetQuality(q)
	return e
}

func (e *Encoder) SetQuality(q string) {
	e.mu.Lock()
	defer e.mu.Unlock()
	qq, ok := Qualities[q]
	if !ok {
		qq = Qualities["balanced"]
	}
	e.Q = qq
	for i := range e.sentQ {
		e.sentQ[i] = 0 // resend everything at the new quality
	}
	e.prev = nil
}

// Invalidate forces the next Encode to send a full frame.
func (e *Encoder) Invalidate() {
	e.mu.Lock()
	e.prev = nil
	e.mu.Unlock()
}

// Encode returns the payload for a video message, or nil if nothing changed.
func (e *Encoder) Encode(f Frame) ([]byte, uint32) {
	e.mu.Lock()
	defer e.mu.Unlock()
	now := time.Now()
	full := false
	if f.W != e.w || f.H != e.h || e.prev == nil {
		e.w, e.h = f.W, f.H
		e.tw, e.th = (f.W+Tile-1)/Tile, (f.H+Tile-1)/Tile
		e.prev = make([]byte, f.W*f.H*4)
		e.sentQ = make([]int, e.tw*e.th)
		e.changedAt = make([]time.Time, e.tw*e.th)
		full = true
	}
	dirty := make([]bool, e.tw*e.th)
	refine := make([]bool, e.tw*e.th)
	nd, nr := 0, 0
	rowBytes := f.W * 4
	for ty := 0; ty < e.th; ty++ {
		y0 := ty * Tile
		y1 := min(y0+Tile, f.H)
		for tx := 0; tx < e.tw; tx++ {
			x0 := tx * Tile * 4
			x1 := min((tx+1)*Tile, f.W) * 4
			idx := ty*e.tw + tx
			changed := full
			if !changed {
				for y := y0; y < y1; y++ {
					if !bytes.Equal(f.Pix[y*f.Stride+x0:y*f.Stride+x1], e.prev[y*rowBytes+x0:y*rowBytes+x1]) {
						changed = true
						break
					}
				}
			}
			if changed {
				for y := y0; y < y1; y++ {
					copy(e.prev[y*rowBytes+x0:y*rowBytes+x1], f.Pix[y*f.Stride+x0:y*f.Stride+x1])
				}
				dirty[idx] = true
				e.changedAt[idx] = now
				e.sentQ[idx] = e.Q.Low
				nd++
			} else if e.sentQ[idx] < e.Q.High && now.Sub(e.changedAt[idx]) > 350*time.Millisecond && nr < 96 {
				refine[idx] = true
				e.sentQ[idx] = e.Q.High
				nr++
			}
		}
	}
	if nd == 0 && nr == 0 {
		return nil, 0
	}
	rects := e.merge(dirty, e.Q.Low)
	rects = append(rects, e.merge(refine, e.Q.High)...)

	datas := make([][]byte, len(rects))
	var wg sync.WaitGroup
	sem := make(chan struct{}, runtime.NumCPU())
	for i, r := range rects {
		wg.Add(1)
		sem <- struct{}{}
		go func(i int, r rect) {
			defer func() { <-sem; wg.Done() }()
			datas[i] = e.encodeRect(r)
		}(i, r)
	}
	wg.Wait()

	e.seq++
	var out bytes.Buffer
	hdr := make([]byte, 10)
	binary.BigEndian.PutUint32(hdr, e.seq)
	binary.BigEndian.PutUint16(hdr[4:], uint16(e.w))
	binary.BigEndian.PutUint16(hdr[6:], uint16(e.h))
	binary.BigEndian.PutUint16(hdr[8:], uint16(len(rects)))
	out.Write(hdr)
	rh := make([]byte, 13)
	for i, r := range rects {
		binary.BigEndian.PutUint16(rh[0:], uint16(r.x))
		binary.BigEndian.PutUint16(rh[2:], uint16(r.y))
		binary.BigEndian.PutUint16(rh[4:], uint16(r.w))
		binary.BigEndian.PutUint16(rh[6:], uint16(r.h))
		rh[8] = 1
		binary.BigEndian.PutUint32(rh[9:], uint32(len(datas[i])))
		out.Write(rh)
		out.Write(datas[i])
	}
	return out.Bytes(), e.seq
}

// merge groups marked tiles into rectangles: horizontal runs, then vertical stacking.
func (e *Encoder) merge(mark []bool, q int) []rect {
	type span struct{ a, b int }
	var out []rect
	open := map[span]int{} // span -> index in out, for the previous row
	for ty := 0; ty < e.th; ty++ {
		next := map[span]int{}
		tx := 0
		for tx < e.tw {
			if !mark[ty*e.tw+tx] {
				tx++
				continue
			}
			a := tx
			for tx < e.tw && mark[ty*e.tw+tx] {
				tx++
			}
			s := span{a, tx}
			if i, ok := open[s]; ok {
				out[i].h = min((ty+1)*Tile, e.h) - out[i].y
				next[s] = i
			} else {
				x := a * Tile
				y := ty * Tile
				out = append(out, rect{x, y, min(tx*Tile, e.w) - x, min(y+Tile, e.h) - y, q})
				next[s] = len(out) - 1
			}
		}
		open = next
	}
	return out
}

func (e *Encoder) encodeRect(r rect) []byte {
	img := image.NewRGBA(image.Rect(0, 0, r.w, r.h))
	rowBytes := e.w * 4
	for y := 0; y < r.h; y++ {
		src := e.prev[(r.y+y)*rowBytes+r.x*4 : (r.y+y)*rowBytes+(r.x+r.w)*4]
		dst := img.Pix[y*img.Stride : y*img.Stride+r.w*4]
		for i := 0; i < len(src); i += 4 {
			dst[i] = src[i+2]
			dst[i+1] = src[i+1]
			dst[i+2] = src[i]
			dst[i+3] = 255
		}
	}
	var b bytes.Buffer
	jpeg.Encode(&b, img, &jpeg.Options{Quality: r.q})
	return b.Bytes()
}
