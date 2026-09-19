package main

import (
	"virelai/tls"
	"virelai/vi"
)

// One TLS 1.3 application record is at most 2^14 bytes; Client.read copies
// a whole record and parks the unread tail, so the read buffer is a full
// record. The total body is capped at the file-channel byte cap.
const (
	tlsRecordBuf = 16384
	tlsBodyCap   = vi.MaxFileBytes
)

func httpsDial(addr string, port uint16, sni string) (*tls.TLSConn, error) {
	return tls.Dial(addr, port, sni)
}

func httpsGetOn(c *tls.TLSConn, sni, path string) ([]byte, error) {
	if path == "" {
		path = "/"
	}
	host := sni
	if host == "" {
		host = "localhost"
	}
	req := "GET " + path + " HTTP/1.0\r\nHost: " + host + "\r\nConnection: close\r\n\r\n"
	if _, err := c.Write([]byte(req)); err != nil {
		return nil, err
	}
	return readTLS(c, tlsBodyCap)
}

func readTLS(c *tls.TLSConn, capn int) ([]byte, error) {
	tmp := make([]byte, tlsRecordBuf)
	var out []byte
	for len(out) < capn {
		n, err := c.Read(tmp)
		if n > 0 {
			out = append(out, tmp[:n]...)
		}
		if err != nil || n == 0 {
			if len(out) > 0 {
				return out, nil
			}
			return out, err
		}
	}
	return out, nil
}
