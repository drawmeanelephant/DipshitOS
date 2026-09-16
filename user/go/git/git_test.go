package main

import (
	"bytes"
	"compress/zlib"
	"crypto/sha1"
	"testing"
)

func TestSHA1MatchesStdlib(t *testing.T) {
	cases := [][]byte{
		nil,
		[]byte(""),
		[]byte("abc"),
		[]byte("hello, git\n"),
		bytes.Repeat([]byte("x"), 1000),
	}
	for _, c := range cases {
		got := sha1Sum(c)
		want := sha1.Sum(c)
		if got != want {
			t.Fatalf("sha1(%q) = %x want %x", c, got, want)
		}
	}
}

func TestHexRoundTrip(t *testing.T) {
	sum := sha1Sum([]byte("blob"))
	s := hexEncode(sum[:])
	if len(s) != 40 {
		t.Fatalf("hex len %d", len(s))
	}
	back, ok := hexDecode(s)
	if !ok || back != sum {
		t.Fatalf("hexDecode(%q) = %x ok=%v", s, back, ok)
	}
	if _, ok := hexDecode("zz"); ok {
		t.Fatal("bad hex accepted")
	}
}

func TestPktLineRoundTrip(t *testing.T) {
	raw := pktEncodeString("want abc\n")
	p, rest, err := pktRead(raw)
	if err != nil || len(rest) != 0 || p.Flush {
		t.Fatalf("pktRead = %+v rest=%q err=%v", p, rest, err)
	}
	if string(p.Data) != "want abc\n" {
		t.Fatalf("data = %q", p.Data)
	}
	fl, rest, err := pktRead(pktFlush())
	if err != nil || !fl.Flush || len(rest) != 0 {
		t.Fatalf("flush = %+v", fl)
	}
}

func TestPktLineSplitStopsAtPackTail(t *testing.T) {
	var buf []byte
	buf = append(buf, pktEncodeString("NAK\n")...)
	buf = append(buf, []byte("PACK")...)
	pkts, leftover, err := pktSplit(buf)
	if err != nil {
		t.Fatal(err)
	}
	if len(pkts) != 1 || string(pkts[0].Data) != "NAK\n" {
		t.Fatalf("pkts = %+v", pkts)
	}
	if string(leftover) != "PACK" {
		t.Fatalf("leftover = %q", leftover)
	}
}

func TestInflateMatchesStdlibZlib(t *testing.T) {
	payloads := [][]byte{
		[]byte("hello, git\n"),
		bytes.Repeat([]byte("The quick brown fox. "), 40),
		[]byte{0, 1, 2, 3, 255},
	}
	for _, p := range payloads {
		var buf bytes.Buffer
		w := zlib.NewWriter(&buf)
		if _, err := w.Write(p); err != nil {
			t.Fatal(err)
		}
		if err := w.Close(); err != nil {
			t.Fatal(err)
		}
		out := make([]byte, len(p)+8)
		n, consumed, err := inflateZlib(buf.Bytes(), out)
		if err != nil {
			t.Fatalf("inflate %q: %v", p, err)
		}
		if n != len(p) || !bytes.Equal(out[:n], p) {
			t.Fatalf("got %q want %q", out[:n], p)
		}
		if consumed != buf.Len() {
			t.Fatalf("consumed %d want %d", consumed, buf.Len())
		}
	}
}

func TestZlibStoreRoundTrip(t *testing.T) {
	p := []byte("hello, git\n")
	z := zlibStore(p)
	out := make([]byte, len(p)+4)
	n, _, err := inflateZlib(z, out)
	if err != nil || n != len(p) || !bytes.Equal(out[:n], p) {
		t.Fatalf("store roundtrip n=%d err=%v got=%q", n, err, out[:n])
	}
}

func TestDeltaCopyInsert(t *testing.T) {
	base := []byte("hello, git\n")
	target := []byte("hello, git!\n")
	d := encodeDelta(base, target)
	got, err := applyDelta(base, d)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(got, target) {
		t.Fatalf("delta = %q want %q", got, target)
	}
}

