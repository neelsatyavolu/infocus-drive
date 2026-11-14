package app

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
	"time"

	"github.com/neelsatyavolu/infocus-drive/cli/internal/api"
	"github.com/neelsatyavolu/infocus-drive/cli/internal/config"
	"github.com/neelsatyavolu/infocus-drive/cli/internal/transfer"
)

type backupOut struct {
	Uploaded      int            `json:"uploaded"`
	Unchanged     int            `json:"unchanged"`
	Deleted       []string       `json:"deleted"`
	PendingDelete int            `json:"pending_delete"`
	Failed        []failedUpload `json:"failed"`
	Verified      bool           `json:"verified"`
}

// backup runs `infocus --json backup` at the given time and decodes the result.
func (h *harness) backup(t *testing.T, now time.Time, root, state string, extra ...string) backupOut {
	t.Helper()
	h.env.Now = func() time.Time { return now }
	args := append([]string{"--json", "backup", root, "Backups/Mac", "--state", state}, extra...)
	h.mustRun(t, args...)
	var out backupOut
	if err := json.Unmarshal(h.stdout.Bytes(), &out); err != nil {
		t.Fatalf("result %q: %v", h.stdout, err)
	}
	return out
}

func touch(t *testing.T, p, data string, mtime time.Time) {
	t.Helper()
	if err := os.WriteFile(p, []byte(data), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.Chtimes(p, mtime, mtime); err != nil {
		t.Fatal(err)
	}
}

func TestBackupSecondRunSkipsUnchangedFilesWithoutListingTheDrive(t *testing.T) {
	h := newHarness(t)
	root := localTree(t, map[string]string{"a.txt": "a", "Docs/b.txt": "bb", ".DS_Store": "junk"})
	state := filepath.Join(t.TempDir(), "state.json")
	now := time.Unix(1_800_000_000, 0)

	first := h.backup(t, now, root, state)
	if first.Uploaded != 2 || !first.Verified {
		t.Fatalf("first run %+v", first)
	}
	if h.data(t, "Backups/Mac/Docs/b.txt") != "bb" {
		t.Fatal("nested file not backed up")
	}
	if _, ok := h.drive.files["Backups/Mac/.DS_Store"]; ok {
		t.Fatal("junk was backed up")
	}

	h.drive.listCalls = 0
	second := h.backup(t, now.Add(time.Hour), root, state)
	if second.Uploaded != 0 || second.Unchanged != 2 || second.Verified || h.drive.listCalls != 0 {
		t.Fatalf("quiet run %+v, %d listings", second, h.drive.listCalls)
	}

	touch(t, filepath.Join(root, "Docs/b.txt"), "changed", now.Add(2*time.Hour))
	third := h.backup(t, now.Add(2*time.Hour), root, state)
	if third.Uploaded != 1 || third.Unchanged != 1 || h.drive.listCalls != 1 {
		t.Fatalf("changed run %+v, %d listings", third, h.drive.listCalls)
	}
	if h.data(t, "Backups/Mac/Docs/b.txt") != "changed" {
		t.Fatal("changed file not uploaded")
	}
}

func TestBackupFirstRunKeepsIdenticalDriveFiles(t *testing.T) {
	h := newHarness(t)
	h.drive.dir("Backups")
	h.drive.dir("Backups/Mac")
	h.drive.put("Backups/Mac/same.txt", "same")
	root := localTree(t, map[string]string{"same.txt": "same"})
	out := h.backup(t, time.Now(), root, filepath.Join(t.TempDir(), "s.json"))
	if out.Uploaded != 0 || out.Unchanged != 1 || h.drive.uploads != 0 {
		t.Fatalf("%+v, %d uploads", out, h.drive.uploads)
	}
}

func TestBackupRemovesFilesDeletedLocallyAfterTheGracePeriod(t *testing.T) {
	h := newHarness(t)
	h.drive.dir("#recycle")
	root := localTree(t, map[string]string{"keep.txt": "k", "gone.txt": "g", "edited.txt": "e"})
	state := filepath.Join(t.TempDir(), "state.json")
	now := time.Unix(1_800_000_000, 0)
	h.backup(t, now, root, state)

	os.Remove(filepath.Join(root, "gone.txt"))
	os.Remove(filepath.Join(root, "edited.txt"))
	out := h.backup(t, now.Add(time.Hour), root, state)
	if out.PendingDelete != 2 || len(out.Deleted) != 0 {
		t.Fatalf("%+v", out)
	}
	// Someone changes one of them on the Drive during the grace period.
	h.drive.put("Backups/Mac/edited.txt", "edited on the Drive")

	out = h.backup(t, now.Add(6*24*time.Hour), root, state)
	if out.PendingDelete != 2 || len(out.Deleted) != 0 {
		t.Fatalf("too early: %+v", out)
	}
	out = h.backup(t, now.Add(8*24*time.Hour), root, state)
	if strings.Join(out.Deleted, ",") != "Backups/Mac/gone.txt" || out.PendingDelete != 0 {
		t.Fatalf("after a week: %+v", out)
	}
	if _, ok := h.drive.files["Backups/Mac/gone.txt"]; ok {
		t.Fatal("deleted file still on the Drive")
	}
	if h.data(t, "Backups/Mac/edited.txt") != "edited on the Drive" || h.data(t, "Backups/Mac/keep.txt") != "k" {
		t.Fatal("removed a file it shouldn't have")
	}
}

func TestBackupForgetsAPendingDeletionWhenTheFileComesBack(t *testing.T) {
	h := newHarness(t)
	h.drive.dir("#recycle")
	root := localTree(t, map[string]string{"a.txt": "a", "b.txt": "b"})
	state := filepath.Join(t.TempDir(), "state.json")
	now := time.Unix(1_800_000_000, 0)
	h.backup(t, now, root, state)
	data, _ := os.ReadFile(filepath.Join(root, "b.txt"))
	os.Remove(filepath.Join(root, "b.txt"))
	h.backup(t, now.Add(time.Hour), root, state)
	os.WriteFile(filepath.Join(root, "b.txt"), data, 0o644)
	h.backup(t, now.Add(2*time.Hour), root, state)
	os.Remove(filepath.Join(root, "b.txt"))
	out := h.backup(t, now.Add(8*24*time.Hour), root, state)
	if len(out.Deleted) != 0 || out.PendingDelete != 1 {
		t.Fatalf("grace period should restart: %+v", out)
	}
}

func TestBackupNeverDeletesWhenTheFolderLooksEmpty(t *testing.T) {
	h := newHarness(t)
	h.drive.dir("#recycle")
	root := localTree(t, map[string]string{"a.txt": "a"})
	state := filepath.Join(t.TempDir(), "state.json")
	now := time.Unix(1_800_000_000, 0)
	h.backup(t, now, root, state)
	os.Remove(filepath.Join(root, "a.txt"))
	h.backup(t, now.Add(time.Hour), root, state)
	out := h.backup(t, now.Add(30*24*time.Hour), root, state)
	if len(out.Deleted) != 0 || h.data(t, "Backups/Mac/a.txt") != "a" {
		t.Fatalf("%+v", out)
	}
}

func TestBackupExcludesAndUnreadableFoldersAreLeftAlone(t *testing.T) {
	if os.Geteuid() == 0 {
		t.Skip("root can read anything")
	}
	h := newHarness(t)
	h.drive.dir("#recycle")
	root := localTree(t, map[string]string{"a.txt": "a", "Library/Caches/x": "x", "Private/p.txt": "p"})
	state := filepath.Join(t.TempDir(), "state.json")
	now := time.Unix(1_800_000_000, 0)
	h.backup(t, now, root, state, "--exclude", "Library")
	if _, ok := h.drive.files["Backups/Mac/Library/Caches/x"]; ok {
		t.Fatal("excluded folder was backed up")
	}
	private := filepath.Join(root, "Private")
	if err := os.Chmod(private, 0o000); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { os.Chmod(private, 0o755) })
	out := h.backup(t, now.Add(30*24*time.Hour), root, state, "--exclude", "Library")
	if len(out.Deleted) != 0 || h.data(t, "Backups/Mac/Private/p.txt") != "p" {
		t.Fatalf("unreadable folder treated as deleted: %+v", out)
	}
}

