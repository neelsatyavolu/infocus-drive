package app

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"io"
	"net/http"
	"path"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"time"

	"github.com/neelsatyavolu/infocus-drive/cli/internal/api"
	"github.com/neelsatyavolu/infocus-drive/cli/internal/transfer"
)

// Backup copies a local folder to a Drive folder and remembers what it sent
// (--state), so a run where little changed only walks the local folder: no
// Drive listing and no file reads for unchanged files. Files deleted locally
// are moved to the share's Recycle bin once they've been gone --delete-after;
// only files this backup uploaded, only if nobody changed them on the Drive
// since (checked again right before), and only on a share with a Recycle bin.
// The first run, and --verify, check the whole Drive folder.

const (
	backupListWorkers    = 8
	backupCompareWorkers = 4
)

type backupDelete struct {
	rel, remote string
	mtimeNS     int64 // the Drive copy must still have this mtime
}

type backupPlan struct {
	jobs      []uploadJob
	compare   []uploadJob // same size, unknown content: fingerprint first
	keep      map[string]transfer.BackupFile
	missing   map[string]int64
	conflicts []string
	deletes   []backupDelete
	pending   int // gone locally, still inside the grace period
	unchanged int
}

type backupResult struct {
	Uploaded      int            `json:"uploaded"`
	Bytes         int64          `json:"bytes"`
	Unchanged     int            `json:"unchanged"`
	Deleted       []string       `json:"deleted"`
	PendingDelete int            `json:"pending_delete"`
	Conflicts     []string       `json:"conflicts"`
	Failed        []failedUpload `json:"failed"`
	Unseen        int            `json:"unseen"`
	NoRecycleBin  bool           `json:"no_recycle_bin,omitempty"` // deletions held: the share has no Recycle bin
	Verified      bool           `json:"verified"`
	ElapsedMS     int64          `json:"elapsed_ms"`
}

// backupInput is everything planBackup decides from.
type backupInput struct {
	scan        transfer.BackupScan
	state       transfer.BackupState
	index       map[string]api.Entry // Drive entries by full path (all of root, or the listed folders)
	root        string
	full        bool // index covers all of root
	now         time.Time
	deleteAfter time.Duration // 0 = never delete
}

// unchangedLocally: same size and mtime as when this backup last sent it.
func unchangedLocally(f transfer.File, st transfer.BackupFile, known bool) bool {
	return known && st.Size == f.Size && st.ModTime == f.ModTime
}

// deletionDue: a backed-up file has been missing locally for the grace period.
func deletionDue(first int64, now time.Time, after time.Duration) bool {
	return after > 0 && now.Sub(time.Unix(first, 0)) >= after
}

// trackDeletions: an empty scan with a non-empty backup is far more likely a
// missing disk or a revoked permission than everything deleted on purpose.
func trackDeletions(in backupInput) bool {
	return len(in.scan.Files) > 0 || len(in.state.Files) == 0
}

// backupDirsToList: in a quick run, the Drive folders whose listing the plan
// needs (parents of new or changed files and of deletions that are due).
func backupDirsToList(in backupInput) []string {
	dirs := map[string]bool{}
	local := map[string]bool{}
	for _, f := range in.scan.Files {
		local[f.Rel] = true
		st, known := in.state.Files[f.Rel]
		if !unchangedLocally(f, st, known) {
			dirs[path.Dir(path.Join(in.root, f.Rel))] = true
		}
	}
	if trackDeletions(in) {
		for rel := range in.state.Files {
			first, ok := in.state.Missing[rel]
			if !local[rel] && !in.scan.Covers(rel) && ok && deletionDue(first, in.now, in.deleteAfter) {
				dirs[path.Dir(path.Join(in.root, rel))] = true
			}
		}
	}
	out := make([]string, 0, len(dirs))
	for d := range dirs {
		if d == "." {
			d = ""
		}
		out = append(out, d)
	}
	sort.Strings(out)
	return out
}

