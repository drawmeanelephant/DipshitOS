// WEB.ELF — the VirelaiOS browser (Go, EL0).
//
// The app shell (window, chrome, navigation, history, HTTP fetch) is Go, and
// the page renderer is the project's own Go library (virelai/webrender):
// parse -> UA style table -> block/inline layout -> span paint. There is no
// JavaScript and no CSS cascade by design; the UI says so out loud.
//
// Usage:  exec WEB.ELF /host/PAGE.HTML     (file channel)
//
//	exec WEB.ELF http://10.0.0.2/    (TCP fetch; IP literals only)
package main

import (
	"strings"

	"virelai/vi"
	"virelai/webrender"
)

// Window geometry matches the in-guest Zig renderer's window (DOC.BIN) so the
// same scanout probes apply.
const (
	winX = 40
	winY = 28
	winW = 512
	winH = 384
)

// Chrome geometry (all inside the app's own surface).
//
// The kernel paints its OWN window title band over the top 16 rows of every
// user window (observed live: see the live-web pixel probes), so the app's
// chrome starts below it — otherwise the title and the JS indicator would be
// hidden under the kernel band.
const (
	kernelBand = 16
	titleY     = kernelBand
	titleH     = 16
	urlRowY    = titleY + titleH // 32
	urlRowH    = 18
	contentY   = urlRowY + urlRowH // 50
	statusH    = 12
	contentX   = 8
	contentW   = winW - 2*contentX
	contentH   = winH - contentY - statusH

	backX, backY, chipW, chipH = 6, urlRowY + 2, 14, 14
	fwdX                       = 22
	reloadX                    = 38
	urlX                       = 56
	urlY, urlH                 = urlRowY + 2, 14
	urlW                       = winW - urlX - 8
)

// Serial markers. These exact bytes are the live gate's grep targets and are
// pinned by a host test (see history_test.go).
const (
	markerOpen      = "web: open id="
	markerParse     = "web: parse nodes="
	markerLayout    = "web: layout blocks="
	markerURL       = "web: url "
	markerNav       = "web: nav "
	markerNavigated = "web: navigated"
	markerError     = "web: error "
	markerPaint     = "web: paint items="
	markerPollErr   = "web: poll err="
	markerLoop      = "web: poll n="
	markerEvent     = "web: ev "
	markerRepaint   = "web: repaint items="
	markerReady     = "web: ready"
	markerNavReady  = "web: nav-ready"
	markerSettled   = "web: settled"
	markerQuit      = "web: quit"
)

// HistoryPersistence is where visits are appended (inspectable text, one
// "unix-seconds target" row per visit, after a schema line).
const (
	historyPath   = "/host/WEB-HISTORY.TXT"
	historySchema = "# virelai-web-history v1 (unix-seconds<TAB>target)"
)

// HID usage codes the OS delivers in EvKeyDown.Arg0.
const (
	keyQ        = 0x14
	keyR        = 0x15
	keyEscape   = 0x29
	keyBacksp   = 0x2a
	keyRight    = 0x4f
	keyLeft     = 0x50
	keyDown     = 0x51
	keyUp       = 0x52
	keyPageUp   = 0x4b
	keyPageDown = 0x4e
	keyHome     = 0x4a
	keyEnd      = 0x4d
	keyF5       = 0x3e
)

type app struct {
	win    int
	filler vi.Filler

	hist   *history
	target string
	title  string

	doc *webrender.Document
	lay *webrender.Layout

	scroll     int
	hover      string
	status     string
	errKind    string
	errMsg     string
	dirty      bool
	quit       bool
	painted    int
	navCount   int
	polls      int
	events     int
	lastFills  int
	logPaint   bool
	loggedPoll bool
}

// virender adapts the kernel fill batcher to the renderer's Surface.
type virender struct {
	f   *vi.Filler
	win int
}

func (v virender) Fill(x, y, w, h int, rgb uint32) {
	if w <= 0 || h <= 0 || x < 0 || y < 0 {
		return
	}
	v.f.Rect(v.win, uint32(x), uint32(y), uint32(w), uint32(h), rgb)
}