func TestBackupVerifyReuploadsFilesMissingFromTheDrive(t *testing.T) {
	h := newHarness(t)
	root := localTree(t, map[string]string{"a.txt": "a"})
	state := filepath.Join(t.TempDir(), "state.json")
	now := time.Unix(1_800_000_000, 0)
	h.backup(t, now, root, state)
	delete(h.drive.files, "Backups/Mac/a.txt")
	if out := h.backup(t, now, root, state); out.Uploaded != 0 {
		t.Fatalf("quick run trusts its state: %+v", out)
	}
	if out := h.backup(t, now, root, state, "--verify"); out.Uploaded != 1 || h.data(t, "Backups/Mac/a.txt") != "a" {
		t.Fatalf("verify: %+v", out)
	}
}

func TestBackupProgressEventsAreJSONLines(t *testing.T) {
	h := newHarness(t)
	root := localTree(t, map[string]string{"a.txt": "a"})
	h.backup(t, time.Now(), root, filepath.Join(t.TempDir(), "s.json"), "--progress")
	lines := strings.Split(strings.TrimSpace(h.stderr.String()), "\n")
	phases := []string{}
	for _, line := range lines {
		var ev map[string]any
		if err := json.Unmarshal([]byte(line), &ev); err != nil {
			t.Fatalf("not JSON: %q", line)
		}
		if ev["event"] == "phase" {
			phases = append(phases, ev["phase"].(string))
		}
	}
	if strings.Join(phases, ",") != "scanning,checking,uploading,deleting" {
		t.Fatalf("phases %v", phases)
	}
}