func planBackup(in backupInput) backupPlan {
	plan := backupPlan{keep: map[string]transfer.BackupFile{}, missing: map[string]int64{}}
	local := map[string]bool{}
	for _, f := range in.scan.Files {
		local[f.Rel] = true
		full := path.Join(in.root, f.Rel)
		f.Remote = full
		st, known := in.state.Files[f.Rel]
		same := unchangedLocally(f, st, known)
		e, have := in.index[full]
		if same && !in.full {
			plan.keep[f.Rel] = st
			plan.unchanged++
			continue
		}
		if same && have && !e.IsDir && e.Size == f.Size && (st.RemoteMtimeNS == 0 || e.MtimeNS == st.RemoteMtimeNS) {
			plan.keep[f.Rel] = transfer.BackupFile{Size: f.Size, ModTime: f.ModTime, RemoteMtimeNS: e.MtimeNS, Owned: st.Owned}
			plan.unchanged++
			continue
		}
		switch {
		case !have:
			must := api.MustNotExist
			plan.jobs = append(plan.jobs, uploadJob{file: f, expect: &must})
		case e.IsDir:
			plan.conflicts = append(plan.conflicts, full)
		case same || e.Size != f.Size:
			// Changed here, or the Drive copy changed: the Mac's copy wins.
			mtime := e.MtimeNS
			plan.jobs = append(plan.jobs, uploadJob{file: f, expect: &mtime})
		default:
			mtime := e.MtimeNS
			plan.compare = append(plan.compare, uploadJob{file: f, expect: &mtime})
		}
	}
	track := trackDeletions(in)
	for rel, st := range in.state.Files {
		if local[rel] {
			continue
		}
		if !track || in.scan.Covers(rel) {
			plan.keep[rel] = st // excluded or unreadable now: leave the Drive copy alone
			if first, ok := in.state.Missing[rel]; ok {
				plan.missing[rel] = first
			}
			continue
		}
		if !st.Owned {
			continue // found on the Drive, not uploaded by this backup: never remove it
		}
		first, ok := in.state.Missing[rel]
		if !ok {
			first = in.now.Unix()
		}
		if !deletionDue(first, in.now, in.deleteAfter) {
			plan.keep[rel] = st
			plan.missing[rel] = first
			plan.pending++
			continue
		}
		full := path.Join(in.root, rel)
		e, have := in.index[full]
		if !have || e.IsDir || st.RemoteMtimeNS == 0 || e.MtimeNS != st.RemoteMtimeNS {
			continue // already gone, or changed on the Drive since: forget it, delete nothing
		}
		plan.deletes = append(plan.deletes, backupDelete{rel: rel, remote: full, mtimeNS: st.RemoteMtimeNS})
	}
	sort.Strings(plan.conflicts)
	sort.Slice(plan.deletes, func(i, j int) bool { return plan.deletes[i].remote < plan.deletes[j].remote })
	return plan
}

