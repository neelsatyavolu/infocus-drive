// Package davfs serves a user's Drive shares as a WebDAV file system so Finder
// can mount them through a local server (`infocus webdav`, used by the Mac app).
//
// Layout: the WebDAV root lists the shares the account can open, one folder
// each; everything below a share folder maps onto the Drive API.
//
// Names the Drive hides from listings (macOS "._" AppleDouble files,
// .DS_Store, *.tmp …) never reach the Drive. They live in a local store for
// as long as the server runs, so Finder and apps that save through a temp
// file still see what they wrote.
package davfs

import (
	"context"
	"errors"
	"fmt"
	"os"
	"path"
	"strings"
	"sync"
	"time"

	"github.com/neelsatyavolu/infocus-drive/cli/internal/api"
)

const (
	listTTL   = 10 * time.Second // Finder re-lists folders constantly; writes update the cache in place
	sharesTTL = time.Minute
)

// FS implements webdav.FileSystem on top of the Drive API.
type FS struct {
	client *api.Client
	local  *localStore
	start  time.Time

	// OnSignedOut is called when the Drive rejects the token (optional).
	OnSignedOut func()
	// OnUpload is called as uploads start, progress and finish (optional).
	OnUpload func(Upload)
	// OnWriting reports how many files are open for writing (a Finder copy in
	// progress, before its upload starts), so the app never restarts mid-copy.
	OnWriting func(open int)

	mu        sync.Mutex
	lists     map[string]cachedList
	shares    []api.Share
	sharesAt  time.Time
	uploadSeq int64
	writing   int
	sharesMu  sync.Mutex // serializes share-list refreshes
	locks     *pendingLocks
}

type cachedList struct {
	items []api.Entry
	at    time.Time
}

// New returns a file system for client's account. Local-only files are kept
// in tempDir, which the caller creates and removes.
func New(client *api.Client, tempDir string) *FS {
	return &FS{
		client: client,
		local:  newLocalStore(tempDir),
		start:  time.Now(),
		lists:  map[string]cachedList{},
	}
}

// target is a WebDAV name resolved to a share and a path inside it.
type target struct {
	share  api.Share // zero value = the root that lists shares
	rel    string    // path inside the share; "" = the share itself
	locked bool      // a locked personal folder (only its root and LockedNote)
}

func (t target) isRoot() bool { return t.share.ID == "" }

func (t target) key() string { return t.share.ID + "\x00" + t.rel }

func (t target) base() string { return path.Base("/" + t.rel) }

func (t target) with(rel string) target { return target{share: t.share, rel: rel} }

// shareName is the folder name a share gets at the WebDAV root.
func shareName(s api.Share) string {
	name := strings.ReplaceAll(strings.TrimSpace(s.Name), "/", "-")
	if name == "" {
		return strings.ReplaceAll(s.ID, "/", "-")
	}
	return name
}

// localOnly mirrors fsops._is_hidden_entry on the Drive, plus "._" files:
// anything the Drive would hide from listings stays on this Mac.
func localOnly(name string) bool {
	switch name {
	case ".DS_Store", "Thumbs.db", "desktop.ini":
		return true
	}
	if strings.HasPrefix(name, "._") || strings.HasPrefix(name, ".ifd-") {
		return true
	}
	lower := strings.ToLower(name)
	for _, suffix := range []string{".ug-tmp", ".ugtmp", ".tmp", ".partial", ".crdownload"} {
		if strings.HasSuffix(lower, suffix) {
			return true
		}
	}
	return false
}

// errLocked: an encrypted personal folder that isn't unlocked. Finder shows it
// as "no permission"; the Mac app offers Unlock.
var errLocked = fmt.Errorf("%w: personal folder is locked", os.ErrPermission)

// lockedRecheck limits how often a locked share makes us re-read the share
// list (to notice an unlock right away without asking on every request).
const lockedRecheck = time.Second

func pathErr(op, name string, err error) error {
	return &os.PathError{Op: op, Path: name, Err: err}
}

