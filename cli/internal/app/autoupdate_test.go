package app

import (
	"archive/tar"
	"bytes"
	"compress/gzip"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/neelsatyavolu/infocus-drive/cli/internal/config"
	"github.com/neelsatyavolu/infocus-drive/cli/internal/update"
)

// withReleases points the harness at a fake release host offering cli-v0.2.0
// and a fake installed binary. It returns the binary path and a check counter.
func withReleases(t *testing.T, h *harness) (string, *int) {
	t.Helper()
	old := Version
	Version = "0.1.0"
	t.Cleanup(func() { Version = old })

	var buf bytes.Buffer
	gz := gzip.NewWriter(&buf)
	tw := tar.NewWriter(gz)
	tw.WriteHeader(&tar.Header{Name: "infocus", Mode: 0o755, Size: 3})
	tw.Write([]byte("NEW"))
	tw.Close()
	gz.Close()
	archive := buf.Bytes()
	sum := sha256.Sum256(archive)
	checks := 0
	mux := http.NewServeMux()
	mux.HandleFunc("/releases/latest", func(w http.ResponseWriter, r *http.Request) {
		checks++
		http.Redirect(w, r, "/releases/tag/cli-v0.2.0", http.StatusFound)
	})
	mux.HandleFunc("/releases/download/cli-v0.2.0/"+update.Asset, func(w http.ResponseWriter, r *http.Request) { w.Write(archive) })
	mux.HandleFunc("/releases/download/cli-v0.2.0/SHA256SUMS", func(w http.ResponseWriter, r *http.Request) {
		w.Write([]byte(hex.EncodeToString(sum[:]) + "  " + update.Asset + "\n"))
	})
	srv := httptest.NewServer(mux)
	t.Cleanup(srv.Close)

	exe := filepath.Join(t.TempDir(), "infocus")
	os.WriteFile(exe, []byte("OLD"), 0o755)
	h.env.UpdateRepo = srv.URL
	h.env.Executable = func() (string, error) { return exe, nil }
	h.env.StdinIsTTY, h.env.StderrIsTTY = true, true
	return exe, &checks
}

func binary(t *testing.T, exe string) string {
	data, err := os.ReadFile(exe)
	if err != nil {
		t.Fatal(err)
	}
	return string(data)
}

func TestAutoUpdateAfterInteractiveCommandOncePerDay(t *testing.T) {
	h := newHarness(t)
	exe, checks := withReleases(t, h)
	h.mustRun(t, "ls")
	if binary(t, exe) != "NEW" || !strings.Contains(h.stderr.String(), "0.1.0 → 0.2.0") {
		t.Fatalf("binary %q, stderr %q", binary(t, exe), h.stderr)
	}
	h.mustRun(t, "ls")
	if *checks != 1 {
		t.Fatalf("checked %d times in one day", *checks)
	}
}

func TestAutoUpdateStaysOutOfTheWay(t *testing.T) {
	cases := map[string]func(h *harness){
		"json":    func(h *harness) {},
		"non-tty": func(h *harness) { h.env.StdinIsTTY = false },
		"env": func(h *harness) {
			h.env.Getenv = func(k string) string { return map[string]string{"INFOCUS_NO_UPDATE": "1"}[k] }
		},
		"config": func(h *harness) {
			off := false
			cfg, _ := config.Load(h.env.ConfigDir)
			cfg.AutoUpdate = &off
			config.Save(h.env.ConfigDir, cfg)
		},
		"dev-build": func(h *harness) { Version = "dev" },
	}
	for name, setup := range cases {
		t.Run(name, func(t *testing.T) {
			h := newHarness(t)
			exe, checks := withReleases(t, h)
			setup(h)
			args := []string{"ls"}
			if name == "json" {
				args = []string{"--json", "ls"}
			}
			h.mustRun(t, args...)
			if binary(t, exe) != "OLD" || *checks != 0 {
				t.Fatalf("updated anyway (checks=%d)", *checks)
			}
		})
	}
}

func TestUpdateCommandAndConfig(t *testing.T) {
	h := newHarness(t)
	exe, _ := withReleases(t, h)
	h.env.StdinIsTTY, h.env.StderrIsTTY = false, false // explicit update works for scripts too
	h.mustRun(t, "--json", "update")
	var out struct {
		From, To string
		Updated  bool
	}
	json.Unmarshal(h.stdout.Bytes(), &out)
	if !out.Updated || out.From != "0.1.0" || out.To != "0.2.0" || binary(t, exe) != "NEW" {
		t.Fatalf("got %+v, binary %q", out, binary(t, exe))
	}

	h.mustRun(t, "config", "auto-update", "off")
	cfg, _ := config.Load(h.env.ConfigDir)
	if cfg.AutoUpdate == nil || *cfg.AutoUpdate {
		t.Fatalf("auto_update not saved: %+v", cfg)
	}
	if code := h.run("config", "auto-update", "maybe"); code != ExitUsage {
		t.Fatalf("bad value: exit %d", code)
	}
}
