package davfs

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"mime"
	"os"
	"path"
	"sort"
	"time"

	"github.com/neelsatyavolu/infocus-drive/cli/internal/api"
	"golang.org/x/net/webdav"
)

// fileInfo is an os.FileInfo for Drive items, shares and local files.
type fileInfo struct {
	name  string
	size  int64
	mtime time.Time
	dir   bool
}

func entryInfo(e api.Entry) fileInfo {
	return fileInfo{name: e.Name, size: e.Size, mtime: time.Unix(0, e.MtimeNS), dir: e.IsDir}
}

func (i fileInfo) Name() string       { return i.name }
func (i fileInfo) Size() int64        { return i.size }
func (i fileInfo) ModTime() time.Time { return i.mtime }
func (i fileInfo) IsDir() bool        { return i.dir }
func (i fileInfo) Sys() any           { return nil }

func (i fileInfo) Mode() fs.FileMode {
	if i.dir {
		return fs.ModeDir | 0o755
	}
	return 0o644
}

// ContentType implements webdav.ContentTyper so PROPFIND never downloads a
// file just to sniff its type.
func (i fileInfo) ContentType(context.Context) (string, error) {
	if t := mime.TypeByExtension(path.Ext(i.name)); t != "" {
		return t, nil
	}
	return "application/octet-stream", nil
}

var errNotSupported = errors.New("not supported")

// OpenFile implements webdav.FileSystem. x/net/webdav only opens files for
// reading or with O_RDWR|O_CREATE|O_TRUNC (PUT, COPY, LOCK), so any write
// open starts an empty file that replaces the target on Close — except for
// LOCK, which may only create a file that doesn't exist yet.
func (f *FS) OpenFile(ctx context.Context, name string, flag int, _ os.FileMode) (webdav.File, error) {
	if flag&(os.O_WRONLY|os.O_RDWR|os.O_CREATE|os.O_TRUNC|os.O_APPEND) != 0 {
		return f.create(ctx, name)
	}
	n, err := f.find(ctx, name)
	if err != nil {
		return nil, err
	}
	switch {
	case n.t.locked && !n.info.dir:
		return &noteFile{Reader: bytes.NewReader(lockedNoteText), info: n.info}, nil
	case n.info.dir && n.local == nil:
		return &dirFile{fs: f, ctx: ctx, n: n}, nil
	case n.local != nil && n.local.ghost != "":
		if n.info.dir {
			return &dirFile{fs: f, ctx: ctx, n: node{t: n.t.with(n.local.ghost), info: n.info}}, nil
		}
		return &remoteFile{ctx: ctx, fs: f, client: f.clientFor(n.t.share), rel: n.local.ghost, info: n.info}, nil
	case n.local != nil:
		file, err := os.Open(n.local.file)
		if err != nil {
			return nil, err
		}
		return &localFile{File: file, info: n.info}, nil
	}
	return &remoteFile{ctx: ctx, fs: f, client: f.clientFor(n.t.share), rel: n.t.rel, info: n.info}, nil
}

func (f *FS) create(ctx context.Context, name string) (webdav.File, error) {
	t, err := f.resolve(ctx, name)
	if err != nil {
		return nil, err
	}
	// Hidden files never reach the Drive, so Finder may keep its .DS_Store
	// and "._" files even in a read-only share.
	if t.isRoot() || t.rel == "" || t.locked || (!t.share.CanWrite && !localOnly(t.base())) {
		return nil, pathErr("open", name, os.ErrPermission)
	}
	parent, err := f.find(ctx, path.Dir("/"+api.CleanPath(name)))
	if err != nil || !parent.info.dir {
		return nil, pathErr("open", name, os.ErrNotExist)
	}
	existing, err := f.find(ctx, name)
	switch {
	case err == nil && existing.info.dir:
		return nil, pathErr("open", name, os.ErrExist)
	case err != nil && !os.IsNotExist(err):
		return nil, err // unsure whether it exists: never risk replacing it
	}
	tmp, err := f.local.tempFile()
	if err != nil {
		return nil, err
	}
	req := requestOf(ctx)
	return &writeFile{File: tmp, ctx: ctx, fs: f, t: t, name: t.base(), req: req,
		createOnly: req.method == "LOCK"}, nil
}

