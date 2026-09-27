package app

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/neelsatyavolu/infocus-drive/cli/internal/api"
	"github.com/neelsatyavolu/infocus-drive/cli/internal/config"
	"github.com/neelsatyavolu/infocus-drive/cli/internal/davfs"
)

const davPassword = "correct-horse-battery-staple"

type davHarness struct {
	drive   *fakeDrive
	srv     *httptest.Server
	mu      sync.Mutex
	uploads []davfs.Upload
}

func (h *davHarness) uploadEvents() []davfs.Upload {
	h.mu.Lock()
	defer h.mu.Unlock()
	return append([]davfs.Upload(nil), h.uploads...)
}

func newDavHarness(t *testing.T) *davHarness {
	t.Helper()
	drive, driveSrv := newFakeDrive(t)
	base, _ := url.Parse(driveSrv.URL)
	client := &api.Client{Base: base, Token: testToken, HTTP: driveSrv.Client()}
	fs := davfs.New(client, t.TempDir())
	h := &davHarness{drive: drive}
	fs.OnUpload = func(u davfs.Upload) {
		h.mu.Lock()
		h.uploads = append(h.uploads, u)
		h.mu.Unlock()
	}
	h.srv = httptest.NewServer(davfs.Handler(fs, "/InFocus Drive", davPassword, t.Logf))
	t.Cleanup(h.srv.Close)
	return h
}

// url builds a WebDAV URL from unescaped path segments below the volume.
func (h *davHarness) url(segments ...string) string {
	parts := []string{h.srv.URL, "InFocus%20Drive"}
	for _, s := range segments {
		parts = append(parts, url.PathEscape(s))
	}
	return strings.Join(parts, "/")
}

func (h *davHarness) do(t *testing.T, method, target string, body string, headers ...string) (int, string) {
	t.Helper()
	req, err := http.NewRequest(method, target, strings.NewReader(body))
	if err != nil {
		t.Fatal(err)
	}
	req.SetBasicAuth(davfs.User, davPassword)
	for i := 0; i+1 < len(headers); i += 2 {
		if headers[i] == "Host" {
			req.Host = headers[i+1]
		} else {
			req.Header.Set(headers[i], headers[i+1])
		}
	}
	res, err := h.srv.Client().Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer res.Body.Close()
	raw, _ := io.ReadAll(res.Body)
	return res.StatusCode, string(raw)
}

func (h *davHarness) propfind(t *testing.T, target string) (int, string) {
	return h.do(t, "PROPFIND", target, "", "Depth", "1")
}

func (h *davHarness) driveHas(p string) (string, bool) {
	h.drive.mu.Lock()
	defer h.drive.mu.Unlock()
	f, ok := h.drive.files[p]
	if !ok {
		return "", false
	}
	return string(f.data), true
}

func TestWebdavRequiresPasswordAndLoopbackHost(t *testing.T) {
	h := newDavHarness(t)
	res, err := http.Get(h.url())
	if err != nil {
		t.Fatal(err)
	}
	res.Body.Close()
	if res.StatusCode != http.StatusUnauthorized || res.Header.Get("WWW-Authenticate") == "" {
		t.Fatalf("no password: got %d", res.StatusCode)
	}
	req, _ := http.NewRequest("PROPFIND", h.url(), nil)
	req.SetBasicAuth(davfs.User, "wrong-password-wrong-password")
	res, _ = http.DefaultClient.Do(req)
	res.Body.Close()
	if res.StatusCode != http.StatusUnauthorized {
		t.Fatalf("wrong password: got %d", res.StatusCode)
	}
	if code, _ := h.do(t, "PROPFIND", h.url(), "", "Host", "evil.example.com", "Depth", "1"); code != http.StatusForbidden {
		t.Fatalf("rebinding host: got %d", code)
	}
}