func TestPackRefDelta(t *testing.T) {
	blob1 := gitObj{Type: objBlob, Data: []byte("hello, git\n")}
	blob1.ID = hashObject(objBlob, blob1.Data)
	blob2 := gitObj{Type: objBlob, Data: []byte("hello, git!\n")}
	blob2.ID = hashObject(objBlob, blob2.Data)
	tree := gitObj{Type: objTree, Data: encodeTree([]treeEnt{{Mode: "100644", Name: "HELLO", ID: blob2.ID}})}
	tree.ID = hashObject(objTree, tree.Data)
	commitData := []byte("tree " + hexEncode(tree.ID[:]) + "\n" +
		"author g <g@g> 1000000000 +0000\n" +
		"committer g <g@g> 1000000000 +0000\n\nsecond\n")
	commit := gitObj{Type: objCommit, Data: commitData}
	commit.ID = hashObject(objCommit, commit.Data)

	objs := []gitObj{blob1, blob2, tree, commit}
	deltaFrom := []int{-1, 0, -1, -1}
	pack := packObjects(objs, deltaFrom, nil)
	got, nDelta, err := parsePack(pack)
	if err != nil {
		t.Fatal(err)
	}
	if nDelta != 1 {
		t.Fatalf("nDelta = %d want 1", nDelta)
	}
	if len(got) != 4 {
		t.Fatalf("len = %d", len(got))
	}
	if got[1].ID != blob2.ID || !bytes.Equal(got[1].Data, blob2.Data) {
		t.Fatalf("delta blob mismatch %x vs %x", got[1].ID, blob2.ID)
	}
	if got[2].ID != tree.ID || got[3].ID != commit.ID {
		t.Fatalf("tree/commit ids")
	}
}

func TestPackOfsDelta(t *testing.T) {
	blob1 := gitObj{Type: objBlob, Data: []byte("hello, git\n")}
	blob1.ID = hashObject(objBlob, blob1.Data)
	blob2 := gitObj{Type: objBlob, Data: []byte("hello, git!\n")}
	blob2.ID = hashObject(objBlob, blob2.Data)
	objs := []gitObj{blob1, blob2}
	pack := packObjects(objs, []int{-1, 0}, []bool{false, true})
	got, nDelta, err := parsePack(pack)
	if err != nil {
		t.Fatal(err)
	}
	if nDelta != 1 {
		t.Fatalf("nDelta = %d", nDelta)
	}
	if got[1].ID != blob2.ID || !bytes.Equal(got[1].Data, blob2.Data) {
		t.Fatalf("ofs-delta blob mismatch")
	}
}

func TestOfsRoundTrip(t *testing.T) {
	for _, v := range []int{1, 2, 127, 128, 129, 1000, 20000} {
		enc := encodeOfs(v)
		off, n, err := readOfsDelta(enc)
		if err != nil || n != len(enc) || off != v {
			t.Fatalf("ofs %d: got %d n=%d err=%v enc=%x", v, off, n, err, enc)
		}
	}
}

func TestInfoRefsAndWant(t *testing.T) {
	sha := hashObject(objCommit, []byte("x"))
	hex := hexEncode(sha[:])
	var body []byte
	body = append(body, pktEncodeString("# service=git-upload-pack\n")...)
	body = append(body, pktFlush()...)
	first := hex + " HEAD\x00multi_ack thin-pack\n"
	body = append(body, pktEncodeString(first)...)
	body = append(body, pktEncodeString(hex+" refs/heads/main\n")...)
	body = append(body, pktFlush()...)
	refs, err := parseInfoRefs(body)
	if err != nil {
		t.Fatal(err)
	}
	if len(refs) != 2 {
		t.Fatalf("refs = %d", len(refs))
	}
	want, ok := pickWant(refs)
	if !ok || want.Name != "refs/heads/main" {
		t.Fatalf("pick = %+v", want)
	}
	wb := wantBody(want.SHA)
	if !bytes.Contains(wb, []byte("want "+hex)) || !bytes.Contains(wb, []byte("done\n")) {
		t.Fatalf("want body = %q", wb)
	}
}

