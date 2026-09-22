package main

import (
	"strings"
	"testing"
)

func TestBrowserHandoffKeepsTheFullLink(t *testing.T) {
	link := "https://example.com/posts/1-a-long-article-slug"
	if len(link) <= execArgMax {
		t.Fatalf("fixture must be longer than the exec cap, len=%d", len(link))
	}
	path, body, arg, ok := browserHandoff(link)
	if !ok {
		t.Fatal("handoff refused a usable link")
	}
	if len(arg) > execArgMax {
		t.Fatalf("exec arg %q is %d bytes, cap is %d", arg, len(arg), execArgMax)
	}
	if arg != "@"+linkFile || path != linkFile {
		t.Fatalf("path=%q arg=%q", path, arg)
	}
	if strings.TrimRight(string(body), "\n") != link {
		t.Fatalf("file body = %q, want the full link", body)
	}
	if _, _, _, ok := browserHandoff(""); ok {
		t.Fatal("empty link must not launch")
	}
}