func main() {
	args := vi.Args()
	target := ""
	if len(args) > 1 {
		target = args[1]
	}

	id, rc := vi.WinOpen(winX, winY, winW, winH)
	if rc < 0 || id < 0 {
		vi.ConsoleLine("web: error window")
		vi.Exit(2)
	}
	a := &app{win: id, hist: newHistory()}
	vi.ConsoleLine(markerOpen + itoa(id))

	if target == "" {
		a.showStartSurface()
	} else {
		a.navigate(target, "")
	}
	a.render()
	vi.ConsoleLine(markerSettled)
	a.settleRepaint()
	a.loop()
}

// settleRepaint presents the first frame a second time after the scheduler has
// had a tick to pace the composite. Observed live: a single present
// immediately after a long blocking fetch could leave the scanout on the
// pre-paint buffer, while the fill accounting showed every rect accepted.
func (a *app) settleRepaint() {
	vi.Sleep(30)
	a.render()
	vi.ConsoleLine(markerRepaint + itoa(itemsOf(a)) + " fills=" + itoa(a.lastFills))
	// The gate snapshots on `web: repaint` and *exits* on `web: ready`; the
	// two are deliberately different lines so the framebuffer stream has
	// time to complete before the run ends (observed live: a shared marker
	// let the runner shut down mid-stream and the snapshot never landed).
	vi.Sleep(5)
	vi.ConsoleLine(markerReady)
}

func (a *app) loop() {
	for !a.quit {
		a.polls++
		if a.polls%250 == 0 {
			vi.ConsoleLine(markerLoop + itoa(a.polls) + " ev=" + itoa(a.events))
		}
		ev, raw, ok := vi.PollEventRaw()
		if !ok {
			if raw < 0 && !a.loggedPoll {
				// A negative poll is a kernel refusal (not an empty queue):
				// surface it instead of spinning silently.
				vi.ConsoleLine(markerPollErr + itoa64(raw))
				a.loggedPoll = true
			}
			// Poll at ~10 Hz: the browser does not need finer input
			// latency, and quiet tasks leave the shell's idle loop (which
			// paces the composite and services the scanout snapshot) room
			// to run on this single-user machine.
			vi.Sleep(10)
			continue
		}
		a.events++
		if a.events <= 8 {
			vi.ConsoleLine(markerEvent + "kind=" + itoa(int(ev.Kind)) + " a0=" + itoa(int(ev.Arg0)) + " a1=" + itoa(int(ev.Arg1)))
		}
		switch ev.Kind {
		case vi.EvWinClose:
			a.quit = true
		case vi.EvKeyDown:
			a.key(ev.Arg0, ev.Flags)
		case vi.EvMouseDown:
			a.click(int(ev.Arg0), int(ev.Arg1))
		case vi.EvMouseMove:
			a.move(int(ev.Arg0), int(ev.Arg1))
		}
		if a.dirty {
			a.render()
			a.dirty = false
		}
	}
	vi.ConsoleLine(markerQuit)
	vi.WinClose(a.win)
	vi.Exit(0)
}

// --- navigation -----------------------------------------------------------

// showStartSurface renders the "nothing loaded" page (still a real page: the
// same pipeline, no special-casing of the viewport).
func (a *app) showStartSurface() {
	body := []byte("<h1>VirelaiOS Browser</h1><p>No target. Pass a path or an HTTP URL on the command line:</p>" +
		"<pre>exec WEB.ELF /host/PAGE.HTML\nexec WEB.ELF http://10.0.0.2/</pre>" +
		"<p>This browser has no JavaScript and no CSS cascade: pages render with a fixed built-in style table.</p>")
	a.target = ""
	a.title = "Start"
	a.loadBody(body, "/")
	a.render()
	vi.ConsoleLine(markerSettled)
}

