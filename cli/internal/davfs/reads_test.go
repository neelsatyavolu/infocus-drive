package davfs

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"net/url"
	"sync"
	"testing"
	"time"

	"github.com/neelsatyavolu/infocus-drive/cli/internal/api"
)

// revDrive serves one file in share S, whose content and version tests change.
type revDrive struct {
	mu         sync.Mutex
	name       string
	data       []byte
	etag       string
	swapAt     int64 // a range starting here is served from data2
	data2      []byte
	rangeBytes int64
	ranges     []string
	inflight   int // ranged downloads being served right now
	maxFlight  int
}

func newRevDrive(t *testing.T, name string, data []byte) (*revDrive, *FS, *httptest.Server) {
	d := &revDrive{name: name, data: data, etag: `"v1"`, swapAt: -1}
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		q := r.URL.Query()
		switch r.URL.Path {
		case "/api/me":
			json.NewEncoder(w).Encode(map[string]any{"authenticated": true,
				"shares": []map[string]any{{"id": "S", "name": "S", "can_read": true, "can_write": true}}})
		case "/api/files":
			d.mu.Lock()
			items := []api.Entry{{Name: d.name, Path: d.name, Size: int64(len(d.data))}}
			d.mu.Unlock()
			json.NewEncoder(w).Encode(map[string]any{"path": q.Get("path"), "items": items})
		case "/api/download":
			d.mu.Lock()
			d.inflight++
			d.maxFlight = max(d.maxFlight, d.inflight)
			d.mu.Unlock()
			defer func() { d.mu.Lock(); d.inflight--; d.mu.Unlock() }()
			time.Sleep(5 * time.Millisecond) // a real link: requests overlap
			d.mu.Lock()
			data, etag := d.data, d.etag
			if rng := r.Header.Get("Range"); rng != "" {
				d.ranges = append(d.ranges, rng)
				var a, b int64
				fmt.Sscanf(rng, "bytes=%d-%d", &a, &b)
				d.rangeBytes += b - a + 1
				if a == d.swapAt {
					data, etag = d.data2, `"v2"`
				}
			}
			d.mu.Unlock()
			w.Header().Set("ETag", etag)
			http.ServeContent(w, r, "", time.Time{}, bytes.NewReader(data))
		default:
			http.NotFound(w, r)
		}
	}))
	t.Cleanup(srv.Close)
	base, _ := url.Parse(srv.URL)
	fs := New(&api.Client{Base: base, Token: "ifd_test", HTTP: srv.Client()}, t.TempDir())
	dav := httptest.NewServer(Handler(fs, "/V", "pw", t.Logf))
	t.Cleanup(dav.Close)
	return d, fs, dav
}

func davDo(t *testing.T, dav *httptest.Server, method, p string, hdr ...string) (int, []byte) {
	req, _ := http.NewRequest(method, dav.URL+"/V/S/"+p, nil)
	req.SetBasicAuth(User, "pw")
	for i := 0; i+1 < len(hdr); i += 2 {
		req.Header.Set(hdr[i], hdr[i+1])
	}
	res, err := dav.Client().Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer res.Body.Close()
	b, _ := io.ReadAll(res.Body)
	return res.StatusCode, b
}

// A listing that joins a fetch started before an upload finished still shows
// the uploaded file.
func TestJoinedListingIncludesLocalChange(t *testing.T) {
	d, fs := newSlowDrive(t)
	ctx := context.Background()
	if _, err := fs.Stat(ctx, "/S"); err != nil {
		t.Fatal(err)
	}
	d.listDelay.Store(int64(300 * time.Millisecond))
	go fs.Stat(ctx, "/S/Shows/a.mov") // starts a fetch of Shows
	eventually(t, "the fetch to start", func() bool { return d.listCalls.Load() >= 1 })
	tgt, err := fs.resolve(ctx, "/S/Shows/b.mov")
	if err != nil {
		t.Fatal(err)
	}
	fs.cachePut(tgt, api.Entry{Name: "b.mov", Path: "Shows/b.mov", Size: 5}) // the upload finished
	if _, err := fs.Stat(ctx, "/S/Shows/b.mov"); err != nil {
		t.Fatalf("just-uploaded file not found: %v", err)
	}
}

// Copying into a folder while Finder keeps listing it: every file is found
// right after its upload, and listings still get cached (not one per file).
func TestCopyIntoListedFolderFindsEveryFile(t *testing.T) {
	d, fs := newSlowDrive(t)
	fs.listTTL, fs.listStale = 30*time.Millisecond, 60*time.Millisecond
	ctx := context.Background()
	if _, err := fs.Stat(ctx, "/S/Shows/a.mov"); err != nil {
		t.Fatal(err)
	}
	d.listDelay.Store(int64(10 * time.Millisecond))
	tgt, _ := fs.resolve(ctx, "/S/Shows/x")
	stop := make(chan struct{})
	done := make(chan struct{})
	go func() { // Finder showing the folder
		defer close(done)
		for {
			select {
			case <-stop:
				return
			default:
			}
			fs.readDir(ctx, node{t: tgt.with("Shows")})
			time.Sleep(time.Millisecond)
		}
	}()
	before := d.listCalls.Load()
	missing := 0
	for i := 0; i < 60; i++ {
		e := api.Entry{Name: fmt.Sprintf("f%d", i), Path: fmt.Sprintf("Shows/f%d", i)}
		d.mu.Lock()
		d.items = append(d.items, e)
		d.mu.Unlock()
		fs.cachePut(tgt.with(e.Path), e) // upload done
		if _, err := fs.Stat(ctx, "/S/"+e.Path); err != nil {
			missing++
		}
		time.Sleep(3 * time.Millisecond)
	}
	close(stop)
	<-done
	if missing > 0 {
		t.Fatalf("%d of 60 just-uploaded files were not found right after their upload", missing)
	}
	// ~200 ms of copying with a 30 ms TTL: a handful of listings, not one per file.
	if n := d.listCalls.Load() - before; n > 20 {
		t.Fatalf("%d listings while copying 60 files", n)
	}
}