func TestSplitHTTPAndExtractPack(t *testing.T) {
	pack := packObjects([]gitObj{{Type: objBlob, Data: []byte("a"), ID: hashObject(objBlob, []byte("a"))}}, nil, nil)
	resp := append([]byte("HTTP/1.0 200 OK\r\nContent-Type: application/x-git-upload-pack-result\r\n\r\n"), pktEncodeString("NAK\n")...)
	resp = append(resp, pack...)
	st, body, err := splitHTTP(resp)
	if err != nil || st != 200 {
		t.Fatalf("http st=%d err=%v", st, err)
	}
	got, err := extractPack(body)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(got, pack) {
		t.Fatalf("pack mismatch %d vs %d", len(got), len(pack))
	}
	raw := append(pktEncodeString("# service=git-upload-pack\n"), pktFlush()...)
	st, body, err = splitHTTP(raw)
	if err != nil || st != 200 || !bytes.Equal(body, raw) {
		t.Fatalf("pkt-line fallback st=%d err=%v", st, err)
	}
}

func TestSidebandExtractPack(t *testing.T) {
	pack := packObjects([]gitObj{{Type: objBlob, Data: []byte("a"), ID: hashObject(objBlob, []byte("a"))}}, nil, nil)
	var body []byte
	body = append(body, pktEncodeString("NAK\n")...)
	chunk := append([]byte{1}, pack...)
	body = append(body, pktEncode(chunk)...)
	body = append(body, pktFlush()...)
	got, err := extractPack(body)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(got, pack) {
		t.Fatalf("sideband pack mismatch")
	}
}

func TestPlanHelperNeverCleartext(t *testing.T) {
	https := classify("https://10.0.0.2:24541/g.git")
	if https.Kind != kindHTTPS || https.Path != "/g.git" {
		t.Fatalf("classify = %+v", https)
	}
	if wouldSendCleartext(https) {
		t.Fatal("https flagged cleartext")
	}
	plan, ok := planHelper(https, "GET", "/host/G/.git/P", "/host/G/.git/O", "")
	if !ok || plan.Name != helperName {
		t.Fatalf("plan = %+v ok=%v", plan, ok)
	}
	if len(plan.Args) != 6 || plan.Args[3] != "GET" {
		t.Fatalf("args = %v", plan.Args)
	}
	http := classify("http://10.0.0.2/g.git")
	if !wouldSendCleartext(http) {
		t.Fatal("http must be cleartext")
	}
	if _, ok := planHelper(http, "GET", "/host/G/.git/P", "/host/G/.git/O", ""); ok {
		t.Fatal("http produced a helper plan")
	}
	post, ok := planHelper(https, "POST", "/host/G/.git/P", "/host/G/.git/O", "/host/G/.git/B")
	if !ok || post.Args[3] != "POST" || post.Args[6] != "/host/G/.git/B" {
		t.Fatalf("post plan = %v", post.Args)
	}
	for _, a := range post.Args {
		if len(a) > 31 {
			t.Fatalf("argv slot %q exceeds 31", a)
		}
	}
}

func TestObjectPathFits(t *testing.T) {
	id := hashObject(objBlob, []byte("hello, git!\n"))
	p, ok := objectPath("/host/G/.git", id)
	if !ok {
		t.Fatal("object path refused")
	}
	if len(p) > maxPath {
		t.Fatalf("path len %d > %d: %s", len(p), maxPath, p)
	}
	ents := parseTree(encodeTree([]treeEnt{{Mode: "100644", Name: "HELLO", ID: id}}))
	if len(ents) != 1 || ents[0].Name != "HELLO" || ents[0].ID != id {
		t.Fatalf("tree ents = %+v", ents)
	}
}

func TestLooseObjectInflates(t *testing.T) {
	o := gitObj{Type: objBlob, Data: []byte("hello, git!\n")}
	o.ID = hashObject(objBlob, o.Data)
	z := looseBytes(o)
	out := make([]byte, 64)
	n, _, err := inflateZlib(z, out)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.HasPrefix(out[:n], []byte("blob ")) || !bytes.Contains(out[:n], o.Data) {
		t.Fatalf("loose = %q", out[:n])
	}
}

func TestMarkers(t *testing.T) {
	cases := []struct{ got, want string }{
		{markerStart, "gotgit: start"},
		{markerOK, "gotgit OK"},
		{markerBlob, "gotgit: blob "},
		{markerTree, "gotgit: tree "},
		{markerCommit, "gotgit: commit "},
		{markerDelta, "gotgit: delta"},
		{helperName, "FETCHS.BIN"},
	}
	for _, c := range cases {
		if c.got != c.want {
			t.Fatalf("marker = %q want %q", c.got, c.want)
		}
	}
}