// osErr turns Drive API errors into the os errors x/net/webdav understands.
func (f *FS) osErr(op, name string, err error) error {
	var apiErr *api.Error
	if !errors.As(err, &apiErr) {
		return err
	}
	switch apiErr.Status {
	case 401:
		if f.OnSignedOut != nil {
			f.OnSignedOut()
		}
		return pathErr(op, name, fmt.Errorf("%w: %v", os.ErrPermission, err))
	case 403:
		return pathErr(op, name, fmt.Errorf("%w: %v", os.ErrPermission, err))
	case 404:
		return pathErr(op, name, os.ErrNotExist)
	case 423, 428: // encrypted personal folder is locked
		return pathErr(op, name, errLocked)
	case 409:
		return pathErr(op, name, os.ErrExist)
	}
	return err
}

func (f *FS) clientFor(s api.Share) *api.Client {
	c := *f.client
	c.Share = s.ID
	return &c
}

func (f *FS) listShares(ctx context.Context) ([]api.Share, error) {
	return f.fetchShares(ctx, sharesTTL)
}

func (f *FS) fetchShares(ctx context.Context, maxAge time.Duration) ([]api.Share, error) {
	// One /api/me at a time: Finder's parallel requests share the answer.
	f.sharesMu.Lock()
	defer f.sharesMu.Unlock()
	f.mu.Lock()
	if f.shares != nil && time.Since(f.sharesAt) < maxAge {
		shares := f.shares
		f.mu.Unlock()
		return shares, nil
	}
	f.mu.Unlock()
	me, err := f.client.Me(ctx)
	if err != nil {
		return nil, f.osErr("stat", "/", err)
	}
	if !me.Authenticated {
		return nil, f.osErr("stat", "/", &api.Error{Status: 401})
	}
	shares := me.Shares
	if shares == nil {
		shares = []api.Share{}
	}
	f.mu.Lock()
	f.shares, f.sharesAt = shares, time.Now()
	f.mu.Unlock()
	return shares, nil
}

func (f *FS) resolve(ctx context.Context, name string) (target, error) {
	// CleanPath treats "\" as a separator, but on a Mac it is part of a
	// name; refuse such names rather than write somewhere else.
	if strings.Contains(name, "\\") {
		return target{}, pathErr("stat", name, os.ErrNotExist)
	}
	clean := api.CleanPath(name)
	if clean == "" {
		return target{}, nil
	}
	head, rest, _ := strings.Cut(clean, "/")
	shares, err := f.listShares(ctx)
	if err != nil {
		return target{}, err
	}
	for _, s := range shares {
		if shareName(s) != head {
			continue
		}
		if s.Locked {
			// It may have been unlocked (here, on the website or in the app).
			if fresh, err := f.fetchShares(ctx, lockedRecheck); err == nil {
				for _, again := range fresh {
					if again.ID == s.ID {
						s = again
					}
				}
			}
			if s.Locked {
				if rest == "" || rest == LockedNote {
					return target{share: s, rel: rest, locked: true}, nil
				}
				return target{}, pathErr("open", name, errLocked)
			}
		}
		return target{share: s, rel: rest}, nil
	}
	return target{}, pathErr("stat", name, os.ErrNotExist)
}

// list returns a Drive folder's entries, cached briefly.
func (f *FS) list(ctx context.Context, t target) ([]api.Entry, error) {
	f.mu.Lock()
	cached, ok := f.lists[t.key()]
	f.mu.Unlock()
	if ok && time.Since(cached.at) < listTTL {
		return cached.items, nil
	}
	listing, err := f.clientFor(t.share).List(ctx, t.rel)
	if err != nil {
		return nil, f.osErr("readdir", t.rel, err)
	}
	f.mu.Lock()
	f.lists[t.key()] = cachedList{items: listing.Items, at: time.Now()}
	f.mu.Unlock()
	return listing.Items, nil
}

// node is a resolved, existing name.
type node struct {
	t     target
	info  fileInfo
	local *localEntry // set for local-only files and ghosts
}

