package davfs

import (
	"context"
	"errors"
	"io"

	"github.com/neelsatyavolu/infocus-drive/cli/internal/api"
)

// Parallel read-ahead: one HTTP stream through the tunnel tops out well below
// what several do (measured ~45 vs ~70 MB/s), so large sequential reads fetch
// 8 MiB chunks, readStreams at a time, and hand them out in order. At most
// readWindow chunks are fetched ahead, plus the one being read (48 MiB).
// It only starts after readAheadAfter bytes of sequential reading, so small
// range reads stay one request.
//
// Every chunk must come from the same version of the file (ETag, Last-Modified,
// size) as the bytes already read; otherwise the read fails instead of
// stitching an old and a new version together.
const (
	readChunk      = 8 << 20
	readStreams    = 4
	readWindow     = 5
	readAheadAfter = 1 << 20
)

// errChanged: the file was replaced on the Drive in the middle of a read.
var errChanged = errors.New("the file changed on the Drive while it was being read; copy it again")

type chunkResult struct {
	data    []byte
	version string
	err     error
}

// readAhead streams a file from offset `from` using parallel ranged requests.
type readAhead struct {
	cancel  context.CancelFunc
	results []chan chunkResult // one per chunk, in file order
	window  chan struct{}      // limits chunks fetched ahead of the reader
	next    int                // next chunk to hand out
	cur     []byte             // unread part of the current chunk
	pos     int64              // file offset of cur[0]
	version string             // every chunk must match this version
}

func startReadAhead(parent context.Context, client *api.Client, rel string, from, size int64, version string) *readAhead {
	ctx, cancel := context.WithCancel(parent)
	n := int((size - from + readChunk - 1) / readChunk)
	r := &readAhead{
		cancel:  cancel,
		results: make([]chan chunkResult, n),
		window:  make(chan struct{}, readWindow),
		pos:     from,
		version: version,
	}
	for i := range r.results {
		r.results[i] = make(chan chunkResult, 1)
	}
	go func() {
		streams := make(chan struct{}, readStreams)
		for i := 0; i < n; i++ {
			select {
			case r.window <- struct{}{}: // freed when the reader takes a chunk
			case <-ctx.Done():
				return
			}
			select {
			case streams <- struct{}{}:
			case <-ctx.Done():
				return
			}
			offset := from + int64(i)*readChunk
			length := min(readChunk, size-offset)
			go func(i int) {
				defer func() { <-streams }()
				data, version, err := client.DownloadRange(ctx, rel, offset, length)
				r.results[i] <- chunkResult{data, version, err}
			}(i)
		}
	}()
	return r
}

// Read hands out the file's bytes in order.
func (r *readAhead) Read(ctx context.Context, p []byte) (int, error) {
	for len(r.cur) == 0 {
		if r.next >= len(r.results) {
			return 0, io.EOF
		}
		var res chunkResult
		select {
		case res = <-r.results[r.next]:
		case <-ctx.Done():
			return 0, ctx.Err()
		}
		<-r.window
		r.next++
		if res.err != nil {
			return 0, res.err
		}
		if r.version == "" {
			r.version = res.version
		} else if res.version != r.version {
			return 0, errChanged
		}
		r.cur = res.data
	}
	n := copy(p, r.cur)
	r.cur = r.cur[n:]
	r.pos += int64(n)
	return n, nil
}

func (r *readAhead) Close() { r.cancel() }

// rangeUnsupported reports whether the Drive answered ranges with whole files.
func rangeUnsupported(err error) bool { return errors.Is(err, api.ErrNoRange) }
