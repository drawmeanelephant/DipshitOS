package main

import (
	"bytes"
	"testing"

	"virelai/git/gitread"
)

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
		t.Fatalf("flush = %+v rest=%q err=%v", fl, rest, err)
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

func TestInfoRefsAndWant(t *testing.T) {
	sha := gitread.HashObject(gitread.ObjCommit, []byte("x"))
	hex := gitread.HexEncode(sha[:])
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
	pack := gitread.PackObjects([]gitread.GitObj{{Type: gitread.ObjCommit, Data: []byte("a"), ID: gitread.HashObject(gitread.ObjCommit, []byte("a"))}}, nil, nil)
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
	pack := gitread.PackObjects([]gitread.GitObj{{Type: gitread.ObjCommit, Data: []byte("a"), ID: gitread.HashObject(gitread.ObjCommit, []byte("a"))}}, nil, nil)
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

func TestHTTPSNeverCleartext(t *testing.T) {
	https := classify("https://10.0.0.2:24541/g.git")
	if https.Kind != kindHTTPS || https.Path != "/g.git" {
		t.Fatalf("classify = %+v", https)
	}
	if wouldSendCleartext(https) {
		t.Fatal("https flagged cleartext")
	}
	if https.SNI != defaultSNI || https.Port != 24541 {
		t.Fatalf("dial fields = %+v", https)
	}
	http := classify("http://10.0.0.2/g.git")
	if !wouldSendCleartext(http) {
		t.Fatal("http must be cleartext")
	}
	if http.Kind == kindHTTPS {
		t.Fatal("http must not classify as https")
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
		{markerDial, "gotgit: dial "},
		{markerHS, "gotgit: handshake ok"},
		{defaultSNI, "leaf.example.com"},
	}
	for _, c := range cases {
		if c.got != c.want {
			t.Fatalf("marker = %q want %q", c.got, c.want)
		}
	}
}
