package app

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"os"
	"strings"
	"sync"
	"time"

	"github.com/neelsatyavolu/infocus-drive/cli/internal/davfs"
)

const minWebdavPassword = 16

// cmdWebdav serves the account's shares to Finder over WebDAV on loopback.
// The Mac app runs it: it writes a password line on stdin, reads JSON events
// from stdout ({"event":"ready","url":…}, {"event":"upload",…} for transfer
// progress, {"event":"signed_out"}) and mounts
// the URL with NetFS. The server stops on interrupt, when stdin closes (the
// app quit) or when the Drive rejects the token.
func cmdWebdav(ctx context.Context, r *runner, args []string) error {
	fs := flag.NewFlagSet("webdav", flag.ContinueOnError)
	addr := fs.String("addr", "127.0.0.1:0", "loopback address to listen on")
	name := fs.String("name", "InFocus Drive", "volume name Finder shows")
	rest, err := parseFlags(fs, args)
	if err != nil {
		return err
	}
	if len(rest) > 0 {
		return usagef("usage: infocus webdav [--addr 127.0.0.1:PORT] [--name NAME]  (password on stdin)")
	}
	if !loopbackAddr(*addr) {
		return usagef("--addr must be a loopback address like 127.0.0.1:0")
	}
	if strings.TrimSpace(*name) == "" || strings.ContainsAny(*name, "/\\") {
		return usagef("--name must be a plain folder name")
	}
	stdin := bufio.NewReader(r.env.Stdin)
	password, err := readPassword(stdin)
	if err != nil {
		return err
	}
	client, err := r.signedIn()
	if err != nil {
		return err
	}
	me, err := client.Me(ctx)
	if err != nil {
		return err
	}
	if !me.Authenticated {
		return exitError{ExitAuth, "sign-in expired or revoked; run infocus login"}
	}
	tempDir, err := os.MkdirTemp("", "infocus-webdav-")
	if err != nil {
		return err
	}
	defer os.RemoveAll(tempDir)

	signedOut := make(chan struct{})
	var once sync.Once
	events := &eventWriter{enc: json.NewEncoder(r.env.Stdout)}
	dav := davfs.New(client, tempDir)
	dav.OnSignedOut = func() { once.Do(func() { close(signedOut) }) }
	dav.OnWriting = func(open int) {
		events.send(map[string]any{"event": "writing", "open": open})
	}
	dav.OnUpload = func(u davfs.Upload) {
		events.send(struct {
			Event string `json:"event"`
			davfs.Upload
		}{"upload", u})
	}

	ln, err := net.Listen("tcp", *addr)
	if err != nil {
		return fmt.Errorf("listen on %s: %w", *addr, err)
	}
	prefix := "/" + *name
	logf := func(format string, args ...any) { fmt.Fprintf(r.env.Stderr, format+"\n", args...) }
	srv := &http.Server{
		Handler:           davfs.Handler(dav, prefix, password, logf),
		ReadHeaderTimeout: 30 * time.Second,
	}
	served := make(chan error, 1)
	go func() { served <- srv.Serve(ln) }()

	mountURL := url.URL{Scheme: "http", Host: ln.Addr().String(), Path: prefix + "/"}
	events.send(map[string]string{"event": "ready", "url": mountURL.String(), "user": davfs.User})

	stdinClosed := make(chan struct{})
	go func() {
		io.Copy(io.Discard, stdin) //nolint:errcheck
		close(stdinClosed)
	}()
	var result error
	select {
	case <-ctx.Done():
	case <-stdinClosed:
	case err := <-served:
		result = err
	case <-signedOut:
		events.send(map[string]string{"event": "signed_out"})
		result = exitError{ExitAuth, "sign-in expired or revoked; run infocus login"}
	}
	// Give in-flight transfers a moment to finish before stopping.
	shutdownCtx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	srv.Shutdown(shutdownCtx) //nolint:errcheck
	return result
}

func readPassword(stdin *bufio.Reader) (string, error) {
	line, err := stdin.ReadString('\n')
	if err != nil && !errors.Is(err, io.EOF) {
		return "", err
	}
	password := strings.TrimSpace(line)
	if len(password) < minWebdavPassword {
		return "", usagef("infocus webdav reads a password of at least %d characters on stdin", minWebdavPassword)
	}
	return password, nil
}

func loopbackAddr(addr string) bool {
	host, _, err := net.SplitHostPort(addr)
	if err != nil {
		return false
	}
	ip := net.ParseIP(host)
	return host == "localhost" || (ip != nil && ip.IsLoopback())
}

// eventWriter writes one JSON event per line; uploads report concurrently.
type eventWriter struct {
	mu  sync.Mutex
	enc *json.Encoder
}

func (w *eventWriter) send(v any) {
	w.mu.Lock()
	defer w.mu.Unlock()
	w.enc.Encode(v) //nolint:errcheck // the app may be gone; nothing to do
}