func (a *app) navigate(target, from string) {
	resolved, kind := resolveInput(target)
	if kind == "empty" {
		a.setError("url", target)
		a.dirty = true
		return
	}
	if kind == "unsupported" {
		a.setError("scheme", resolved)
		a.dirty = true
		return
	}
	a.target = resolved
	a.scroll = 0
	vi.ConsoleLine(markerURL + resolved)

	body, errKind := a.fetch(resolved)
	if errKind != "" {
		a.setError(errKind, resolved)
	} else {
		a.loadBody(body, resolved)
	}
	a.hist.push(entry{Target: resolved, Title: a.title})
	a.persistHistory(resolved)
	a.dirty = true
}

// fetch returns the page bytes or a short error kind. Network failures are
// distinct kinds so the error page can be honest about what happened.
func (a *app) fetch(target string) ([]byte, string) {
	if strings.HasPrefix(strings.ToLower(target), "http://") {
		u, ok := webrender.ParseHTTPURL(target)
		if !ok {
			return nil, "url"
		}
		if !u.IsIP {
			// No resolver in this slice: say so instead of hanging.
			return nil, "dns"
		}
		if rc := vi.TCPConnect(u.IPv4, u.Port); rc < 0 {
			return nil, "tcp"
		}
		defer vi.TCPClose()
		req := webrender.FormatGetRequest(u.Host, u.Path)
		if _, rc := vi.TCPSend([]byte(req)); rc < 0 {
			return nil, "tcp"
		}
		buf := make([]byte, 0, 8192)
		chunk := make([]byte, 1024)
		idle := 0
		for len(buf) < vi.MaxFileBytes {
			n, rc := vi.TCPRecv(chunk)
			if rc < 0 {
				return nil, "tcp"
			}
			if n == 0 {
				if len(buf) > 0 {
					break // the responder closes after the body
				}
				idle++
				if idle > 900 {
					return nil, "timeout"
				}
				vi.Sleep(1)
				continue
			}
			idle = 0
			buf = append(buf, chunk[:n]...)
		}
		if len(buf) == 0 {
			return nil, "timeout"
		}
		head, body, ok := webrender.SplitHTTPResponse(buf)
		if !ok {
			return nil, "truncated"
		}
		if code := webrender.HTTPStatus(head); code != 200 {
			a.status = "HTTP " + itoa(code)
			return nil, "http"
		}
		if len(body) == 0 {
			return nil, "empty"
		}
		return body, ""
	}

	body, rc := vi.ReadFileAll(target, vi.MaxFileBytes)
	if rc < 0 {
		return nil, "file"
	}
	if len(body) == 0 {
		return nil, "empty"
	}
	return body, ""
}

// loadBody runs the renderer pipeline and emits the parse/layout markers.
func (a *app) loadBody(body []byte, target string) {
	a.errKind, a.errMsg = "", ""
	a.doc = webrender.ParseHTML(body)
	a.lay = webrender.LayoutDocument(a.doc, contentW, nil)
	a.scroll = 0
	vi.ConsoleLine(markerParse + itoa(a.doc.Nodes) + " text=" + itoa(a.doc.TextBytes) + " truncated=" + boolStr(a.doc.Truncated))
	vi.ConsoleLine(markerLayout + itoa(a.lay.Blocks) + " lines=" + itoa(a.lay.Lines) + " h=" + itoa(a.lay.Height))
	a.title = pageTitle(a.doc, target)
	a.status = ""
	a.logPaint = true
	a.dirty = true
}

func (a *app) setError(kind, target string) {
	a.errKind = kind
	a.errMsg = errorMessage(kind, target)
	a.lay = nil
	a.doc = nil
	a.scroll = 0
	a.title = "Error"
	a.logPaint = true
	vi.ConsoleLine(markerError + kind)
	a.dirty = true
}

// --- events ---------------------------------------------------------------

func (a *app) key(usage uint32, flags uint16) {
	alt := flags&vi.ModAlt != 0
	ctrl := flags&vi.ModCtrl != 0
	page := contentH - 16
	if page < 16 {
		page = 16
	}
	switch usage {
	case keyQ:
		a.quit = true
	case keyEscape:
		a.status = "stopped"
		a.dirty = true
	case keyR, keyF5:
		a.reload()
	case keyUp:
		a.scrollBy(-16)
	case keyDown:
		a.scrollBy(16)
	case keyPageUp:
		a.scrollBy(-page)
	case keyPageDown:
		a.scrollBy(page)
	case keyHome:
		a.scroll = 0
		a.dirty = true
	case keyEnd:
		a.scroll = webrender.ScrollMax(a.lay, contentH)
		a.dirty = true
	case keyBacksp, keyLeft:
		if usage == keyLeft && !alt {
			return
		}
		a.goBack()
	case keyRight:
		if !alt && !ctrl {
			return
		}
		a.goForward()
	}
}