// The file grew on the Drive after Finder listed the folder: opening it uses
// a fresh listing, so the whole new file is served.
func TestOpenNeverUsesAStaleSize(t *testing.T) {
	d, fs, dav := newRevDrive(t, "f.png", bytes.Repeat([]byte("A"), 1000))
	fs.listTTL = 10 * time.Millisecond
	if code, _ := davDo(t, dav, "PROPFIND", "", "Depth", "1"); code != 207 {
		t.Fatalf("PROPFIND: %d", code)
	}
	d.mu.Lock()
	d.data, d.etag = bytes.Repeat([]byte("B"), 3000), `"v2"`
	d.mu.Unlock()
	time.Sleep(30 * time.Millisecond)
	if code, body := davDo(t, dav, "GET", "f.png"); code != 200 || !bytes.Equal(body, bytes.Repeat([]byte("B"), 3000)) {
		t.Fatalf("GET: %d, %d bytes", code, len(body))
	}
}

// Even a fresh listing can be out of date: a read whose download names
// another size fails rather than serve a cut-off file, and the next read
// re-lists.
func TestSizeMismatchFailsTheReadAndRelists(t *testing.T) {
	d, fs, dav := newRevDrive(t, "f.png", bytes.Repeat([]byte("A"), 1000))
	fs.listTTL = time.Hour
	davDo(t, dav, "PROPFIND", "", "Depth", "1")
	d.mu.Lock()
	d.data, d.etag = bytes.Repeat([]byte("B"), 3000), `"v2"`
	d.mu.Unlock()
	if code, body := davDo(t, dav, "GET", "f.png"); code == 200 && len(body) == 1000 {
		t.Fatal("served 1000 bytes of a 3000-byte file without error")
	}
	if code, body := davDo(t, dav, "GET", "f.png"); code != 200 || len(body) != 3000 {
		t.Fatalf("GET after the mismatch: %d, %d bytes", code, len(body))
	}
}

// A multi-range GET reads each part separately; all must be one version.
func TestMultiRangeNeverMixesVersions(t *testing.T) {
	size := 10 << 20
	d, _, dav := newRevDrive(t, "f.png", bytes.Repeat([]byte("A"), size))
	d.data2 = bytes.Repeat([]byte("B"), size)
	d.swapAt = 9000000
	code, body := davDo(t, dav, "GET", "f.png", "Range", "bytes=0-5242879,9000000-9000099")
	if code == 206 && bytes.Contains(body, []byte("AAAA")) && bytes.Contains(body, []byte("BBBB")) {
		t.Fatal("multi-range response mixed two versions")
	}
}

// A file without an extension: serving it must not read its start to guess
// the type (a Drive request of its own, then abandoned).
func TestUnknownTypeFetchesOnlyTheRange(t *testing.T) {
	d, _, dav := newRevDrive(t, "clip", make([]byte, 64<<20))
	code, body := davDo(t, dav, "GET", "clip", "Range", "bytes=40000000-40065535")
	if code != http.StatusPartialContent || len(body) != 65536 {
		t.Fatalf("ranged GET: %d, %d bytes", code, len(body))
	}
	if code, _ := davDo(t, dav, "HEAD", "clip"); code != 200 {
		t.Fatalf("HEAD: %d", code)
	}
	time.Sleep(50 * time.Millisecond)
	d.mu.Lock()
	defer d.mu.Unlock()
	if d.rangeBytes != 65536 || len(d.ranges) != 1 {
		t.Fatalf("Drive asked for %d bytes in %v", d.rangeBytes, d.ranges)
	}
}

// Finder making a thumbnail opens a big video and reads a little of it. The
// read must not start fetching megabytes ahead it will never use.
func TestPeekingAtABigFileFetchesLittle(t *testing.T) {
	d, _, dav := newRevDrive(t, "clip.mov", make([]byte, 64<<20))
	req, _ := http.NewRequest("GET", dav.URL+"/V/S/clip.mov", nil)
	req.SetBasicAuth(User, "pw")
	res, err := dav.Client().Do(req)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := io.ReadFull(res.Body, make([]byte, 300<<10)); err != nil {
		t.Fatal(err)
	}
	time.Sleep(100 * time.Millisecond) // let anything already started finish
	res.Body.Close()
	d.mu.Lock()
	defer d.mu.Unlock()
	// Socket buffers take ~1 MB more than the client reads; before the ramp
	// this fetched 17+ MB (six chunks at once).
	if d.rangeBytes > 6<<20 {
		t.Fatalf("reading 300 KB fetched %d MB from the Drive: %v", d.rangeBytes>>20, d.ranges)
	}
}

// Many files read at once (a folder of thumbnails) share a cap on parallel
// downloads, so they can't swamp the link and stall everything else.
func TestParallelReadsShareACap(t *testing.T) {
	d, _, dav := newRevDrive(t, "clip.mov", make([]byte, 48<<20))
	var wg sync.WaitGroup
	for i := 0; i < 5; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			if code, body := davDo(t, dav, "GET", "clip.mov"); code != 200 || len(body) != 48<<20 {
				t.Errorf("GET: %d, %d bytes", code, len(body))
			}
		}()
	}
	wg.Wait()
	d.mu.Lock()
	defer d.mu.Unlock()
	// totalReadStreams large chunks, plus each read's small first chunk.
	if d.maxFlight > totalReadStreams+5 {
		t.Fatalf("%d downloads at once for 5 reads", d.maxFlight)
	}
}
