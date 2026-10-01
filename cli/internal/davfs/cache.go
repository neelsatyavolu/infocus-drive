package davfs

import (
	"strings"

	"github.com/neelsatyavolu/infocus-drive/cli/internal/api"
)

// Listing cache upkeep. Writes update cached listings in place instead of
// dropping them all, so copying many files into a folder doesn't re-list it
// for every file (each listing is a round trip through the tunnel). Each
// change bumps the listing's generation, so a fetch that started before it
// isn't cached over it (see fetchList). Callers hold f.mu.

// changed marks key's listing as changed locally.
func (f *FS) changed(key string) { f.listGen[key]++ }

// cachePut records an entry the Drive just returned (upload, mkdir) in its
// parent's cached listing, if that listing is cached.
func (f *FS) cachePut(t target, e api.Entry) {
	dir, _ := api.SplitPath(t.rel)
	key := t.with(dir).key()
	f.mu.Lock()
	defer f.mu.Unlock()
	f.changed(key)
	cached, ok := f.lists[key]
	if !ok {
		return
	}
	items := make([]api.Entry, 0, len(cached.items)+1)
	for _, item := range cached.items {
		if item.Name != e.Name {
			items = append(items, item)
		}
	}
	f.lists[key] = cachedList{items: append(items, e), at: cached.at}
}

// cacheForget removes t from its parent's listing and drops cached listings
// of t and anything below it (a deleted or moved folder).
func (f *FS) cacheForget(t target) {
	dir, base := api.SplitPath(t.rel)
	parent := t.with(dir).key()
	prefix := t.key()
	f.mu.Lock()
	defer f.mu.Unlock()
	f.changed(parent)
	if cached, ok := f.lists[parent]; ok {
		items := make([]api.Entry, 0, len(cached.items))
		for _, item := range cached.items {
			if item.Name != base {
				items = append(items, item)
			}
		}
		f.lists[parent] = cachedList{items: items, at: cached.at}
	}
	below := func(key string) bool { return key == prefix || strings.HasPrefix(key, prefix+"/") }
	for key := range f.lists {
		if below(key) {
			f.changed(key)
			delete(f.lists, key)
		}
	}
	for key := range f.flights {
		if below(key) {
			f.changed(key)
		}
	}
}

// cacheDropParent forgets t's parent listing (its state is unknown now).
func (f *FS) cacheDropParent(t target) {
	dir, _ := api.SplitPath(t.rel)
	key := t.with(dir).key()
	f.mu.Lock()
	f.changed(key)
	delete(f.lists, key)
	f.mu.Unlock()
}

// cacheMoved updates the cache after src was renamed/moved to dst.
func (f *FS) cacheMoved(src, dst target) {
	f.cacheForget(src)
	f.cacheForget(dst)
	f.cacheDropParent(dst) // re-list to learn the moved item's details
}