func (a *app) click(x, y int) {
	switch {
	case inRect(x, y, backX, backY, chipW, chipH):
		a.goBack()
		return
	case inRect(x, y, fwdX, backY, chipW, chipH):
		a.goForward()
		return
	case inRect(x, y, reloadX, backY, chipW, chipH):
		a.reload()
		return
	}
	if y < contentY || y >= contentY+contentH || a.lay == nil {
		return
	}
	cx := x - contentX
	cy := y - contentY + a.scroll
	if target := webrender.HitTest(a.lay, cx, cy); target != "" {
		from := a.target
		resolved, kind := resolveInput(relativeTo(from, target))
		if kind == "empty" {
			return
		}
		a.navigate(resolved, from)
		if from != "" {
			a.announceNavigation()
		}
	}
}

func (a *app) move(x, y int) {
	if a.lay == nil || y < contentY {
		if a.hover != "" {
			a.hover = ""
			a.dirty = true
		}
		return
	}
	cx := x - contentX
	cy := y - contentY + a.scroll
	if target := webrender.HitTest(a.lay, cx, cy); target != a.hover {
		a.hover = target
		a.dirty = true
	}
}

func (a *app) goBack() {
	if e, ok := a.hist.back(); ok {
		a.navigate(e.Target, "")
		a.hist.replace(e)
		a.announceNavigation()
	}
}

func (a *app) goForward() {
	if e, ok := a.hist.forward(); ok {
		a.navigate(e.Target, "")
		a.hist.replace(e)
		a.announceNavigation()
	}
}

// announceNavigation paints the newly loaded page FIRST and only then prints
// the navigation markers, so `web: navigated` means "the new page is on
// screen" — the gate snapshots on that line. (Observed live: printing the
// markers inside navigate() let the snapshot capture the previous page.)
func (a *app) announceNavigation() {
	// Present, let the shell's idle path composite, then present again — the
	// same shape as settleRepaint, and for the same observed reason: a single
	// present immediately after a blocking fetch can be composited late, so a
	// marker printed right after it would still describe the previous frame.
	a.render()
	vi.Sleep(10)
	a.render()
	a.dirty = false
	a.navCount++
	vi.ConsoleLine(markerNav + a.target)
	vi.ConsoleLine(markerNavigated)
	// A navigation gets its own settle marker: the gate snapshots on
	// `web: navigated` and exits on this line, so the framebuffer stream is
	// never cut off by the run ending (same reason as markerReady).
	vi.Sleep(5)
	vi.ConsoleLine(markerNavReady)
}

func (a *app) reload() {
	if a.target == "" {
		a.showStartSurface()
		return
	}
	a.status = "reloading"
	a.navigate(a.target, "")
}

func (a *app) scrollBy(d int) {
	if a.lay == nil {
		return
	}
	a.scroll += d
	if a.scroll < 0 {
		a.scroll = 0
	}
	if max := webrender.ScrollMax(a.lay, contentH); a.scroll > max {
		a.scroll = max
	}
	a.dirty = true
}

// --- painting -------------------------------------------------------------

