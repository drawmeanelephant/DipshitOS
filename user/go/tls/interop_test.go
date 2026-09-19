// End-to-end interop: this client handshakes against the host Go stdlib's
// crypto/tls server (OpenSSL-heritage, FIPS-validated primitives) over a
// real TCP connection — TLS 1.3 only, TLS_AES_128_GCM_SHA256, an ECDSA
// P-256 chain, bidirectional application data, and fail-closed negatives
// (wrong hostname, untrusted root). This is the same interop shape the Zig
// client pins in user/src/lib/tls/interop/, with the peers reversed.

package tls

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"math/big"
	"net"
	"testing"
	"time"
)

// buildTestChain makes a CA and a server leaf for serverName with SANs for
// the names given. Returns the CA DER (the client's anchor) and the
// tls.Certificate for the server.
func buildTestChain(t *testing.T, dnsNames ...string) ([]byte, tls.Certificate) {
	t.Helper()
	caKey, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	caTmpl := &x509.Certificate{
		SerialNumber:          big.NewInt(1),
		Subject:               pkix.Name{CommonName: "interop test root"},
		NotBefore:             time.Now().Add(-time.Hour),
		NotAfter:              time.Now().Add(time.Hour),
		IsCA:                  true,
		BasicConstraintsValid: true,
		KeyUsage:              x509.KeyUsageCertSign | x509.KeyUsageDigitalSignature,
	}
	caDER, err := x509.CreateCertificate(rand.Reader, caTmpl, caTmpl, &caKey.PublicKey, caKey)
	if err != nil {
		t.Fatal(err)
	}
	caCert, err := x509.ParseCertificate(caDER)
	if err != nil {
		t.Fatal(err)
	}

	leafKey, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	leafTmpl := &x509.Certificate{
		SerialNumber: big.NewInt(2),
		Subject:      pkix.Name{CommonName: dnsNames[0]},
		NotBefore:    time.Now().Add(-time.Hour),
		NotAfter:     time.Now().Add(time.Hour),
		DNSNames:     dnsNames,
		KeyUsage:     x509.KeyUsageDigitalSignature,
		ExtKeyUsage:  []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth},
	}
	leafDER, err := x509.CreateCertificate(rand.Reader, leafTmpl, caCert, &leafKey.PublicKey, caKey)
	if err != nil {
		t.Fatal(err)
	}
	return caDER, tls.Certificate{Certificate: [][]byte{leafDER, caDER}, PrivateKey: leafKey}
}

// startTLSServer runs a TLS 1.3-only server on the loopback; it echoes one
// request and closes.
func startTLSServer(t *testing.T, cert tls.Certificate, cfgHook func(*tls.Config)) (addr string, done chan error) {
	t.Helper()
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	done = make(chan error, 1)
	go func() {
		defer ln.Close()
		cfg := &tls.Config{
			Certificates: []tls.Certificate{cert},
			MinVersion:   tls.VersionTLS13,
			MaxVersion:   tls.VersionTLS13,
			CipherSuites: []uint16{tls.TLS_AES_128_GCM_SHA256},
		}
		if cfgHook != nil {
			cfgHook(cfg)
		}
		conn, err := ln.Accept()
		if err != nil {
			done <- err
			return
		}
		defer conn.Close()
		sc := tls.Server(conn, cfg)
		if err := sc.Handshake(); err != nil {
			done <- err
			return
		}
		buf := make([]byte, 512)
		n, err := sc.Read(buf)
		if err != nil {
			done <- err
			return
		}
		if _, err := sc.Write(append([]byte("echo:"), buf[:n]...)); err != nil {
			done <- err
			return
		}
		done <- nil
	}()
	return ln.Addr().String(), done
}

type netTransport struct {
	conn net.Conn
	rbuf []byte
}

func (n *netTransport) read(p []byte) (int, error) {
	if n.rbuf == nil {
		n.rbuf = make([]byte, 0, 4096)
	}
	if len(n.rbuf) == 0 {
		tmp := make([]byte, 4096)
		m, err := n.conn.Read(tmp)
		if err != nil {
			return 0, err
		}
		n.rbuf = tmp[:m]
	}
	c := copy(p, n.rbuf)
	n.rbuf = n.rbuf[c:]
	return c, nil
}

