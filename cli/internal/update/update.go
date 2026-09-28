// Package update keeps the infocus binary current from this repo's GitHub
// releases (tags cli-vX.Y.Z), verifying each download against SHA256SUMS.
package update

import (
	"archive/tar"
	"bufio"
	"bytes"
	"compress/gzip"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"time"
)

const (
	// DefaultRepo is where releases are published.
	DefaultRepo = "https://github.com/neelsatyavolu/infocus-drive"
	// Asset is the release archive holding the universal macOS binary.
	Asset = "infocus-darwin-universal.tar.gz"

	maxBinary     = 200 << 20
	checkInterval = time.Hour
	stateFile     = "update-check.json"
)

var tagPattern = regexp.MustCompile(`/releases/tag/cli-v(\d+\.\d+\.\d+)$`)

// Updater talks to the release host.
type Updater struct {
	Repo string // e.g. DefaultRepo; a fake server in tests
	HTTP *http.Client
}

func (u Updater) client() *http.Client {
	if u.HTTP != nil {
		return u.HTTP
	}
	return http.DefaultClient
}

// Latest returns the newest CLI version ("0.2.0"), or "" if the repo's latest
// release isn't a CLI release. It reads the web redirect, not the REST API,
// so a campus behind one IP doesn't hit the API's hourly limit.
func (u Updater) Latest(ctx context.Context) (string, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodHead, u.Repo+"/releases/latest", nil)
	if err != nil {
		return "", err
	}
	client := *u.client()
	client.CheckRedirect = func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }
	res, err := client.Do(req)
	if err != nil {
		return "", fmt.Errorf("check for updates: %w", err)
	}
	res.Body.Close()
	if res.StatusCode < 300 || res.StatusCode >= 400 {
		return "", fmt.Errorf("check for updates: unexpected HTTP %d", res.StatusCode)
	}
	match := tagPattern.FindStringSubmatch(res.Header.Get("Location"))
	if match == nil {
		return "", nil
	}
	return match[1], nil
}

func parse(v string) ([3]int, bool) {
	var out [3]int
	parts := strings.Split(v, ".")
	if len(parts) != 3 {
		return out, false
	}
	for i, p := range parts {
		n, err := strconv.Atoi(p)
		if err != nil || n < 0 {
			return out, false
		}
		out[i] = n
	}
	return out, true
}

// Valid reports whether v is a release version (development builds aren't).
func Valid(v string) bool {
	_, ok := parse(v)
	return ok
}

// Newer reports whether latest is a higher version than current. Unparsable
// versions (including "dev" builds) never update.
func Newer(latest, current string) bool {
	l, ok1 := parse(latest)
	c, ok2 := parse(current)
	if !ok1 || !ok2 {
		return false
	}
	for i := range l {
		if l[i] != c[i] {
			return l[i] > c[i]
		}
	}
	return false
}

func (u Updater) get(ctx context.Context, url string, limit int64) ([]byte, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	if err != nil {
		return nil, err
	}
	res, err := u.client().Do(req)
	if err != nil {
		return nil, err
	}
	defer res.Body.Close()
	if res.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("download %s: HTTP %d", url, res.StatusCode)
	}
	data, err := io.ReadAll(io.LimitReader(res.Body, limit+1))
	if err != nil {
		return nil, err
	}
	if int64(len(data)) > limit {
		return nil, fmt.Errorf("download %s: larger than expected", url)
	}
	return data, nil
}

func expectedSum(sums []byte) (string, error) {
	scanner := bufio.NewScanner(bytes.NewReader(sums))
	for scanner.Scan() {
		fields := strings.Fields(scanner.Text())
		if len(fields) == 2 && strings.TrimPrefix(fields[1], "*") == Asset {
			return strings.ToLower(fields[0]), nil
		}
	}
	return "", errors.New("SHA256SUMS has no entry for " + Asset)
}

func extractBinary(archive []byte) ([]byte, error) {
	gz, err := gzip.NewReader(bytes.NewReader(archive))
	if err != nil {
		return nil, err
	}
	tr := tar.NewReader(gz)
	for {
		h, err := tr.Next()
		if errors.Is(err, io.EOF) {
			return nil, errors.New("release archive has no infocus binary")
		}
		if err != nil {
			return nil, err
		}
		if h.Typeflag == tar.TypeReg && h.Name == "infocus" {
			return io.ReadAll(io.LimitReader(tr, maxBinary))
		}
	}
}

// Install downloads version, verifies it, and atomically replaces exe.
// On any error exe is left untouched.
func (u Updater) Install(ctx context.Context, version, exe string) error {
	base := fmt.Sprintf("%s/releases/download/cli-v%s/", u.Repo, version)
	archive, err := u.get(ctx, base+Asset, maxBinary)
	if err != nil {
		return err
	}
	sums, err := u.get(ctx, base+"SHA256SUMS", 64<<10)
	if err != nil {
		return err
	}
	want, err := expectedSum(sums)
	if err != nil {
		return err
	}
	got := sha256.Sum256(archive)
	if hex.EncodeToString(got[:]) != want {
		return errors.New("update checksum mismatch — not installing")
	}
	binary, err := extractBinary(archive)
	if err != nil {
		return err
	}
	// Same folder as exe so the final rename is atomic.
	tmp, err := os.CreateTemp(filepath.Dir(exe), ".infocus-update-*")
	if err != nil {
		return fmt.Errorf("can't write next to %s: %w", exe, err)
	}
	defer os.Remove(tmp.Name())
	if _, err := tmp.Write(binary); err != nil {
		tmp.Close()
		return err
	}
	if err := tmp.Close(); err != nil {
		return err
	}
	if err := os.Chmod(tmp.Name(), 0o755); err != nil {
		return err
	}
	return os.Rename(tmp.Name(), exe)
}

type checkState struct {
	CheckedAt time.Time `json:"checked_at"`
	Latest    string    `json:"latest"`
}

// Due reports whether a day has passed since the last automatic check.
func Due(configDir string, now time.Time) bool {
	raw, err := os.ReadFile(filepath.Join(configDir, stateFile))
	if err != nil {
		return true
	}
	var st checkState
	if json.Unmarshal(raw, &st) != nil {
		return true
	}
	return now.Sub(st.CheckedAt) >= checkInterval
}

// MarkChecked records an automatic check (successful or not).
func MarkChecked(configDir string, now time.Time, latest string) {
	raw, _ := json.Marshal(checkState{CheckedAt: now, Latest: latest})
	if os.MkdirAll(configDir, 0o700) == nil {
		os.WriteFile(filepath.Join(configDir, stateFile), raw, 0o600)
	}
}

// Executable is the running binary's real path (symlinks resolved).
func Executable() (string, error) {
	exe, err := os.Executable()
	if err != nil {
		return "", err
	}
	return filepath.EvalSymlinks(exe)
}