func (a *app) render() {
	f := &a.filler
	vs := virender{f: f, win: a.win}
	clip := webrender.Clip{X: 0, Y: 0, W: winW, H: winH}

	// Title band.
	f.Rect(a.win, 0, titleY, winW, titleH, webrender.ColorChromeBg)
	webrender.DrawText(vs, 6, titleY+4, fit("WEB.ELF  "+a.title, (winW-72)/8), 1, false, webrender.ColorChromeInk, clip)
	webrender.DrawText(vs, winW-58, titleY+4, "JS: off", 1, false, webrender.ColorError, clip)

	// URL row.
	f.Rect(a.win, 0, urlRowY, winW, urlRowH, webrender.ColorChromeBg)
	chevBack := webrender.ColorMuted
	if a.hist.canBack() {
		chevBack = webrender.ColorChromeInk
	}
	chevFwd := webrender.ColorMuted
	if a.hist.canForward() {
		chevFwd = webrender.ColorChromeInk
	}
	webrender.DrawText(vs, backX+3, backY+3, "<", 1, false, chevBack, clip)
	webrender.DrawText(vs, fwdX+3, backY+3, ">", 1, false, chevFwd, clip)
	webrender.DrawText(vs, reloadX+3, backY+3, "R", 1, false, webrender.ColorChromeInk, clip)

	f.Rect(a.win, urlX, urlY, urlW, urlH, webrender.ColorSurface)
	f.Rect(a.win, urlX, urlY, urlW, 1, webrender.ColorRule)
	shown := a.target
	if shown == "" {
		shown = "(no target)"
	}
	webrender.DrawText(vs, urlX+4, urlY+3, fit(shown, (urlW-8)/8), 1, false, webrender.ColorChromeInk, clip)

	// Content.
	f.Rect(a.win, 0, contentY, winW, contentH, webrender.ColorPageBg)
	if a.lay != nil {
		webrender.Paint(a.lay, vs, contentX, contentY, contentW, contentH, a.scroll)
		a.painted = len(a.lay.Items)
	} else {
		a.paintErrorPage(vs)
	}

	// Status line (drawn last so nothing can cover it).
	f.Rect(a.win, 0, winH-statusH, winW, statusH, webrender.ColorChromeBg)
	webrender.DrawText(vs, 6, winH-statusH+2, fit(a.statusText(), winW/8-2), 1, false, webrender.ColorMuted, clip)

	processed := f.Flush()
	a.lastFills = processed
	vi.WinPresent(a.win)
	if a.logPaint {
		vi.ConsoleLine(markerPaint + itoa(itemsOf(a)) + " fills=" + itoa(processed))
		a.logPaint = false
	}
}

func itemsOf(a *app) int {
	if a.lay == nil {
		return 0
	}
	return len(a.lay.Items)
}

func (a *app) statusText() string {
	if a.hover != "" {
		return "link: " + a.hover
	}
	if a.status != "" {
		return a.status
	}
	if a.lay == nil {
		return "error"
	}
	max := webrender.ScrollMax(a.lay, contentH)
	return "nodes=" + itoa(nodeCount(a.doc)) + " blocks=" + itoa(a.lay.Blocks) +
		" lines=" + itoa(a.lay.Lines) + " items=" + itoa(len(a.lay.Items)) +
		" scroll=" + itoa(a.scroll) + "/" + itoa(max)
}

func (a *app) paintErrorPage(vs virender) {
	clip := webrender.Clip{X: contentX, Y: contentY, W: contentW, H: contentH}
	y := contentY + 12
	webrender.DrawText(vs, contentX, y, "This page could not be loaded", 2, true, webrender.ColorText, clip)
	y += 26
	webrender.DrawText(vs, contentX, y, fit(a.errMsg, contentW/8), 1, false, webrender.ColorError, clip)
	y += 18
	webrender.DrawText(vs, contentX, y, fit("target: "+a.describeTarget(), contentW/8), 1, false, webrender.ColorMuted, clip)
	y += 18
	webrender.DrawText(vs, contentX, y, "kind: "+a.errKind, 1, false, webrender.ColorMuted, clip)
	y += 24
	webrender.DrawText(vs, contentX, y, "R reloads  < back  > forward  Esc stop  Q quit", 1, false, webrender.ColorMuted, clip)
}

func (a *app) describeTarget() string {
	if a.target == "" {
		return "(none)"
	}
	return a.target
}

func (a *app) persistHistory(target string) {
	if !vi.FileExists(historyPath) {
		vi.FileAppend(historyPath, []byte(historySchema+"\n"))
	}
	line := itoa64(vi.Time()) + "\t" + target + "\n"
	vi.FileAppend(historyPath, []byte(line))
}