func (f *FS) find(ctx context.Context, name string) (node, error) {
	t, err := f.resolve(ctx, name)
	if err != nil {
		return node{}, err
	}
	if t.isRoot() {
		return node{t: t, info: fileInfo{name: "/", dir: true, mtime: f.start}}, nil
	}
	if t.rel == "" {
		return node{t: t, info: fileInfo{name: shareName(t.share), dir: true, mtime: f.start}}, nil
	}
	if t.locked {
		return node{t: t, info: f.lockedNoteInfo()}, nil
	}
	if entry, ok := f.local.get(t.key()); ok {
		return node{t: t, info: entry.info(t.base()), local: &entry}, nil
	}
	if localOnly(t.base()) {
		return node{}, pathErr("stat", name, os.ErrNotExist)
	}
	dir, base := api.SplitPath(t.rel)
	items, err := f.list(ctx, t.with(dir))
	if err != nil {
		return node{}, err
	}
	for _, item := range items {
		if item.Name == base {
			return node{t: t, info: entryInfo(item)}, nil
		}
	}
	return node{}, pathErr("stat", name, os.ErrNotExist)
}

// Stat implements webdav.FileSystem.
func (f *FS) Stat(ctx context.Context, name string) (os.FileInfo, error) {
	n, err := f.find(ctx, name)
	if err != nil {
		return nil, err
	}
	return n.info, nil
}

// writable resolves name for a change inside a share the account can write.
func (f *FS) writable(ctx context.Context, op, name string) (target, error) {
	t, err := f.resolve(ctx, name)
	if err != nil {
		return target{}, err
	}
	if t.isRoot() || t.rel == "" || t.locked || !t.share.CanWrite {
		return target{}, pathErr(op, name, os.ErrPermission)
	}
	return t, nil
}

// Mkdir implements webdav.FileSystem.
func (f *FS) Mkdir(ctx context.Context, name string, _ os.FileMode) error {
	t, err := f.writable(ctx, "mkdir", name)
	if err != nil {
		return err
	}
	dir, base := api.SplitPath(t.rel)
	entry, err := f.clientFor(t.share).Mkdir(ctx, dir, base)
	if err != nil {
		f.cacheDropParent(t)
		return f.osErr("mkdir", name, err)
	}
	f.cachePut(t, entry)
	return nil
}

// RemoveAll implements webdav.FileSystem. Drive items go to the recycle bin.
func (f *FS) RemoveAll(ctx context.Context, name string) error {
	t, err := f.writable(ctx, "remove", name)
	if err != nil {
		return err
	}
	if f.replacedByMove(ctx, t) {
		return nil
	}
	f.local.removeTree(t.share.ID, t.rel)
	entry, isLocal := f.local.remove(t.key())
	remote := t.rel
	switch {
	case isLocal && entry.ghost == "":
		return nil
	case isLocal:
		remote = entry.ghost
	case localOnly(t.base()):
		return nil
	}
	if _, err := f.clientFor(t.share).Delete(ctx, remote); err != nil {
		if err := f.osErr("remove", name, err); !os.IsNotExist(err) {
			f.cacheDropParent(t.with(remote)) // it may still be there
			return err
		}
	}
	f.cacheForget(t.with(remote))
	return nil
}

// replacedByMove reports whether RemoveAll(t) is x/net/webdav clearing the
// destination of a MOVE whose source is a local temp file (an app's safe
// save). Rename then uploads over the document, which replaces it only once
// the upload succeeded; deleting it first would lose it if the upload failed.
func (f *FS) replacedByMove(ctx context.Context, t target) bool {
	req := requestOf(ctx)
	if req.method != "MOVE" || api.CleanPath(shareName(t.share)+"/"+t.rel) != req.moveDst || localOnly(t.base()) {
		return false
	}
	src, err := f.find(ctx, req.moveSrc)
	if err != nil || src.local == nil || src.local.ghost != "" || src.local.pending || src.t.share.ID != t.share.ID {
		return false
	}
	dst, err := f.find(ctx, shareName(t.share)+"/"+t.rel)
	return err == nil && !dst.info.dir && dst.local == nil
}