func (n *netTransport) write(p []byte) (int, error) { return n.conn.Write(p) }
func (n *netTransport) close() error                { return n.conn.Close() }

func TestInteropWithHostStdlib(t *testing.T) {
	caDER, cert := buildTestChain(t, "interop.example.com")
	store := newTrustStore("interop")
	if err := store.addRoot(caDER); err != nil {
		t.Fatal(err)
	}
	addr, done := startTLSServer(t, cert, nil)

	conn, err := net.Dial("tcp", addr)
	if err != nil {
		t.Fatal(err)
	}
	nt := &netTransport{conn: conn}
	cl := newClient(nt, "interop.example.com", time.Now().Unix(), func(p []byte) error {
		_, err := rand.Read(p)
		return err
	}, true)
	// The client resolves anchors through defaultStore; the test chain is
	// injected by temporarily validating directly. Simplest honest path:
	// point the handshake's validation at this store.
	cl.store = store
	if err := cl.handshake(); err != nil {
		t.Fatalf("handshake failed: %v", err)
	}
	if !cl.state.allowsApplicationData() {
		t.Fatal("not connected after handshake")
	}
	if cl.lastValidation != resultValid {
		t.Fatalf("validation verdict %v", cl.lastValidation)
	}

	req := []byte("ping interop")
	if err := cl.write(req); err != nil {
		t.Fatal(err)
	}
	buf := make([]byte, 256)
	n, err := cl.read(buf)
	if err != nil {
		t.Fatal(err)
	}
	if string(buf[:n]) != "echo:"+string(req) {
		t.Fatalf("echo mismatch: %q", buf[:n])
	}
	_ = cl.close()
	if err := <-done; err != nil {
		t.Fatalf("server side: %v", err)
	}
}

func TestInteropNegativesFailClosed(t *testing.T) {
	caDER, cert := buildTestChain(t, "interop.example.com")
	store := newTrustStore("interop")
	_ = store.addRoot(caDER)
	addr, done := startTLSServer(t, cert, nil)

	// Wrong hostname: the handshake must fail closed. The server may reject
	// the unknown SNI first (unrecognized_name alert), or the connection
	// reaches our own validation and fails with hostname_mismatch — either
	// way, no application data flows and the client is not usable.
	conn, err := net.Dial("tcp", addr)
	if err != nil {
		t.Fatal(err)
	}
	nt := &netTransport{conn: conn}
	cl := newClient(nt, "wrong.example.com", time.Now().Unix(), func(p []byte) error {
		_, err := rand.Read(p)
		return err
	}, true)
	cl.store = store
	err = cl.handshake()
	_ = nt.close()
	if err == nil {
		t.Fatal("wrong-hostname handshake succeeded")
	}
	if cl.state.allowsApplicationData() {
		t.Fatal("wrong-hostname client reached connected")
	}
	if cl.lastValidation != resultValid && cl.lastValidation != resultHostnameMismatch {
		t.Fatalf("verdict %v", cl.lastValidation)
	}
	<-done // the server may see an alert or a closed conn; either is fine

	// Untrusted root: no_path_to_root.
	_, cert2 := buildTestChain(t, "interop.example.com")
	addr2, done2 := startTLSServer(t, cert2, nil)
	conn2, err := net.Dial("tcp", addr2)
	if err != nil {
		t.Fatal(err)
	}
	nt2 := &netTransport{conn: conn2}
	cl2 := newClient(nt2, "interop.example.com", time.Now().Unix(), func(p []byte) error {
		_, err := rand.Read(p)
		return err
	}, true)
	cl2.store = newTrustStore("empty") // no anchors at all
	err = cl2.handshake()
	_ = nt2.close()
	if err == nil {
		t.Fatal("untrusted-root handshake succeeded")
	}
	if cl2.lastValidation != resultNoPathToRoot {
		t.Fatalf("verdict %v, want no_path_to_root", cl2.lastValidation)
	}
	<-done2
}