// --- pure helpers (host-tested) -------------------------------------------

// resolveInput classifies a command-line target or address-bar entry.
func resolveInput(in string) (string, string) {
	s := strings.TrimSpace(in)
	if s == "" {
		return "", "empty"
	}
	low := strings.ToLower(s)
	switch {
	case strings.HasPrefix(low, "http://"):
		return s, "http"
	case strings.HasPrefix(low, "https://"), strings.Contains(low, "://"):
		return s, "unsupported"
	case strings.HasPrefix(s, "/"):
		return s, "file"
	}
	return "/host/" + s, "file"
}

// relativeTo resolves an href found on a page against the page's own target.
func relativeTo(base, href string) string {
	if strings.HasPrefix(strings.ToLower(href), "http://") {
		return href
	}
	if strings.HasPrefix(strings.ToLower(base), "http://") {
		if strings.HasPrefix(href, "/") {
			if u, ok := webrender.ParseHTTPURL(base); ok {
				return "http://" + u.Host + href
			}
		}
		if resolved, ok := webrender.ResolveHref(base, href); ok {
			return resolved
		}
		return href
	}
	if base == "" {
		return href
	}
	if resolved, ok := webrender.ResolveHref(base, href); ok {
		return resolved
	}
	return href
}

func pageTitle(doc *webrender.Document, target string) string {
	if doc != nil {
		for _, it := range doc.Root.Children {
			if t := firstHeading(it); t != "" {
				return t
			}
		}
	}
	if i := strings.LastIndexByte(target, '/'); i >= 0 && i+1 < len(target) {
		return target[i+1:]
	}
	return target
}

func firstHeading(n *webrender.Node) string {
	if n.Kind == webrender.KindElement && (n.Tag == "h1" || n.Tag == "h2" || n.Tag == "title") {
		if t := strings.TrimSpace(webrender.TextContent(n)); t != "" {
			return t
		}
	}
	for _, c := range n.Children {
		if t := firstHeading(c); t != "" {
			return t
		}
	}
	return ""
}

func nodeCount(doc *webrender.Document) int {
	if doc == nil {
		return 0
	}
	return doc.Nodes
}

// fit truncates s so it fits in cols 8-pixel columns, marking the cut.
func fit(s string, cols int) string {
	if cols < 1 {
		cols = 1
	}
	s = webrender.UpperASCII(s)
	if len(s) <= cols {
		return s
	}
	if cols <= 2 {
		return s[:cols]
	}
	return s[:cols-2] + ".."
}

func inRect(x, y, rx, ry, rw, rh int) bool {
	return x >= rx && x < rx+rw && y >= ry && y < ry+rh
}

func boolStr(b bool) string {
	if b {
		return "yes"
	}
	return "no"
}

func errorMessage(kind, target string) string {
	switch kind {
	case "file":
		return "No such file on the share (expected " + target + ")."
	case "dns":
		return "This slice resolves IP literals only; use http://10.0.0.2/ style URLs."
	case "tcp":
		return "TCP connect, send, or receive failed."
	case "timeout":
		return "The server did not answer in time."
	case "truncated":
		return "The response ended before its headers were complete."
	case "empty":
		return "The target produced zero bytes."
	case "http":
		return "The server answered with a non-200 status."
	case "scheme":
		return "Only http:// and the local file channel are supported."
	}
	return "Unrecognised target."
}

func itoa(n int) string {
	if n == 0 {
		return "0"
	}
	neg := n < 0
	if neg {
		n = -n
	}
	var buf [24]byte
	i := len(buf)
	for n > 0 {
		i--
		buf[i] = byte('0' + n%10)
		n /= 10
	}
	if neg {
		i--
		buf[i] = '-'
	}
	return string(buf[i:])
}

func itoa64(n int64) string {
	if n == 0 {
		return "0"
	}
	neg := n < 0
	if neg {
		n = -n
	}
	var buf [24]byte
	i := len(buf)
	for n > 0 {
		i--
		buf[i] = byte('0' + n%10)
		n /= 10
	}
	if neg {
		i--
		buf[i] = '-'
	}
	return string(buf[i:])
}
