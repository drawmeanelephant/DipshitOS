// Minimal TLS 1.3 server for the interop matrix (Go crypto/tls).
package main

import (
	"crypto/tls"
	"fmt"
	"net/http"
	"os"
)

func main() {
	certPath := os.Args[1]
	keyPath := os.Args[2]
	port := os.Args[3]

	cert, err := tls.LoadX509KeyPair(certPath, keyPath)
	if err != nil {
		panic(err)
	}
	srv := &http.Server{
		Addr: "127.0.0.1:" + port,
		TLSConfig: &tls.Config{
			Certificates: []tls.Certificate{cert},
			MinVersion:   tls.VersionTLS13,
			MaxVersion:   tls.VersionTLS13,
		},
	}
	http.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		fmt.Fprintf(w, "go-crypto/tls server: %s\n", r.TLS.Version == tls.VersionTLS13)
	})
	_ = srv.ListenAndServeTLS("", "")
}
