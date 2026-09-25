package app

import (
	"bytes"
	"context"
	"crypto/sha256"
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"

	"github.com/neelsatyavolu/infocus-drive/cli/internal/api"
)

func cmdCat(ctx context.Context, r *runner, args []string) error {
	if len(args) != 1 {
		return usagef("usage: infocus cat PATH")
	}
	client, err := r.signedIn()
	if err != nil {
		return err
	}
	body, err := client.Download(ctx, args[0])
	if err != nil {
		return err
	}
	defer body.Close()
	_, err = io.Copy(r.env.Stdout, body)
	return err
}

func cmdGet(ctx context.Context, r *runner, args []string) error {
	fs := flag.NewFlagSet("get", flag.ContinueOnError)
	force := fs.Bool("force", false, "overwrite an existing local file")
	rest, err := parseFlags(fs, args)
	if err != nil {
		return err
	}
	if len(rest) < 1 || len(rest) > 2 {
		return usagef("usage: infocus get PATH [LOCAL|-] [--force]")
	}
	client, err := r.signedIn()
	if err != nil {
		return err
	}
	remote := api.CleanPath(rest[0])
	entry, found, err := client.Stat(ctx, remote)
	if err != nil {
		return err
	}
	if !found {
		return exitError{ExitNotFound, fmt.Sprintf("%s not found", remote)}
	}
	// Never trust a server-provided name as a local path.
	name := filepath.Base(entry.Name)
	if name == "" || name == "." || name == ".." || name == "-" || name == string(filepath.Separator) {
		name = "download"
	}
	if entry.IsDir {
		name += ".zip"
	}
	local := name
	if len(rest) == 2 {
		local = rest[1]
		if info, err := os.Stat(local); err == nil && info.IsDir() {
			local = filepath.Join(local, name)
		}
	}
	var body io.ReadCloser
	if entry.IsDir {
		body, err = client.DownloadZip(ctx, remote)
	} else {
		body, err = client.Download(ctx, remote)
	}
	if err != nil {
		return err
	}
	defer body.Close()
	if local == "-" {
		_, err = io.Copy(r.env.Stdout, body)
		return err
	}
	written, err := writeLocal(local, body, *force)
	if err != nil {
		return err
	}
	return r.emit(map[string]any{"path": remote, "local": local, "bytes": written}, func(w io.Writer) {
		fmt.Fprintf(w, "Saved %s (%s)\n", local, formatSize(written))
	})
}

// writeLocal streams body to a temp file then renames it into place.
func writeLocal(local string, body io.Reader, force bool) (int64, error) {
	if _, err := os.Lstat(local); err == nil && !force {
		return 0, exitError{ExitConflict, fmt.Sprintf("%s already exists (use --force to overwrite)", local)}
	}
	tmp, err := os.CreateTemp(filepath.Dir(local), ".infocus-*.partial")
	if err != nil {
		return 0, err
	}
	defer os.Remove(tmp.Name())
	written, err := io.Copy(tmp, body)
	if closeErr := tmp.Close(); err == nil {
		err = closeErr
	}
	if err != nil {
		return 0, fmt.Errorf("download: %w", err)
	}
	if force {
		return written, os.Rename(tmp.Name(), local)
	}
	// No-clobber: link() fails atomically if something created local meanwhile.
	if err := os.Link(tmp.Name(), local); err != nil {
		if errors.Is(err, os.ErrExist) {
			return 0, exitError{ExitConflict, fmt.Sprintf("%s appeared while downloading; not overwritten (use --force)", local)}
		}
		return 0, fmt.Errorf("save %s: %w", local, err)
	}
	return written, nil
}

// stageStdin copies stdin to a temp file so uploads know their size.
func stageStdin(stdin io.Reader) (*os.File, error) {
	tmp, err := os.CreateTemp("", "infocus-stdin-*")
	if err != nil {
		return nil, err
	}
	os.Remove(tmp.Name()) // unlinked: disappears when closed
	if _, err := io.Copy(tmp, stdin); err != nil {
		tmp.Close()
		return nil, fmt.Errorf("read stdin: %w", err)
	}
	if _, err := tmp.Seek(0, io.SeekStart); err != nil {
		tmp.Close()
		return nil, err
	}
	return tmp, nil
}

