package davfs

import (
	"context"
	"net/http"
	"net/url"
	"strings"
	"sync/atomic"

	"github.com/neelsatyavolu/infocus-drive/cli/internal/api"
)

// request is what the file system needs to know about the WebDAV request
// it is serving; x/net/webdav only hands it a context.
type request struct {
	method  string
	length  int64  // PUT body length; -1 if unknown
	moveSrc string // MOVE source and destination, as cleaned names
	moveDst string
	broken  atomic.Bool // a read or write in this request failed
}

type requestKey struct{}

func withRequest(r *http.Request, prefix string) *http.Request {
	req := &request{method: r.Method, length: -1}
	switch r.Method {
	case http.MethodPut:
		req.length = r.ContentLength
	case "MOVE":
		req.moveSrc = api.CleanPath(strings.TrimPrefix(r.URL.Path, prefix))
		if dst, err := url.Parse(r.Header.Get("Destination")); err == nil {
			req.moveDst = api.CleanPath(strings.TrimPrefix(dst.Path, prefix))
		}
	}
	return r.WithContext(context.WithValue(r.Context(), requestKey{}, req))
}

func requestOf(ctx context.Context) *request {
	if req, ok := ctx.Value(requestKey{}).(*request); ok {
		return req
	}
	return &request{length: -1}
}