// readDir lists a folder: shares at the root, else Drive entries plus local ones.
func (f *FS) readDir(ctx context.Context, n node) ([]fs.FileInfo, error) {
	if n.t.locked {
		return []fs.FileInfo{f.lockedNoteInfo()}, nil
	}
	if n.t.isRoot() {
		shares, err := f.listShares(ctx)
		if err != nil {
			return nil, err
		}
		out := make([]fs.FileInfo, 0, len(shares))
		for _, s := range shares {
			out = append(out, fileInfo{name: shareName(s), dir: true, mtime: f.start})
		}
		return out, nil
	}
	items, err := f.list(ctx, n.t)
	if err != nil {
		return nil, err
	}
	local := f.local.children(n.t.share.ID, n.t.rel)
	out := make([]fs.FileInfo, 0, len(items)+len(local))
	for _, item := range items {
		if _, shadowed := local[item.Name]; !shadowed && !localOnly(item.Name) {
			out = append(out, entryInfo(item))
		}
	}
	for name, e := range local {
		out = append(out, e.info(name))
	}
	sort.Slice(out, func(i, j int) bool { return out[i].Name() < out[j].Name() })
	return out, nil
}

// dirFile is an open folder.
type dirFile struct {
	fs      *FS
	ctx     context.Context
	n       node
	entries []fs.FileInfo
	loaded  bool
}

func (d *dirFile) Readdir(count int) ([]fs.FileInfo, error) {
	if !d.loaded {
		entries, err := d.fs.readDir(d.ctx, d.n)
		if err != nil {
			return nil, err
		}
		d.entries, d.loaded = entries, true
	}
	if count <= 0 {
		out := d.entries
		d.entries = nil
		return out, nil
	}
	if len(d.entries) == 0 {
		return nil, io.EOF
	}
	n := min(count, len(d.entries))
	out := d.entries[:n]
	d.entries = d.entries[n:]
	return out, nil
}

func (d *dirFile) Stat() (fs.FileInfo, error)     { return d.n.info, nil }
func (d *dirFile) Close() error                   { return nil }
func (d *dirFile) Read([]byte) (int, error)       { return 0, errNotSupported }
func (d *dirFile) Write([]byte) (int, error)      { return 0, errNotSupported }
func (d *dirFile) Seek(int64, int) (int64, error) { return 0, errNotSupported }

// remoteFile reads a Drive file lazily with ranged downloads, so seeking
// (Range requests from Finder) doesn't fetch the whole file.
type remoteFile struct {
	ctx     context.Context
	fs      *FS
	client  *api.Client
	rel     string
	info    fileInfo
	off     int64
	body    io.ReadCloser
	bodyOff int64
}

func (r *remoteFile) Read(p []byte) (int, error) {
	if r.off >= r.info.size {
		return 0, io.EOF
	}
	if r.body == nil || r.bodyOff != r.off {
		r.closeBody()
		body, err := r.client.DownloadFrom(r.ctx, r.rel, r.off)
		if err != nil {
			requestOf(r.ctx).broken.Store(true)
			return 0, r.fs.osErr("read", r.rel, err)
		}
		r.body, r.bodyOff = body, r.off
	}
	n, err := r.body.Read(p)
	r.off += int64(n)
	r.bodyOff += int64(n)
	if err == io.EOF && r.off < r.info.size {
		err = io.ErrUnexpectedEOF
	}
	if err != nil && err != io.EOF {
		// x/net/webdav closes a COPY target even when the copy failed; this
		// tells that target not to upload.
		requestOf(r.ctx).broken.Store(true)
	}
	return n, err
}

func (r *remoteFile) Seek(offset int64, whence int) (int64, error) {
	switch whence {
	case io.SeekCurrent:
		offset += r.off
	case io.SeekEnd:
		offset += r.info.size
	}
	if offset < 0 {
		return 0, errors.New("seek before start of file")
	}
	r.off = offset
	return offset, nil
}