func TestWebdavRootListsShares(t *testing.T) {
	h := newDavHarness(t)
	code, body := h.propfind(t, h.url()+"/")
	if code != http.StatusMultiStatus {
		t.Fatalf("PROPFIND root: %d %s", code, body)
	}
	for _, want := range []string{"InFocus%20Drive/InFocus%20Drive/", "InFocus%20Drive/Photos/", "InFocus%20Drive/My%20folder/"} {
		if !strings.Contains(body, want) {
			t.Errorf("root listing missing %s:\n%s", want, body)
		}
	}
}

func TestWebdavListAndReadWithRange(t *testing.T) {
	h := newDavHarness(t)
	h.drive.dir("Shows")
	h.drive.put("Shows/cut.txt", "0123456789")
	h.drive.put("Shows/.DS_Store", "server junk")

	code, body := h.propfind(t, h.url("My folder", "Shows")+"/")
	if code != http.StatusMultiStatus || !strings.Contains(body, "cut.txt") || strings.Contains(body, "DS_Store") {
		t.Fatalf("PROPFIND: %d %s", code, body)
	}
	if h.drive.lastShare != "~student1" {
		t.Fatalf("share header = %q, want ~student1", h.drive.lastShare)
	}
	if code, body := h.do(t, "GET", h.url("My folder", "Shows", "cut.txt"), ""); code != 200 || body != "0123456789" {
		t.Fatalf("GET: %d %q", code, body)
	}
	code, body = h.do(t, "GET", h.url("My folder", "Shows", "cut.txt"), "", "Range", "bytes=4-6")
	if code != http.StatusPartialContent || body != "456" {
		t.Fatalf("ranged GET: %d %q", code, body)
	}
	if h.drive.rangeReads == 0 {
		t.Fatal("ranged GET downloaded the whole file instead of asking the Drive for a range")
	}
}

func TestWebdavPutUploadsSmallAndChunked(t *testing.T) {
	h := newDavHarness(t)
	if code, body := h.do(t, "PUT", h.url("InFocus Drive", "small.txt"), "hello"); code != http.StatusCreated {
		t.Fatalf("PUT small: %d %s", code, body)
	}
	if got, _ := h.driveHas("small.txt"); got != "hello" {
		t.Fatalf("small.txt = %q", got)
	}
	big := strings.Repeat("x", api.ChunkThreshold+123)
	if code, body := h.do(t, "PUT", h.url("InFocus Drive", "big.bin"), big); code != http.StatusCreated {
		t.Fatalf("PUT big: %d %s", code, body)
	}
	if got, _ := h.driveHas("big.bin"); got != big {
		t.Fatalf("big.bin has %d bytes, want %d", len(got), len(big))
	}
	if h.drive.chunkPuts == 0 {
		t.Fatal("big file did not use chunked upload")
	}
	// Overwrite in place.
	if code, _ := h.do(t, "PUT", h.url("InFocus Drive", "small.txt"), "bye"); code/100 != 2 {
		t.Fatalf("overwrite: %d", code)
	}
	if got, _ := h.driveHas("small.txt"); got != "bye" {
		t.Fatalf("after overwrite small.txt = %q", got)
	}
	if code, _ := h.do(t, "PUT", h.url("InFocus Drive", "missing", "a.txt"), "x"); code/100 == 2 {
		t.Fatalf("PUT into missing folder succeeded: %d", code)
	}
}

func TestWebdavHiddenFilesStayLocal(t *testing.T) {
	h := newDavHarness(t)
	for _, name := range []string{"._clip.mov", ".DS_Store"} {
		if code, body := h.do(t, "PUT", h.url("InFocus Drive", name), "meta"); code != http.StatusCreated {
			t.Fatalf("PUT %s: %d %s", name, code, body)
		}
		if _, ok := h.driveHas(name); ok {
			t.Fatalf("%s was uploaded to the Drive", name)
		}
		if code, body := h.do(t, "GET", h.url("InFocus Drive", name), ""); code != 200 || body != "meta" {
			t.Fatalf("GET %s: %d %q", name, code, body)
		}
	}
	if _, body := h.propfind(t, h.url("InFocus Drive")+"/"); !strings.Contains(body, "._clip.mov") {
		t.Fatalf("listing misses local file:\n%s", body)
	}
	if code, _ := h.do(t, "DELETE", h.url("InFocus Drive", "._clip.mov"), ""); code != http.StatusNoContent {
		t.Fatalf("DELETE: %d", code)
	}
	if code, _ := h.do(t, "GET", h.url("InFocus Drive", "._clip.mov"), ""); code != http.StatusNotFound {
		t.Fatalf("GET after DELETE: %d", code)
	}
	// Finder may keep metadata even where it can't write real files.
	if code, _ := h.do(t, "PUT", h.url("Photos", ".DS_Store"), "meta"); code != http.StatusCreated {
		t.Fatalf("PUT .DS_Store in read-only share: %d", code)
	}
}

