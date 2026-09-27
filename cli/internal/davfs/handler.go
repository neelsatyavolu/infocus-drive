package davfs

import (
	"crypto/sha256"
	"crypto/subtle"
	"net"
	"net/http"
	"os"

	"golang.org/x/net/webdav"
)

// User is the fixed WebDAV user name; the per-run password is the secret.
const User = "infocus"

// Handler serves fs over WebDAV under prefix (e.g. "/InFocus Drive").
//
// It listens on loopback only, but other local accounts and web pages can
// still reach loopback, so every request needs the password (HTTP Basic),
// and Host must be loopback to block DNS-rebinding pages.
func Handler(fs *FS, prefix, password string, logf func(format string, args ...any)) http.Handler {
	dav := &webdav.Handler{
		Prefix:     prefix,
		FileSystem: fs,
		LockSystem: webdav.NewMemLS(),
		Logger: func(r *http.Request, err error) {
			if err != nil && !os.IsNotExist(err) && logf != nil {
				logf("%s %s: %v", r.Method, r.URL.Path, err)
			}
		},
	}
	want := sha256.Sum256([]byte(User + ":" + password))
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if !loopbackHost(r.Host) {
			http.Error(w, "forbidden", http.StatusForbidden)
			return
		}
		user, pass, _ := r.BasicAuth()
		got := sha256.Sum256([]byte(user + ":" + pass))
		if subtle.ConstantTimeCompare(got[:], want[:]) != 1 {
			w.Header().Set("WWW-Authenticate", `Basic realm="InFocus Drive"`)
			http.Error(w, "unauthorized", http.StatusUnauthorized)
			return
		}
		dav.ServeHTTP(w, withRequest(r, prefix))
	})
}

func loopbackHost(hostport string) bool {
	host, _, err := net.SplitHostPort(hostport)
	if err != nil {
		host = hostport
	}
	if host == "localhost" {
		return true
	}
	ip := net.ParseIP(host)
	return ip != nil && ip.IsLoopback()
}