func (r *remoteFile) closeBody() {
	if r.body != nil {
		r.body.Close()
		r.body = nil
	}
}

func (r *remoteFile) Close() error                       { r.closeBody(); return nil }
func (r *remoteFile) Stat() (fs.FileInfo, error)         { return r.info, nil }
func (r *remoteFile) Readdir(int) ([]fs.FileInfo, error) { return nil, errNotSupported }
func (r *remoteFile) Write([]byte) (int, error)          { return 0, errNotSupported }

// localFile is an open local-only file.
type localFile struct {
	*os.File
	info fileInfo
}

func (l *localFile) Stat() (fs.FileInfo, error)         { return l.info, nil }
func (l *localFile) Readdir(int) ([]fs.FileInfo, error) { return nil, errNotSupported }
func (l *localFile) Write([]byte) (int, error)          { return 0, errNotSupported }

// writeFile buffers a PUT in a temp file; Close stores it locally (hidden
// names) or uploads it to the Drive.
type writeFile struct {
	*os.File
	ctx        context.Context
	fs         *FS
	t          target
	name       string
	req        *request
	createOnly bool  // LOCK: create if missing, never replace
	copyErr    error // first error while filling the temp file
}

func (w *writeFile) Write(p []byte) (int, error) {
	n, err := w.File.Write(p)
	w.fail(err)
	return n, err
}

// ReadFrom is what io.Copy uses (via *os.File); it fails on source errors too.
func (w *writeFile) ReadFrom(r io.Reader) (int64, error) {
	n, err := w.File.ReadFrom(r)
	w.fail(err)
	return n, err
}

func (w *writeFile) fail(err error) {
	if err != nil && w.copyErr == nil {
		w.copyErr = err
	}
}

// incomplete reports why the buffered content must not be saved, if so.
func (w *writeFile) incomplete(size int64) error {
	switch {
	case w.copyErr != nil:
		return w.copyErr
	case w.req.broken.Load():
		return errors.New("the source could not be read completely")
	case w.req.method == "PUT" && w.req.length >= 0 && size != w.req.length:
		return fmt.Errorf("received %d of %d bytes", size, w.req.length)
	}
	return nil
}

func (w *writeFile) Stat() (fs.FileInfo, error) {
	st, err := w.File.Stat()
	if err != nil {
		return nil, err
	}
	return fileInfo{name: w.name, size: st.Size(), mtime: st.ModTime()}, nil
}

func (w *writeFile) Readdir(int) ([]fs.FileInfo, error) { return nil, errNotSupported }

func (w *writeFile) Close() error {
	st, err := w.File.Stat()
	if err == nil {
		err = w.incomplete(st.Size())
	}
	if err := errors.Join(w.File.Close(), err); err != nil {
		os.Remove(w.File.Name())
		return fmt.Errorf("nothing was saved: %w", err)
	}
	if localOnly(w.name) {
		if _, exists := w.fs.local.get(w.t.key()); exists && w.createOnly {
			os.Remove(w.File.Name())
			return nil
		}
		if old, ok := w.fs.local.get(w.t.key()); ok && old.ghost != "" {
			w.fs.local.remove(w.t.key())
			if _, err := w.fs.clientFor(w.t.share).Delete(w.ctx, old.ghost); err != nil {
				os.Remove(w.File.Name())
				return w.fs.osErr("write", w.t.rel, err)
			}
		}
		w.fs.local.put(w.t.key(), localEntry{file: w.File.Name(), size: st.Size(), mtime: time.Now()})
		w.fs.changed()
		return nil
	}
	defer os.Remove(w.File.Name())
	opts := api.UploadOptions{}
	if w.createOnly {
		mustNotExist := api.MustNotExist
		opts.ExpectMtimeNS = &mustNotExist
	}
	err = w.fs.upload(w.ctx, w.t, w.File.Name(), opts)
	if w.createOnly && os.IsExist(err) {
		return nil // it exists after all; LOCK leaves it alone
	}
	return err
}
