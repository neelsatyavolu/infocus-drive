package transfer

import (
	"encoding/json"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path"
	"path/filepath"
	"strings"
)

// BackupFile is what the last backup knew about one file: the local size and
// mtime it uploaded (or confirmed), and the Drive copy's mtime_ns afterwards.
// A file whose local size and mtime still match is unchanged without reading it.
type BackupFile struct {
	Size          int64 `json:"size"`
	ModTime       int64 `json:"mtime_ns"`
	RemoteMtimeNS int64 `json:"remote_mtime_ns"`
	// Owned: this backup uploaded the Drive copy (rather than finding an
	// identical file already there). Only owned files are ever removed.
	Owned bool `json:"owned"`
}

// BackupState is a backup's memory between runs, keyed by path relative to the
// local folder. Missing records when a backed-up file was first seen gone
// locally (Unix seconds), so it can be removed from the Drive after a grace period.
type BackupState struct {
	Version int                   `json:"version"`
	Server  string                `json:"server"`
	Share   string                `json:"share"`
	Local   string                `json:"local"`
	Remote  string                `json:"remote"`
	Files   map[string]BackupFile `json:"files"`
	Missing map[string]int64      `json:"missing"`
}

const backupStateVersion = 2

// LoadBackupState reads the state file. A missing file, or one written for a
// different folder pair, server or share, starts fresh (the next run checks
// the Drive in full).
func LoadBackupState(file, server, share, local, remote string) (BackupState, error) {
	fresh := BackupState{
		Version: backupStateVersion, Server: server, Share: share, Local: local, Remote: remote,
		Files: map[string]BackupFile{}, Missing: map[string]int64{},
	}
	data, err := os.ReadFile(file)
	if errors.Is(err, fs.ErrNotExist) {
		return fresh, nil
	}
	if err != nil {
		return fresh, fmt.Errorf("read backup state: %w", err)
	}
	var st BackupState
	if err := json.Unmarshal(data, &st); err != nil || st.Version != backupStateVersion ||
		st.Server != server || st.Share != share || st.Local != local || st.Remote != remote {
		return fresh, nil
	}
	if st.Files == nil {
		st.Files = map[string]BackupFile{}
	}
	if st.Missing == nil {
		st.Missing = map[string]int64{}
	}
	return st, nil
}

// Save writes the state atomically (unique temp file + rename), readable only by the owner.
func (st BackupState) Save(file string) error {
	data, err := json.Marshal(st)
	if err != nil {
		return err
	}
	if err := os.MkdirAll(filepath.Dir(file), 0o700); err != nil {
		return fmt.Errorf("save backup state: %w", err)
	}
	tmp, err := os.CreateTemp(filepath.Dir(file), filepath.Base(file)+".*.tmp")
	if err != nil {
		return fmt.Errorf("save backup state: %w", err)
	}
	_, writeErr := tmp.Write(data)
	closeErr := tmp.Close()
	if err := errors.Join(writeErr, closeErr); err != nil {
		os.Remove(tmp.Name())
		return fmt.Errorf("save backup state: %w", err)
	}
	if err := os.Rename(tmp.Name(), file); err != nil {
		os.Remove(tmp.Name())
		return fmt.Errorf("save backup state: %w", err)
	}
	return nil
}

// ErrBackupRunning: another backup holds the state file's lock.
var ErrBackupRunning = errors.New("another backup with this state file is running")

// LockBackupState takes an exclusive lock for a whole run (load, upload, save),
// so two runs can't overwrite each other's state. Call the returned function to release it.
func LockBackupState(file string) (func(), error) {
	if err := os.MkdirAll(filepath.Dir(file), 0o700); err != nil {
		return nil, fmt.Errorf("lock backup state: %w", err)
	}
	f, err := os.OpenFile(file+".lock", os.O_CREATE|os.O_RDWR, 0o600)
	if err != nil {
		return nil, fmt.Errorf("lock backup state: %w", err)
	}
	if err := lockFile(f); err != nil {
		f.Close()
		return nil, err
	}
	return func() { unlockFile(f); f.Close() }, nil
}

// BackupScan is a backup's view of the local folder.
type BackupScan struct {
	Files []File
	// Unseen are relative paths (folders or files) the scan could not or was
	// told not to look into: unreadable, excluded, symlinks and junk. Files
	// under them are never treated as deleted.
	Unseen map[string]bool
}

// Covers reports whether rel is one of the unseen paths or inside one.
func (s BackupScan) Covers(rel string) bool {
	for p := rel; p != "." && p != "/" && p != ""; p = path.Dir(p) {
		if s.Unseen[p] {
			return true
		}
	}
	return false
}

// ScanBackup walks root for a backup. Unlike Walk it keeps going past folders
// and files it can't read (macOS privacy-protected folders), and leaves out
// excluded relative paths and everything under them.
func ScanBackup(root string, exclude []string) (BackupScan, error) {
	info, err := os.Stat(root)
	if err != nil {
		return BackupScan{}, err
	}
	if !info.IsDir() {
		return BackupScan{}, fmt.Errorf("%s is not a folder", root)
	}
	excluded := map[string]bool{}
	scan := BackupScan{Unseen: map[string]bool{}}
	for _, e := range exclude {
		if e = strings.Trim(path.Clean("/"+filepath.ToSlash(e)), "/"); e != "" {
			excluded[e] = true
			scan.Unseen[e] = true // even when it doesn't exist (any more)
		}
	}
	err = filepath.WalkDir(root, func(p string, d fs.DirEntry, err error) error {
		if p == root {
			return err // the root itself must be readable
		}
		rel, relErr := filepath.Rel(root, p)
		if relErr != nil {
			return relErr
		}
		rel = filepath.ToSlash(rel)
		if err != nil || excluded[rel] || Skip(d.Name()) || d.Type()&fs.ModeSymlink != 0 {
			scan.Unseen[rel] = true
			if d != nil && d.IsDir() {
				return filepath.SkipDir
			}
			return nil
		}
		if d.IsDir() || !d.Type().IsRegular() {
			return nil
		}
		fi, err := d.Info()
		if err != nil {
			scan.Unseen[rel] = true
			return nil
		}
		scan.Files = append(scan.Files, File{
			Local: p, Rel: rel, Size: fi.Size(), ModTime: fi.ModTime().UnixNano(),
		})
		return nil
	})
	return scan, err
}
