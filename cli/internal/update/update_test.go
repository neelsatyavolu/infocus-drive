package update

import (
	"archive/tar"
	"archive/zip"
	"bytes"
	"compress/gzip"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// fakeReleases serves GitHub's /releases/latest redirect and release assets.
func fakeReleases(t *testing.T, latestTag string, binary []byte, corruptSum bool) (*httptest.Server, *int) {
	t.Helper()
	archive := packArchive(binary)
	sum := sha256.Sum256(archive)
	if corruptSum {
		sum[0] ^= 0xff
	}
	checks := 0
	mux := http.NewServeMux()
	mux.HandleFunc("/releases/latest", func(w http.ResponseWriter, r *http.Request) {
		checks++
		http.Redirect(w, r, "/releases/tag/"+latestTag, http.StatusFound)
	})
	mux.HandleFunc("/releases/download/"+latestTag+"/"+Asset, func(w http.ResponseWriter, r *http.Request) {
		w.Write(archive)
	})
	mux.HandleFunc("/releases/download/"+latestTag+"/SHA256SUMS", func(w http.ResponseWriter, r *http.Request) {
		w.Write([]byte(hex.EncodeToString(sum[:]) + "  " + Asset + "\n"))
	})
	srv := httptest.NewServer(mux)
	t.Cleanup(srv.Close)
	return srv, &checks
}

func TestNewer(t *testing.T) {
	cases := []struct {
		latest, current string
		want            bool
	}{
		{"0.2.0", "0.1.1", true}, {"0.1.10", "0.1.9", true}, {"1.0.0", "0.9.9", true},
		{"0.1.1", "0.1.1", false}, {"0.1.0", "0.1.1", false}, {"0.2.0", "dev", false}, {"garbage", "0.1.0", false},
	}
	for _, c := range cases {
		if got := Newer(c.latest, c.current); got != c.want {
			t.Errorf("Newer(%q, %q) = %v", c.latest, c.current, got)
		}
	}
}

func TestLatestFollowsOnlyCLITags(t *testing.T) {
	srv, _ := fakeReleases(t, "cli-v0.2.0", nil, false)
	u := Updater{Repo: srv.URL, HTTP: srv.Client()}
	if v, err := u.Latest(context.Background()); err != nil || v != "0.2.0" {
		t.Fatalf("got %q, %v", v, err)
	}
	other, _ := fakeReleases(t, "v9.9.9", nil, false) // a non-CLI release marked latest
	u.Repo = other.URL
	if v, err := u.Latest(context.Background()); err != nil || v != "" {
		t.Fatalf("non-CLI latest: got %q, %v", v, err)
	}
}

func TestInstallReplacesBinaryAtomically(t *testing.T) {
	srv, _ := fakeReleases(t, "cli-v0.2.0", []byte("NEW BINARY"), false)
	exe := filepath.Join(t.TempDir(), "infocus")
	os.WriteFile(exe, []byte("OLD BINARY"), 0o755)
	u := Updater{Repo: srv.URL, HTTP: srv.Client()}
	if err := u.Install(context.Background(), "0.2.0", exe); err != nil {
		t.Fatal(err)
	}
	data, _ := os.ReadFile(exe)
	info, _ := os.Stat(exe)
	if string(data) != "NEW BINARY" || info.Mode().Perm() != 0o755 {
		t.Fatalf("got %q mode %v", data, info.Mode().Perm())
	}
	if leftovers, _ := filepath.Glob(filepath.Join(filepath.Dir(exe), ".infocus-update-*")); len(leftovers) > 0 {
		t.Fatalf("temp files left: %v", leftovers)
	}
}

func TestInstallRefusesBadChecksum(t *testing.T) {
	srv, _ := fakeReleases(t, "cli-v0.2.0", []byte("EVIL"), true)
	exe := filepath.Join(t.TempDir(), "infocus")
	os.WriteFile(exe, []byte("OLD BINARY"), 0o755)
	u := Updater{Repo: srv.URL, HTTP: srv.Client()}
	err := u.Install(context.Background(), "0.2.0", exe)
	if err == nil || !strings.Contains(err.Error(), "checksum") {
		t.Fatalf("want checksum error, got %v", err)
	}
	if data, _ := os.ReadFile(exe); string(data) != "OLD BINARY" {
		t.Fatalf("binary changed: %q", data)
	}
}

func TestCheckStateIsDaily(t *testing.T) {
	dir := t.TempDir()
	now := time.Date(2026, 9, 26, 12, 0, 0, 0, time.UTC)
	if !Due(dir, now) {
		t.Fatal("first check should be due")
	}
	MarkChecked(dir, now, "0.2.0")
	if Due(dir, now.Add(59*time.Minute)) {
		t.Fatal("checked again within a day")
	}
	if !Due(dir, now.Add(61*time.Minute)) { // hourly
		t.Fatal("not due after a day")
	}
}

// packArchive packs binary like this platform's release asset (zip on
// Windows, tar.gz elsewhere).
func packArchive(binary []byte) []byte {
	var buf bytes.Buffer
	if strings.HasSuffix(Asset, ".zip") {
		zw := zip.NewWriter(&buf)
		w, _ := zw.Create(BinaryName)
		w.Write(binary)
		zw.Close()
		return buf.Bytes()
	}
	gz := gzip.NewWriter(&buf)
	tw := tar.NewWriter(gz)
	tw.WriteHeader(&tar.Header{Name: BinaryName, Mode: 0o755, Size: int64(len(binary))})
	tw.Write(binary)
	tw.Close()
	gz.Close()
	return buf.Bytes()
}

func TestAssetPerPlatform(t *testing.T) {
	if got := assetFor("windows", "arm64"); got != "infocus-windows-arm64.zip" {
		t.Fatalf("windows asset = %q", got)
	}
	if got := assetFor("darwin", "arm64"); got != "infocus-darwin-universal.tar.gz" {
		t.Fatalf("mac asset = %q", got)
	}
	if binaryFor("windows") != "infocus.exe" || binaryFor("darwin") != "infocus" {
		t.Fatal("binary names")
	}
}