func TestWebdavSafeSaveThroughTempName(t *testing.T) {
	h := newDavHarness(t)
	h.drive.put("essay.docx", "draft 1")
	move := func(from, to string) {
		t.Helper()
		code, body := h.do(t, "MOVE", h.url("InFocus Drive", from), "", "Destination", h.url("InFocus Drive", to), "Overwrite", "T")
		if code/100 != 2 {
			t.Fatalf("MOVE %s → %s: %d %s", from, to, code, body)
		}
	}
	// Word-style save: write a temp file, move the original aside, move the
	// temp into place, delete the backup.
	if code, _ := h.do(t, "PUT", h.url("InFocus Drive", "~wrd0001.tmp"), "draft 2"); code != http.StatusCreated {
		t.Fatalf("PUT temp: %d", code)
	}
	move("essay.docx", "~wrl0002.tmp")
	if code, _ := h.propfind(t, h.url("InFocus Drive", "~wrl0002.tmp")); code != http.StatusMultiStatus {
		t.Fatalf("moved-aside original vanished: %d", code)
	}
	move("~wrd0001.tmp", "essay.docx")
	if code, _ := h.do(t, "DELETE", h.url("InFocus Drive", "~wrl0002.tmp"), ""); code != http.StatusNoContent {
		t.Fatalf("DELETE backup: %d", code)
	}
	if got, _ := h.driveHas("essay.docx"); got != "draft 2" {
		t.Fatalf("essay.docx = %q, want draft 2", got)
	}
	h.drive.mu.Lock()
	defer h.drive.mu.Unlock()
	for p := range h.drive.files {
		if strings.HasSuffix(p, ".tmp") {
			t.Errorf("temp file left on the Drive: %s", p)
		}
	}
}

func TestWebdavFoldersMoveAndDelete(t *testing.T) {
	h := newDavHarness(t)
	if code, _ := h.do(t, "MKCOL", h.url("InFocus Drive", "Shows"), ""); code != http.StatusCreated {
		t.Fatalf("MKCOL: %d", code)
	}
	h.do(t, "MKCOL", h.url("InFocus Drive", "Archive"), "")
	h.do(t, "PUT", h.url("InFocus Drive", "Shows", "ep1.txt"), "one")
	code, body := h.do(t, "MOVE", h.url("InFocus Drive", "Shows", "ep1.txt"), "",
		"Destination", h.url("InFocus Drive", "Archive", "episode 1.txt"))
	if code/100 != 2 {
		t.Fatalf("MOVE with rename: %d %s", code, body)
	}
	if got, _ := h.driveHas("Archive/episode 1.txt"); got != "one" {
		t.Fatalf("moved file = %q", got)
	}
	if code, _ := h.do(t, "DELETE", h.url("InFocus Drive", "Shows"), ""); code != http.StatusNoContent {
		t.Fatalf("DELETE folder: %d", code)
	}
	if _, ok := h.driveHas("Shows"); ok {
		t.Fatal("folder still on the Drive")
	}
	code, _ = h.do(t, "MOVE", h.url("InFocus Drive", "Archive"), "", "Destination", h.url("My folder", "Archive"))
	if code/100 == 2 {
		t.Fatalf("MOVE between shares succeeded: %d", code)
	}
}

