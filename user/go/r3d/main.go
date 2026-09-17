package main

import (
	"virelai/r3d/internal"
	"virelai/tabapp"
	"virelai/vi"
)

type windowSink struct {
	f  vi.Filler
	ta *tabapp.TabApp
}

func (s *windowSink) Rect(x, y, w, h int, r, g, b uint8) {
	x0 := x * int(s.ta.W) / internal.SceneWidth
	y0 := y * int(s.ta.H) / internal.SceneHeight
	x1 := (x + w) * int(s.ta.W) / internal.SceneWidth
	y1 := (y + h) * int(s.ta.H) / internal.SceneHeight
	s.f.Rect(s.ta.Win, uint32(x0), uint32(y0), uint32(x1-x0), uint32(y1-y0), uint32(r)<<16|uint32(g)<<8|uint32(b))
}

func main() {
	ta := tabapp.Init(tabapp.Config{Name: "GOR3D.ELF", Title: "R3D", X: 32, Y: 32, W: 512, H: 384})
	if ta == nil {
		vi.ConsoleLine("gor3d: error open")
		vi.Exit(1)
	}
	im := internal.Scene()
	sink := &windowSink{ta: ta}
	draw := func() {
		internal.FlushRuns(im, sink)
		sink.f.Flush()
		if vi.WinPresent(ta.Win) < 0 {
			vi.ConsoleLine("gor3d: error present")
			ta.CloseAndExit(1)
		}
	}
	draw()
	vi.ConsoleLine("gor3d: open id=" + vi.Itoa64(int64(ta.Win)))
	if ta.TabAware {
		vi.ConsoleLine("gor3d: declare accepted")
	}
	vi.ConsoleLine("gor3d: present")
	seenResize := false
	for {
		ev, rc, ok := vi.PollEventRaw()
		if !ok {
			if rc < 0 {
				vi.ConsoleLine("gor3d: error event")
				ta.CloseAndExit(1)
			}
			vi.Sleep(1)
			continue
		}
		switch ta.Dispatch(ev) {
		case tabapp.ActionClosed:
			ta.CloseAndExit(0)
		case tabapp.ActionResized:
			if !seenResize {
				draw()
				seenResize = true
				vi.ConsoleLine("gor3d: resize present " + vi.Itoa64(int64(ta.W)) + "x" + vi.Itoa64(int64(ta.H)))
			}
		}
	}
}