func cmdBackup(ctx context.Context, r *runner, args []string) error {
	fs := flag.NewFlagSet("backup", flag.ContinueOnError)
	stateFile := fs.String("state", "", "file that remembers what was backed up")
	deleteAfter := fs.Duration("delete-after", 7*24*time.Hour, "remove files from the Drive after they've been deleted locally this long (0 = never)")
	verify := fs.Bool("verify", false, "check every file against the Drive, not just local changes")
	progress := fs.Bool("progress", false, "write progress as JSON lines on stderr")
	var excludes multiFlag
	fs.Var(&excludes, "exclude", "path relative to LOCAL_DIR to leave out (repeatable)")
	rest, err := parseFlags(fs, args)
	if err != nil {
		return err
	}
	if len(rest) != 2 || *stateFile == "" {
		return usagef("usage: infocus backup LOCAL_DIR REMOTE_DIR --state FILE [--delete-after 168h] [--exclude REL]... [--verify] [--progress]")
	}
	if *deleteAfter < 0 {
		return usagef("--delete-after can't be negative")
	}
	localRoot, err := filepath.Abs(rest[0])
	if err != nil {
		return usageError{err.Error()}
	}
	root := api.CleanPath(rest[1])
	for _, part := range strings.Split(root, "/") {
		if part == "#recycle" {
			return usagef("REMOTE_DIR can't be in the Recycle bin")
		}
	}
	unlock, err := transfer.LockBackupState(*stateFile)
	if err != nil {
		return err
	}
	defer unlock()
	r.progressEvents = *progress
	client, err := r.signedIn()
	if err != nil {
		return err
	}
	started := time.Now()
	state, err := transfer.LoadBackupState(*stateFile, client.Base.String(), client.Share, localRoot, root)
	if err != nil {
		return err
	}

	r.phase("scanning")
	scan, err := transfer.ScanBackup(localRoot, excludes)
	if err != nil {
		return usageError{err.Error()}
	}
	in := backupInput{
		scan: scan, state: state, root: root, now: r.now(), deleteAfter: *deleteAfter,
		full: *verify || len(state.Files) == 0,
	}
	r.phase("checking")
	if in.full {
		in.index, err = parallelRemoteIndex(ctx, client, root)
	} else {
		in.index, err = listDirs(ctx, client, backupDirsToList(in))
	}
	if err != nil {
		return err
	}
	plan := planBackup(in)
	if err := compareBackup(ctx, client, &plan, state); err != nil {
		return err
	}

	r.phase("uploading")
	ready, mkdirFailed := ensureBackupDirs(ctx, client, plan.jobs, in.index)
	batch := r.runUploads(ctx, client, ready)
	batch.Failed = append(batch.Failed, mkdirFailed...)

	r.phase("deleting")
	noRecycle := false
	if len(plan.deletes) > 0 && ctx.Err() == nil {
		// Deleting on a share without a Recycle bin would be permanent: hold off.
		if noRecycle, err = lacksRecycleBin(ctx, client); err != nil {
			noRecycle = true
		}
	}
	deleted, deleteFailed, kept := []string{}, map[string]bool{}, map[string]bool{}
	if noRecycle {
		for _, d := range plan.deletes {
			kept[d.remote] = true
		}
	} else {
		deleted, deleteFailed, kept = deleteBackedUp(ctx, client, plan.deletes)
	}
	for _, d := range plan.deletes {
		switch {
		case deleteFailed[d.remote], kept[d.remote] && noRecycle:
			plan.keep[d.rel] = state.Files[d.rel]
			plan.missing[d.rel] = state.Missing[d.rel]
			plan.pending++
		default: // removed, or changed on the Drive since: forget it either way
			delete(plan.keep, d.rel)
		}
	}

	// Uploaded files are now owned; a failed or unattempted one keeps its old
	// record, so a later local delete still finds it.
	for _, job := range plan.jobs {
		if entry, ok := batch.entries[job.file.Remote]; ok {
			plan.keep[job.file.Rel] = transfer.BackupFile{Size: job.file.Size, ModTime: job.file.ModTime,
				RemoteMtimeNS: entry.MtimeNS, Owned: true}
		} else if prev, known := state.Files[job.file.Rel]; known {
			plan.keep[job.file.Rel] = prev
		}
	}
	state.Files, state.Missing = plan.keep, plan.missing
	if err := state.Save(*stateFile); err != nil {
		return err
	}

	failed := batch.Failed
	for remote := range deleteFailed {
		failed = append(failed, failedUpload{remote, "couldn't move to the Recycle bin"})
	}
	result := backupResult{
		Uploaded: len(batch.Uploaded), Bytes: batch.Bytes,
		Unchanged: plan.unchanged, Deleted: deleted, PendingDelete: plan.pending,
		Conflicts: append(append(plan.conflicts, batch.Conflicts...), batch.Exists...), Failed: failed,
		Unseen: len(scan.Unseen), Verified: in.full, ElapsedMS: time.Since(started).Milliseconds(),
		NoRecycleBin: noRecycle,
	}
	if err := r.emit(result, func(w io.Writer) {
		fmt.Fprintf(w, "Backed up %d file(s) (%s), %d unchanged, in %s\n", result.Uploaded, formatSize(result.Bytes),
			result.Unchanged, time.Duration(result.ElapsedMS)*time.Millisecond)
		for _, p := range result.Deleted {
			fmt.Fprintf(w, "Removed (deleted locally): %s\n", p)
		}
		if result.NoRecycleBin {
			fmt.Fprintln(w, "This share has no Recycle bin, so files deleted locally stay on the Drive.")
		}
		if result.PendingDelete > 0 {
			fmt.Fprintf(w, "Deleted locally, removed from the Drive after %s: %d file(s)\n", *deleteAfter, result.PendingDelete)
		}
		for _, p := range result.Conflicts {
			fmt.Fprintf(w, "Conflict, skipped: %s\n", p)
		}
		for _, f := range result.Failed {
			fmt.Fprintf(w, "Failed: %s: %s\n", f.Path, f.Error)
		}
	}); err != nil {
		return err
	}
	switch {
	case batch.authErr != nil:
		return batch.authErr
	case ctx.Err() != nil:
		return ctx.Err()
	case len(result.Failed) > 0:
		return exitError{ExitError, fmt.Sprintf("%d file(s) failed; the next backup retries them", len(result.Failed))}
	case len(result.Conflicts) > 0:
		return exitError{ExitConflict, fmt.Sprintf("%d conflict(s): the Drive has a folder where a file goes", len(result.Conflicts))}
	}
	return nil
}