func TestWebdavReadOnlyShare(t *testing.T) {
	h := newDavHarness(t)
	if code, _ := h.do(t, "PUT", h.url("Photos", "new.jpg"), "img"); code/100 == 2 {
		t.Fatalf("PUT in read-only share: %d", code)
	}
	if _, ok := h.driveHas("new.jpg"); ok {
		t.Fatal("file written to read-only share")
	}
	if code, _ := h.do(t, "PUT", h.url("new-share-level-file"), "x"); code/100 == 2 {
		t.Fatalf("PUT at the share list root: %d", code)
	}
}

// TestWebdavCommand runs `infocus webdav` the way the Mac app does.
func TestWebdavCommand(t *testing.T) {
	drive, driveSrv := newFakeDrive(t)
	drive.put("hello.txt", "hi")
	dir := t.TempDir()
	if err := config.Save(dir, config.Config{Server: driveSrv.URL}); err != nil {
		t.Fatal(err)
	}
	stdinR, stdinW := io.Pipe()
	stdoutR, stdoutW := io.Pipe()
	var stderr bytes.Buffer
	env := Env{
		Stdin: stdinR, Stdout: stdoutW, Stderr: &stderr, ConfigDir: dir,
		Tokens: config.MemoryStore{strings.TrimPrefix(driveSrv.URL, "http://"): testToken},
		HTTP:   driveSrv.Client(), Getenv: func(string) string { return "" },
	}
	// No keep-alives: an idle connection would hold up the helper's Shutdown.
	client := &http.Client{Transport: &http.Transport{DisableKeepAlives: true}}
	exit := make(chan int, 1)
	go func() { exit <- Run(context.Background(), []string{"webdav"}, env); stdoutW.Close() }()
	go io.WriteString(stdinW, davPassword+"\n")

	events := bufio.NewScanner(stdoutR)
	next := func() map[string]string {
		t.Helper()
		if !events.Scan() {
			t.Fatalf("no event; stderr: %s", stderr.String())
		}
		var raw map[string]any
		if err := json.Unmarshal(events.Bytes(), &raw); err != nil {
			t.Fatal(err)
		}
		ev := map[string]string{}
		for k, v := range raw {
			if s, ok := v.(string); ok {
				ev[k] = s
			}
		}
		return ev
	}
	ready := next()
	if ready["event"] != "ready" || !strings.HasPrefix(ready["url"], "http://127.0.0.1:") ||
		!strings.HasSuffix(ready["url"], "/InFocus%20Drive/") {
		t.Fatalf("ready event = %v", ready)
	}
	get := func() int {
		req, _ := http.NewRequest("GET", ready["url"]+"InFocus%20Drive/hello.txt", nil)
		req.SetBasicAuth(davfs.User, davPassword)
		res, err := client.Do(req)
		if err != nil {
			t.Fatal(err)
		}
		res.Body.Close()
		return res.StatusCode
	}
	if code := get(); code != 200 {
		t.Fatalf("GET through command: %d", code)
	}
	put, _ := http.NewRequest("PUT", ready["url"]+"InFocus%20Drive/new.txt", strings.NewReader("hello"))
	put.SetBasicAuth(davfs.User, davPassword)
	putDone := make(chan int, 1)
	go func() { // events are written while the PUT is in flight; keep reading them
		res, err := client.Do(put)
		if err != nil {
			putDone <- 0
			return
		}
		res.Body.Close()
		putDone <- res.StatusCode
	}()
	// The Mac app reads these lines; keep the shape stable.
	for {
		if !events.Scan() {
			t.Fatal("no upload event")
		}
		var ev map[string]any
		json.Unmarshal(events.Bytes(), &ev)
		if ev["event"] == "upload" && ev["state"] == "done" {
			if ev["path"] != "InFocus Drive/new.txt" || ev["size"] != 5.0 || ev["sent"] != 5.0 || ev["id"] == nil {
				t.Fatalf("upload event = %v", ev)
			}
			break
		}
	}
	if code := <-putDone; code != http.StatusCreated {
		t.Fatalf("PUT through command: %d", code)
	}
	drive.mu.Lock()
	drive.revoked = true
	drive.mu.Unlock()
	time.Sleep(10 * time.Millisecond)
	get()
	for {
		if ev := next(); ev["event"] == "signed_out" {
			break
		}
	}
	select {
	case code := <-exit:
		if code != ExitAuth {
			t.Fatalf("exit %d, want %d", code, ExitAuth)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("server did not stop after sign-out")
	}
}

func TestWebdavCommandRejectsBadInput(t *testing.T) {
	h := newHarness(t)
	h.env.Stdin = strings.NewReader("short\n")
	if code := h.run("webdav"); code != ExitUsage {
		t.Fatalf("short password: exit %d", code)
	}
	h.env.Stdin = strings.NewReader(davPassword + "\n")
	if code := h.run("webdav", "--addr", "0.0.0.0:0"); code != ExitUsage {
		t.Fatalf("non-loopback addr: exit %d", code)
	}
}

func (h *davHarness) set(fn func(d *fakeDrive)) {
	h.drive.mu.Lock()
	defer h.drive.mu.Unlock()
	fn(h.drive)
}

// Finder sends LOCK before writing; if the Drive can't be listed at that
// moment the file must not be replaced with an empty one.
func TestWebdavLockNeverEmptiesExistingFile(t *testing.T) {
	h := newDavHarness(t)
	h.drive.put("doc.txt", "precious-data")
	h.set(func(d *fakeDrive) { d.failLists = 2 })
	h.do(t, "LOCK", h.url("InFocus Drive", "doc.txt"), lockBody, "Timeout", "Second-60")
	if got, _ := h.driveHas("doc.txt"); got != "precious-data" {
		t.Fatalf("doc.txt = %q after LOCK during a listing failure", got)
	}
	// Even with a stale "not found" (another user created it meanwhile),
	// LOCK only creates, never replaces.
	code, _ := h.do(t, "LOCK", h.url("InFocus Drive", "new.txt"), lockBody, "Timeout", "Second-60")
	if code/100 != 2 {
		t.Fatalf("LOCK new file: %d", code)
	}
	h.drive.put("race.txt", "theirs")
	h.set(func(d *fakeDrive) { delete(d.files, "race.txt") })
	h.propfind(t, h.url("InFocus Drive")+"/") // cache: race.txt absent
	h.drive.put("race.txt", "theirs")
	h.do(t, "LOCK", h.url("InFocus Drive", "race.txt"), lockBody, "Timeout", "Second-60")
	if got, _ := h.driveHas("race.txt"); got != "theirs" {
		t.Fatalf("race.txt = %q, LOCK replaced a file it thought was missing", got)
	}
}

const lockBody = `<?xml version="1.0" encoding="utf-8"?><D:lockinfo xmlns:D="DAV:"><D:lockscope><D:exclusive/></D:lockscope><D:locktype><D:write/></D:locktype></D:lockinfo>`

func TestWebdavFailedCopyUploadsNothing(t *testing.T) {
	h := newDavHarness(t)
	h.drive.put("src.txt", "0123456789")
	h.drive.put("dst.txt", "keep me")
	h.set(func(d *fakeDrive) { d.truncate = map[string]int{"src.txt": 5} })
	code, _ := h.do(t, "COPY", h.url("InFocus Drive", "src.txt"), "", "Destination", h.url("InFocus Drive", "new.txt"))
	if code/100 == 2 {
		t.Fatalf("COPY with a broken source succeeded: %d", code)
	}
	if got, ok := h.driveHas("new.txt"); ok {
		t.Fatalf("partial copy uploaded: new.txt = %q", got)
	}
}

// An app's safe save renames its temp file over the document. If that
// upload fails the original must still be there.
func TestWebdavFailedSafeSaveKeepsOriginal(t *testing.T) {
	h := newDavHarness(t)
	h.drive.put("essay.docx", "draft 1")
	h.do(t, "PUT", h.url("InFocus Drive", "~wrd0001.tmp"), "draft 2")
	h.set(func(d *fakeDrive) { d.failUpload = true })
	code, _ := h.do(t, "MOVE", h.url("InFocus Drive", "~wrd0001.tmp"), "",
		"Destination", h.url("InFocus Drive", "essay.docx"), "Overwrite", "T")
	if code/100 == 2 {
		t.Fatalf("MOVE succeeded although the upload failed: %d", code)
	}
	if got, _ := h.driveHas("essay.docx"); got != "draft 1" {
		t.Fatalf("essay.docx = %q; the original was removed before the upload", got)
	}
	if code, body := h.do(t, "GET", h.url("InFocus Drive", "~wrd0001.tmp"), ""); code != 200 || body != "draft 2" {
		t.Fatalf("temp file lost after failed save: %d %q", code, body)
	}
}

func TestWebdavRejectsBackslashNames(t *testing.T) {
	h := newDavHarness(t)
	h.drive.dir("Q1")
	h.drive.put("Q1/notes.txt", "original")
	if code, _ := h.do(t, "PUT", h.url("InFocus Drive", `Q1\notes.txt`), "clobber"); code/100 == 2 {
		t.Fatalf("PUT with a backslash name succeeded: %d", code)
	}
	if got, _ := h.driveHas("Q1/notes.txt"); got != "original" {
		t.Fatalf("Q1/notes.txt = %q", got)
	}
}

func TestWebdavFolderRenameKeepsLocalFiles(t *testing.T) {
	h := newDavHarness(t)
	h.drive.dir("Old")
	h.do(t, "PUT", h.url("InFocus Drive", "Old", "._clip.mov"), "meta")
	code, _ := h.do(t, "MOVE", h.url("InFocus Drive", "Old"), "", "Destination", h.url("InFocus Drive", "New"))
	if code/100 != 2 {
		t.Fatalf("MOVE folder: %d", code)
	}
	if code, body := h.do(t, "GET", h.url("InFocus Drive", "New", "._clip.mov"), ""); code != 200 || body != "meta" {
		t.Fatalf("local file after folder rename: %d %q", code, body)
	}
	h.do(t, "MKCOL", h.url("InFocus Drive", "Old"), "")
	if code, _ := h.do(t, "GET", h.url("InFocus Drive", "Old", "._clip.mov"), ""); code != http.StatusNotFound {
		t.Fatalf("stale local file reappeared under the old name: %d", code)
	}
}

func TestWebdavReportsUploads(t *testing.T) {
	h := newDavHarness(t)
	big := strings.Repeat("x", api.ChunkThreshold+10)
	h.do(t, "PUT", h.url("InFocus Drive", "clip.mov"), big)
	events := h.uploadEvents()
	if len(events) < 2 {
		t.Fatalf("want start and finish events, got %+v", events)
	}
	first, last := events[0], events[len(events)-1]
	if first.State != "active" || first.Path != "InFocus Drive/clip.mov" || first.Size != int64(len(big)) {
		t.Fatalf("first event = %+v", first)
	}
	if last.State != "done" || last.Sent != last.Size || last.ID != first.ID {
		t.Fatalf("last event = %+v", last)
	}

	h.set(func(d *fakeDrive) { d.failUpload = true })
	h.do(t, "PUT", h.url("InFocus Drive", "note.txt"), "hello")
	events = h.uploadEvents()
	if last := events[len(events)-1]; last.State != "failed" || last.Error == "" || last.Path != "InFocus Drive/note.txt" {
		t.Fatalf("failed upload event = %+v", last)
	}
	// Finder's empty LOCK placeholders and hidden files are not transfers.
	before := len(events)
	h.do(t, "LOCK", h.url("InFocus Drive", "placeholder.txt"), lockBody)
	h.do(t, "PUT", h.url("InFocus Drive", "._clip.mov"), "meta")
	if got := len(h.uploadEvents()); got != before {
		t.Fatalf("placeholder/hidden writes produced %d upload events", got-before)
	}
}
