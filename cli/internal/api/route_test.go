package api

import (
	"context"
	"net/http"
	"net/http/httptest"
	"net/url"
	"testing"
	"time"
)

// Finder abandons reads all the time; a request its caller cancelled says
// nothing about the LAN, so the route must stay.
func TestCancelledRequestKeepsLANRoute(t *testing.T) {
	started := make(chan struct{})
	lan := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		close(started)
		<-r.Context().Done()
	}))
	defer lan.Close()
	internet := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		t.Error("a cancelled request was retried over the internet")
	}))
	defer internet.Close()
	base, _ := url.Parse(internet.URL)
	lanBase, _ := url.Parse(lan.URL)
	route := &LANRoute{}
	route.Set(&Route{Base: lanBase, Token: "ifl_x", Expires: time.Now().Add(time.Hour)})
	c := &Client{Base: base, Token: "ifd_x", LAN: route}
	ctx, cancel := context.WithCancel(context.Background())
	go func() { <-started; cancel() }()
	if _, _, err := c.DownloadRange(ctx, "a.bin", 0, 10); err == nil {
		t.Fatal("cancelled request succeeded")
	}
	if route.Get() == nil {
		t.Fatal("cancelling a request dropped the LAN route")
	}
}