// phase tells the Mac app what the backup is doing (with --progress).
func (r *runner) phase(name string) {
	if r.progressEvents {
		writeEvent(r.env.Stderr, map[string]any{"event": "phase", "phase": name})
	}
}

// parallelRemoteIndex lists everything under root, several folders at a time.
// A missing root is an empty index.
func parallelRemoteIndex(ctx context.Context, client *api.Client, root string) (map[string]api.Entry, error) {
	index := map[string]api.Entry{}
	var (
		mu       sync.Mutex
		wg       sync.WaitGroup
		firstErr error
	)
	sem := make(chan struct{}, backupListWorkers)
	var walk func(dir string)
	walk = func(dir string) {
		defer wg.Done()
		sem <- struct{}{}
		listing, err := client.List(ctx, dir)
		<-sem
		mu.Lock()
		defer mu.Unlock()
		if err != nil {
			var apiErr *api.Error
			if !(dir == root && errors.As(err, &apiErr) && apiErr.Status == http.StatusNotFound) && firstErr == nil {
				firstErr = err
			}
			return
		}
		if dir != "" {
			index[dir] = api.Entry{Path: dir, IsDir: true}
		}
		for _, e := range listing.Items {
			index[e.Path] = e
			if e.IsDir && e.Name != "#recycle" && firstErr == nil {
				wg.Add(1)
				go walk(e.Path)
			}
		}
	}
	wg.Add(1)
	go walk(root)
	wg.Wait()
	return index, firstErr
}

// listDirs lists just these folders (a missing one lists as empty). Each
// listed folder is in the index too, so creating it again is skipped.
func listDirs(ctx context.Context, client *api.Client, dirs []string) (map[string]api.Entry, error) {
	index := map[string]api.Entry{}
	var (
		mu       sync.Mutex
		wg       sync.WaitGroup
		firstErr error
	)
	sem := make(chan struct{}, backupListWorkers)
	for _, dir := range dirs {
		wg.Add(1)
		go func(dir string) {
			defer wg.Done()
			sem <- struct{}{}
			listing, err := client.List(ctx, dir)
			<-sem
			mu.Lock()
			defer mu.Unlock()
			var apiErr *api.Error
			if errors.As(err, &apiErr) && apiErr.Status == http.StatusNotFound {
				return
			}
			if err != nil {
				if firstErr == nil {
					firstErr = err
				}
				return
			}
			for p := dir; p != "" && p != "."; p = path.Dir(p) {
				index[p] = api.Entry{Path: p, IsDir: true}
			}
			for _, e := range listing.Items {
				index[e.Path] = e
			}
		}(dir)
	}
	wg.Wait()
	return index, firstErr
}

