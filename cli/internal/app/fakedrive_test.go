package app

import (
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"path"
	"sort"
	"strconv"
	"strings"
	"sync"
	"testing"
)

const testToken = "ifd_test"

type fakeFile struct {
	data    []byte
	mtimeNS int64
	isDir   bool
}

// fakeDrive is an in-memory stand-in for the Drive API the CLI uses.
type fakeDrive struct {
	t         *testing.T
	mu        sync.Mutex
	files     map[string]*fakeFile
	clock     int64
	chunks    map[string]map[int][]byte
	meta      map[string][2]string // upload_id → dir, name
	failOnce  map[int]bool         // chunk index → return 500 once
	shares    []string
	lastShare string
	loggedOut bool
}

func newFakeDrive(t *testing.T) (*fakeDrive, *httptest.Server) {
	d := &fakeDrive{
		t: t, files: map[string]*fakeFile{"": {isDir: true}}, clock: 1_000,
		chunks: map[string]map[int][]byte{}, meta: map[string][2]string{},
		failOnce: map[int]bool{}, shares: []string{"InFocus Drive", "Photos"},
	}
	srv := httptest.NewServer(http.HandlerFunc(d.serve))
	t.Cleanup(srv.Close)
	return d, srv
}

func (d *fakeDrive) put(p string, data string) {
	d.clock++
	d.files[p] = &fakeFile{data: []byte(data), mtimeNS: d.clock}
}

func (d *fakeDrive) dir(p string) { d.files[p] = &fakeFile{isDir: true} }

func (d *fakeDrive) entry(p string) map[string]any {
	f := d.files[p]
	return map[string]any{"name": path.Base(p), "path": p, "is_dir": f.isDir,
		"size": len(f.data), "mtime": "2026-09-24T10:00:00+00:00", "mtime_ns": f.mtimeNS}
}

func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	json.NewEncoder(w).Encode(v)
}

func fail(w http.ResponseWriter, status int, detail string) {
	writeJSON(w, status, map[string]string{"detail": detail})
}

func join(dir, name string) string {
	if dir == "" {
		return name
	}
	return dir + "/" + name
}

func (d *fakeDrive) serve(w http.ResponseWriter, r *http.Request) {
	d.mu.Lock()
	defer d.mu.Unlock()
	if r.Header.Get("Authorization") != "Bearer "+testToken {
		fail(w, 401, "Terminal sign-in expired or revoked. Run `infocus login`.")
		return
	}
	d.lastShare = r.Header.Get("X-Drive-Share")
	q := r.URL.Query()
	switch r.URL.Path {
	case "/api/me":
		writeJSON(w, 200, map[string]any{"authenticated": true, "nas_username": "student1",
			"email": "student1@example.org", "share": "InFocus Drive", "shares": d.shares})
	case "/api/files":
		dir := q.Get("path")
		if f, ok := d.files[dir]; !ok || !f.isDir {
			fail(w, 404, "Not found")
			return
		}
		items := []map[string]any{}
		var names []string
		for p := range d.files {
			if p != "" && path.Dir("/"+p) == path.Clean("/"+dir) {
				names = append(names, p)
			}
		}
		sort.Strings(names)
		for _, p := range names {
			items = append(items, d.entry(p))
		}
		writeJSON(w, 200, map[string]any{"path": dir, "items": items})
	case "/api/download":
		f, ok := d.files[q.Get("path")]
		if !ok || f.isDir {
			fail(w, 404, "Not found")
			return
		}
		w.Write(f.data)
	case "/api/upload":
		r.ParseMultipartForm(64 << 20)
		file, header, err := r.FormFile("file")
		if err != nil {
			fail(w, 422, "missing file")
			return
		}
		data, _ := io.ReadAll(file)
		d.finishUpload(w, join(r.FormValue("path"), header.Filename), data, r.FormValue("expect_mtime_ns"))
	case "/api/upload/init":
		id := fmt.Sprintf("u%d", len(d.meta)+1)
		d.meta[id] = [2]string{r.FormValue("path"), r.FormValue("name")}
		d.chunks[id] = map[int][]byte{}
		size, _ := strconv.Atoi(r.FormValue("size"))
		cs, _ := strconv.Atoi(r.FormValue("chunk_size"))
		writeJSON(w, 200, map[string]any{"upload_id": id, "chunk_size": cs, "total_chunks": (size + cs - 1) / cs})
	case "/api/upload/chunk":
		index, _ := strconv.Atoi(q.Get("index"))
		if d.failOnce[index] {
			delete(d.failOnce, index)
			fail(w, 502, "bad gateway")
			return
		}
		data, _ := io.ReadAll(r.Body)
		d.chunks[q.Get("upload_id")][index] = data
		writeJSON(w, 200, map[string]any{"ok": true})
	case "/api/upload/complete":
		id := r.FormValue("upload_id")
		var data []byte
		for i := 0; i < len(d.chunks[id]); i++ {
			data = append(data, d.chunks[id][i]...)
		}
		m := d.meta[id]
		d.finishUpload(w, join(m[0], m[1]), data, r.FormValue("expect_mtime_ns"))
	case "/api/upload/abort":
		writeJSON(w, 200, map[string]any{"ok": true})
	case "/api/mkdir":
		p := join(r.FormValue("path"), r.FormValue("name"))
		if _, exists := d.files[p]; exists {
			fail(w, 409, "Target exists")
			return
		}
		d.dir(p)
		writeJSON(w, 200, d.entry(p))
	case "/api/delete":
		p := r.FormValue("path")
		delete(d.files, p)
		writeJSON(w, 200, map[string]any{"ok": true, "action": "recycled", "path": "#recycle/" + p})
	case "/api/move":
		src, dest := r.FormValue("path"), r.FormValue("dest")
		d.files[join(dest, path.Base(src))] = d.files[src]
		delete(d.files, src)
		writeJSON(w, 200, map[string]any{"ok": true})
	case "/api/search":
		results := []map[string]any{}
		for p := range d.files {
			if p != "" && strings.Contains(p, q.Get("q")) {
				results = append(results, d.entry(p))
			}
		}
		writeJSON(w, 200, map[string]any{"query": q.Get("q"), "results": results})
	case "/api/cli/logout":
		d.loggedOut = true
		writeJSON(w, 200, map[string]any{"ok": true})
	default:
		fail(w, 404, "no route "+r.URL.Path)
	}
}

func (d *fakeDrive) finishUpload(w http.ResponseWriter, p string, data []byte, expect string) {
	if expect != "" {
		want, _ := strconv.ParseInt(expect, 10, 64)
		current := int64(-1)
		if f, ok := d.files[p]; ok {
			current = f.mtimeNS
		}
		if current != want {
			fail(w, 409, "File changed on the Drive since you opened it")
			return
		}
	}
	d.put(p, string(data))
	writeJSON(w, 200, d.entry(p))
}