func TestBackupNeedsAStateFile(t *testing.T) {
	h := newHarness(t)
	if code := h.run("backup", t.TempDir(), "Backups"); code != ExitUsage {
		t.Fatalf("exit %d", code)
	}
}

func TestBackupHoldsDeletionsOnAShareWithoutARecycleBin(t *testing.T) {
	h := newHarness(t)
	root := localTree(t, map[string]string{"a.txt": "a", "b.txt": "b"})
	state := filepath.Join(t.TempDir(), "state.json")
	now := time.Unix(1_800_000_000, 0)
	h.backup(t, now, root, state)
	os.Remove(filepath.Join(root, "b.txt"))
	h.backup(t, now.Add(time.Hour), root, state)
	h.env.Now = func() time.Time { return now.Add(8 * 24 * time.Hour) }
	h.mustRun(t, "--json", "backup", root, "Backups/Mac", "--state", state)
	var held struct {
		NoRecycleBin  bool `json:"no_recycle_bin"`
		PendingDelete int  `json:"pending_delete"`
	}
	json.Unmarshal(h.stdout.Bytes(), &held)
	if !held.NoRecycleBin || held.PendingDelete != 1 || h.data(t, "Backups/Mac/b.txt") != "b" {
		t.Fatalf("deleted without a Recycle bin: %s", h.stdout)
	}
	h.drive.dir("#recycle") // added later: the held deletion goes ahead
	if out := h.backup(t, now.Add(9*24*time.Hour), root, state); len(out.Deleted) != 1 {
		t.Fatalf("%+v", out)
	}
}

func TestBackupNeverRemovesDriveFilesItDidNotUpload(t *testing.T) {
	h := newHarness(t)
	h.drive.dir("#recycle")
	h.drive.dir("Backups")
	h.drive.dir("Backups/Mac")
	h.drive.put("Backups/Mac/theirs.txt", "same")
	root := localTree(t, map[string]string{"theirs.txt": "same", "mine.txt": "m"})
	state := filepath.Join(t.TempDir(), "state.json")
	now := time.Unix(1_800_000_000, 0)
	h.backup(t, now, root, state)
	os.Remove(filepath.Join(root, "theirs.txt"))
	out := h.backup(t, now.Add(30*24*time.Hour), root, state)
	if len(out.Deleted) != 0 || h.data(t, "Backups/Mac/theirs.txt") != "same" {
		t.Fatalf("removed a file it only found: %+v", out)
	}
}

func TestBackupExcludingAFolderThatIsGoneKeepsItsDriveCopy(t *testing.T) {
	h := newHarness(t)
	h.drive.dir("#recycle")
	root := localTree(t, map[string]string{"keep.txt": "k", "Docs/a.txt": "a"})
	state := filepath.Join(t.TempDir(), "state.json")
	now := time.Unix(1_800_000_000, 0)
	h.backup(t, now, root, state)
	os.RemoveAll(filepath.Join(root, "Docs"))
	h.backup(t, now.Add(time.Hour), root, state, "--exclude", "Docs")
	out := h.backup(t, now.Add(30*24*time.Hour), root, state, "--exclude", "Docs")
	if len(out.Deleted) != 0 || h.data(t, "Backups/Mac/Docs/a.txt") != "a" {
		t.Fatalf("%+v", out)
	}
}

func TestBackupAFailedUploadKeepsTheOldRecord(t *testing.T) {
	h := newHarness(t)
	h.drive.dir("#recycle")
	root := localTree(t, map[string]string{"a.txt": "a", "keep.txt": "k"})
	state := filepath.Join(t.TempDir(), "state.json")
	now := time.Unix(1_800_000_000, 0)
	h.backup(t, now, root, state)
	touch(t, filepath.Join(root, "a.txt"), "changed", now.Add(time.Hour))
	h.drive.failUpload = true
	h.env.Now = func() time.Time { return now.Add(time.Hour) }
	if code := h.run("--json", "backup", root, "Backups/Mac", "--state", state); code == ExitOK {
		t.Fatal("upload failure should fail the run")
	}
	h.drive.failUpload = false
	// Deleted locally after the failed upload: it's still known, so it's removed a week later.
	os.Remove(filepath.Join(root, "a.txt"))
	h.backup(t, now.Add(2*time.Hour), root, state)
	if out := h.backup(t, now.Add(9*24*time.Hour), root, state); strings.Join(out.Deleted, ",") != "Backups/Mac/a.txt" {
		t.Fatalf("%+v", out)
	}
}