// compareBackup fingerprints same-size files (first runs, or a touched file
// with the same size): identical ones are kept, the rest become uploads.
func compareBackup(ctx context.Context, client *api.Client, plan *backupPlan, state transfer.BackupState) error {
	var (
		mu       sync.Mutex
		wg       sync.WaitGroup
		firstErr error
	)
	sem := make(chan struct{}, backupCompareWorkers)
	for _, job := range plan.compare {
		wg.Add(1)
		go func(job uploadJob) {
			defer wg.Done()
			sem <- struct{}{}
			same, err := sameContent(ctx, client, job.file, job.file.Remote)
			<-sem
			mu.Lock()
			defer mu.Unlock()
			switch {
			case err != nil:
				if firstErr == nil {
					firstErr = err
				}
			case same:
				// Identical content doesn't make it ours: ownership only carries over.
				prev := state.Files[job.file.Rel]
				plan.keep[job.file.Rel] = transfer.BackupFile{Size: job.file.Size, ModTime: job.file.ModTime,
					RemoteMtimeNS: *job.expect, Owned: prev.Owned && prev.RemoteMtimeNS == *job.expect}
				plan.unchanged++
			default:
				plan.jobs = append(plan.jobs, job)
			}
		}(job)
	}
	wg.Wait()
	plan.compare = nil
	return firstErr
}

// ensureBackupDirs creates the Drive folders the uploads need. A folder that
// can't be made fails only the files inside it.
func ensureBackupDirs(ctx context.Context, client *api.Client, jobs []uploadJob, index map[string]api.Entry) ([]uploadJob, []failedUpload) {
	known := map[string]bool{"": true}
	for p, e := range index {
		if e.IsDir {
			known[p] = true
		}
	}
	broken := map[string]error{}
	var ready []uploadJob
	var failed []failedUpload
	for _, job := range jobs {
		dir, _ := api.SplitPath(job.file.Remote)
		err, seen := broken[dir]
		if !seen && !known[dir] {
			err = mkdirAll(ctx, client, []string{dir}, known)
			if err != nil {
				broken[dir] = err
			}
		}
		if err != nil {
			failed = append(failed, failedUpload{job.file.Remote, err.Error()})
			continue
		}
		ready = append(ready, job)
	}
	return ready, failed
}

// lacksRecycleBin: the share root has no #recycle folder, so a delete would be permanent.
func lacksRecycleBin(ctx context.Context, client *api.Client) (bool, error) {
	listing, err := client.List(ctx, "")
	if err != nil {
		return true, err
	}
	for _, e := range listing.Items {
		if e.IsDir && e.Name == "#recycle" {
			return false, nil
		}
	}
	return true, nil
}

// deleteBackedUp moves files deleted locally to the share's Recycle bin. Each
// is checked again just before: still a file, still the copy this backup sent.
// Returns the removed paths, the ones that failed (retried next run) and the
// ones left alone because they changed on the Drive.
func deleteBackedUp(ctx context.Context, client *api.Client, deletes []backupDelete) ([]string, map[string]bool, map[string]bool) {
	deleted := []string{}
	failed := map[string]bool{}
	changed := map[string]bool{}
	for _, d := range deletes {
		if ctx.Err() != nil {
			failed[d.remote] = true
			continue
		}
		entry, found, err := client.Stat(ctx, d.remote)
		switch {
		case err != nil:
			failed[d.remote] = true
			continue
		case !found:
			deleted = append(deleted, d.remote)
			continue
		case entry.IsDir || entry.MtimeNS != d.mtimeNS:
			changed[d.remote] = true
			continue
		}
		_, err = client.Delete(ctx, d.remote)
		var apiErr *api.Error
		if err == nil || (errors.As(err, &apiErr) && apiErr.Status == http.StatusNotFound) {
			deleted = append(deleted, d.remote)
			continue
		}
		failed[d.remote] = true
	}
	return deleted, failed, changed
}

// multiFlag collects a repeatable string flag.
type multiFlag []string

func (m *multiFlag) String() string { return strings.Join(*m, ",") }

func (m *multiFlag) Set(v string) error {
	*m = append(*m, v)
	return nil
}