func cmdPut(ctx context.Context, r *runner, args []string) error {
	fs := flag.NewFlagSet("put", flag.ContinueOnError)
	force := fs.Bool("force", false, "overwrite if the file exists")
	expect := fs.Int64("expect-mtime-ns", 0, "only overwrite if the Drive copy still has this mtime_ns")
	rest, err := parseFlags(fs, args)
	if err != nil {
		return err
	}
	if len(rest) != 2 {
		return usagef("usage: infocus put LOCAL|- REMOTE [--force | --expect-mtime-ns N]")
	}
	if *force && *expect != 0 {
		return usagef("use either --force or --expect-mtime-ns, not both")
	}
	source, remote := rest[0], rest[1]
	client, err := r.signedIn()
	if err != nil {
		return err
	}

	var file *os.File
	if source == "-" {
		file, err = stageStdin(r.env.Stdin)
	} else {
		file, err = os.Open(source)
	}
	if err != nil {
		return err
	}
	defer file.Close()
	if info, err := file.Stat(); err == nil && info.IsDir() {
		return usagef("%s is a folder; put uploads single files", source)
	}

	dir, name := api.SplitPath(remote)
	if strings.HasSuffix(remote, "/") || api.CleanPath(remote) == "" {
		dir, name = api.CleanPath(remote), filepath.Base(source)
	} else if entry, found, err := client.Stat(ctx, remote); err != nil {
		return err
	} else if found && entry.IsDir {
		dir, name = entry.Path, filepath.Base(source)
	} else if found && !*force && *expect == 0 {
		// Fail before sending any bytes; the server re-checks atomically anyway.
		return &api.Error{Status: 409, Detail: api.CleanPath(remote) + " already exists (use --force to overwrite)"}
	}
	if source == "-" && name == "-" {
		return usagef("give a file name when uploading from stdin")
	}

	opts := api.UploadOptions{}
	switch {
	case *expect != 0:
		opts.ExpectMtimeNS = expect
	case !*force:
		mustNotExist := api.MustNotExist
		opts.ExpectMtimeNS = &mustNotExist
	}
	entry, err := client.UploadFile(ctx, dir, name, file, opts)
	var apiErr *api.Error
	if errors.As(err, &apiErr) && apiErr.Status == 409 && !*force && *expect == 0 {
		return &api.Error{Status: 409, Detail: apiErr.Detail + " (use --force to overwrite)"}
	}
	if err != nil {
		return err
	}
	return r.emit(entry, func(w io.Writer) {
		fmt.Fprintf(w, "Uploaded %s (%s)\n", entry.Path, formatSize(entry.Size))
	})
}

func cmdEdit(ctx context.Context, r *runner, args []string) error {
	if len(args) != 1 {
		return usagef("usage: infocus edit PATH")
	}
	if !r.env.StdinIsTTY {
		return usagef("edit needs an interactive terminal; use cat + put --expect-mtime-ns instead")
	}
	client, err := r.signedIn()
	if err != nil {
		return err
	}
	remote := api.CleanPath(args[0])
	entry, found, err := client.Stat(ctx, remote)
	if err != nil {
		return err
	}
	if !found || entry.IsDir {
		return exitError{ExitNotFound, fmt.Sprintf("%s is not a file on the Drive", remote)}
	}

	workDir, err := os.MkdirTemp("", "infocus-edit-*")
	if err != nil {
		return err
	}
	local := filepath.Join(workDir, entry.Name)
	body, err := client.Download(ctx, remote)
	if err != nil {
		os.RemoveAll(workDir)
		return err
	}
	_, err = writeLocal(local, body, false)
	body.Close()
	if err != nil {
		os.RemoveAll(workDir)
		return err
	}
	before, err := fileHash(local)
	if err != nil {
		os.RemoveAll(workDir)
		return err
	}
	if err := r.env.RunEditor(local); err != nil {
		return fmt.Errorf("editor failed (your copy is at %s): %w", local, err)
	}
	after, err := fileHash(local)
	if err != nil {
		return err
	}
	if bytes.Equal(before, after) {
		os.RemoveAll(workDir)
		return r.emit(map[string]any{"path": remote, "changed": false}, func(w io.Writer) {
			fmt.Fprintln(w, "No changes.")
		})
	}

	file, err := os.Open(local)
	if err != nil {
		return err
	}
	dir, name := api.SplitPath(remote)
	expect := entry.MtimeNS
	saved, err := client.UploadFile(ctx, dir, name, file, api.UploadOptions{ExpectMtimeNS: &expect})
	file.Close()
	var apiErr *api.Error
	if errors.As(err, &apiErr) && apiErr.Status == 409 {
		return &api.Error{Status: 409, Detail: fmt.Sprintf(
			"%s changed on the Drive while you were editing; nothing was overwritten. Your version is saved at %s",
			remote, local)}
	}
	if err != nil {
		return fmt.Errorf("%w (your version is saved at %s)", err, local)
	}
	os.RemoveAll(workDir)
	return r.emit(map[string]any{"path": saved.Path, "changed": true, "size": saved.Size}, func(w io.Writer) {
		fmt.Fprintf(w, "Saved %s\n", saved.Path)
	})
}

func fileHash(path string) ([]byte, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer f.Close()
	h := sha256.New()
	if _, err := io.Copy(h, f); err != nil {
		return nil, err
	}
	return h.Sum(nil), nil
}