func TestBackupLeavesAFileChangedOnTheDriveRightBeforeDeleting(t *testing.T) {
	h := newHarness(t)
	h.drive.dir("#recycle")
	h.drive.dir("Backups")
	h.drive.dir("Backups/Mac")
	h.drive.put("Backups/Mac/a.txt", "edited") // mtime is no longer the one the backup sent
	deleted, failed, changed := deleteBackedUp(context.Background(), h.signedInClient(t),
		[]backupDelete{{rel: "a.txt", remote: "Backups/Mac/a.txt", mtimeNS: 1}})
	if len(deleted) != 0 || len(failed) != 0 || !changed["Backups/Mac/a.txt"] || h.data(t, "Backups/Mac/a.txt") != "edited" {
		t.Fatalf("deleted %v failed %v changed %v", deleted, failed, changed)
	}
}

func TestBackupRefusesTheRecycleBinAsDestination(t *testing.T) {
	h := newHarness(t)
	if code := h.run("backup", t.TempDir(), "#recycle/x", "--state", filepath.Join(t.TempDir(), "s")); code != ExitUsage {
		t.Fatalf("exit %d", code)
	}
}

// signedInClient is the API client a command would use.
func (h *harness) signedInClient(t *testing.T) *api.Client {
	t.Helper()
	cfg, err := config.Load(h.env.ConfigDir)
	if err != nil {
		t.Fatal(err)
	}
	r := &runner{env: h.env, cfg: cfg}
	client, err := r.signedIn()
	if err != nil {
		t.Fatal(err)
	}
	return client
}

func TestBackupReportsUnreadableFoldersAndKeepsGoing(t *testing.T) {
	if os.Geteuid() == 0 || runtime.GOOS == "windows" {
		t.Skip("needs chmod to make files unreadable (not root, not Windows)")
	}
	h := newHarness(t)
	root := localTree(t, map[string]string{"a.txt": "a", "Private/p.txt": "p", "Library/x": "x"})
	private := filepath.Join(root, "Private")
	os.Chmod(private, 0o000)
	t.Cleanup(func() { os.Chmod(private, 0o755) })
	h.env.Now = time.Now
	h.mustRun(t, "--json", "backup", root, "Backups/Mac", "--state", filepath.Join(t.TempDir(), "s"), "--exclude", "Library")
	var out struct {
		Uploaded    int      `json:"uploaded"`
		Unreadable  []string `json:"unreadable"`
		UnreadableN int      `json:"unreadable_count"`
	}
	json.Unmarshal(h.stdout.Bytes(), &out)
	if out.Uploaded != 1 || out.UnreadableN != 1 || strings.Join(out.Unreadable, ",") != "Private" {
		t.Fatalf("%+v", out) // Library is excluded on purpose, not unreadable
	}
}

func TestBackupAnUnreadableFileFailsAloneWhileOthersUpload(t *testing.T) {
	if os.Geteuid() == 0 || runtime.GOOS == "windows" {
		t.Skip("needs chmod to make files unreadable (not root, not Windows)")
	}
	h := newHarness(t)
	h.drive.dir("Backups")
	h.drive.dir("Backups/Mac")
	h.drive.put("Backups/Mac/locked.txt", "XXXX") // same size: needs a content check
	root := localTree(t, map[string]string{"locked.txt": "YYYY", "new.txt": "n"})
	locked := filepath.Join(root, "locked.txt")
	os.Chmod(locked, 0o000)
	t.Cleanup(func() { os.Chmod(locked, 0o644) })
	h.env.Now = time.Now
	if code := h.run("--json", "backup", root, "Backups/Mac", "--state", filepath.Join(t.TempDir(), "s")); code != ExitError {
		t.Fatalf("exit %d: %s", code, h.stderr)
	}
	if h.data(t, "Backups/Mac/new.txt") != "n" {
		t.Fatal("one unreadable file stopped the other uploads")
	}
}

func TestBackupOneRunAtATimePerStateFile(t *testing.T) {
	h := newHarness(t)
	state := filepath.Join(t.TempDir(), "s.json")
	unlock, err := transfer.LockBackupState(state)
	if err != nil {
		t.Fatal(err)
	}
	defer unlock()
	if code := h.run("backup", localTree(t, map[string]string{"a": "a"}), "Backups", "--state", state); code == ExitOK {
		t.Fatal("second run should refuse while the first holds the lock")
	}
	if !strings.Contains(h.stderr.String(), "another backup") {
		t.Fatalf("stderr %s", h.stderr)
	}
}