// Rename implements webdav.FileSystem (MOVE). Moves between shares aren't
// supported by the Drive, so they fail.
func (f *FS) Rename(ctx context.Context, oldName, newName string) error {
	src, err := f.writable(ctx, "rename", oldName)
	if err != nil {
		return err
	}
	dst, err := f.writable(ctx, "rename", newName)
	if err != nil {
		return err
	}
	if src.share.ID != dst.share.ID {
		return pathErr("rename", newName, fmt.Errorf("%w: can't move between shares", os.ErrPermission))
	}
	n, err := f.find(ctx, oldName)
	if err != nil {
		return err
	}
	client := f.clientFor(src.share)
	hidden := localOnly(dst.base())
	switch {
	case n.local != nil && n.local.pending:
		// Moving a file Finder hasn't written yet: it's an empty file now.
		f.local.remove(src.key())
		return f.createEmpty(ctx, dst, false)
	case n.local != nil && n.local.ghost == "" && hidden:
		f.local.move(src.key(), dst.key())
		return nil
	case n.local != nil && n.local.ghost == "":
		// An app saved to a temp name and is renaming it into place.
		if err := f.upload(ctx, dst, n.local.file, api.UploadOptions{}); err != nil {
			return err
		}
		f.local.remove(src.key())
		return nil
	case n.local != nil:
		if err := f.moveRemote(ctx, client, n.local.ghost, dst.rel); err != nil {
			f.cacheDropParent(src.with(n.local.ghost))
			f.cacheDropParent(dst)
			return f.osErr("rename", newName, err)
		}
		f.cacheMoved(src.with(n.local.ghost), dst)
		f.local.remove(src.key())
	default:
		if err := f.moveRemote(ctx, client, src.rel, dst.rel); err != nil {
			f.cacheDropParent(src)
			f.cacheDropParent(dst)
			return f.osErr("rename", newName, err)
		}
		f.cacheMoved(src, dst)
	}
	if n.info.dir {
		f.local.moveTree(src.share.ID, src.rel, dst.rel)
	}
	if hidden {
		// The Drive hides the new name, so remember it or it would vanish.
		f.local.put(dst.key(), localEntry{ghost: dst.rel, size: n.info.size, mtime: n.info.mtime, dir: n.info.dir})
	}
	return nil
}

// moveRemote renames and/or moves a Drive item from one path to another.
func (f *FS) moveRemote(ctx context.Context, c *api.Client, from, to string) error {
	fromDir, fromName := api.SplitPath(from)
	toDir, toName := api.SplitPath(to)
	if fromName != toName {
		if err := c.Rename(ctx, from, toName); err != nil {
			return err
		}
		from = path.Join(fromDir, toName)
	}
	if fromDir == toDir {
		return nil
	}
	if err := c.Move(ctx, from, toDir); err != nil {
		if fromName != toName {
			_ = c.Rename(ctx, from, fromName) // best effort: put it back
		}
		return err
	}
	return nil
}

// finishPending runs when Finder unlocks a file: if it LOCKed a new name but
// never wrote it (e.g. `touch`), create the empty file on the Drive now.
func (f *FS) finishPending(name string) {
	t, err := f.resolve(context.Background(), name)
	if err != nil {
		return
	}
	entry, ok := f.local.get(t.key())
	if !ok || !entry.pending {
		return
	}
	f.local.remove(t.key())
	ctx, cancel := context.WithTimeout(context.Background(), time.Minute)
	defer cancel()
	_ = f.createEmpty(ctx, t, true) // exists already (someone else) is fine
}

// createEmpty uploads an empty file to t (only if missing, when mustNotExist).
func (f *FS) createEmpty(ctx context.Context, t target, mustNotExist bool) error {
	tmp, err := f.local.tempFile()
	if err != nil {
		return err
	}
	tmp.Close()
	defer os.Remove(tmp.Name())
	opts := api.UploadOptions{}
	if mustNotExist {
		m := api.MustNotExist
		opts.ExpectMtimeNS = &m
	}
	return f.upload(ctx, t, tmp.Name(), opts)
}

// FinishPending creates every file Finder LOCKed but never wrote (on shutdown).
func (f *FS) FinishPending() {
	if f.locks != nil {
		f.locks.finishAll()
	}
}
