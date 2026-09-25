package config

import (
	"errors"
	"os"
	"path/filepath"
	"testing"
)

func TestSaveLoadRoundTripWithPrivatePermissions(t *testing.T) {
	dir := filepath.Join(t.TempDir(), "infocus")
	if err := Save(dir, Config{Server: "https://drive.example.com", Share: "Photos"}); err != nil {
		t.Fatal(err)
	}
	cfg, err := Load(dir)
	if err != nil || cfg.Server != "https://drive.example.com" || cfg.Share != "Photos" {
		t.Fatalf("got %+v, %v", cfg, err)
	}
	info, _ := os.Stat(filepath.Join(dir, "config.json"))
	if info.Mode().Perm() != 0o600 {
		t.Fatalf("mode %v", info.Mode().Perm())
	}
	if empty, err := Load(t.TempDir()); err != nil || empty.Server != "" {
		t.Fatalf("missing file: %+v, %v", empty, err)
	}
}

func TestParseServer(t *testing.T) {
	for _, ok := range []string{"https://drive.example.com", "https://drive.example.com/", "http://localhost:8787", "http://127.0.0.1:8787"} {
		if _, err := ParseServer(ok); err != nil {
			t.Errorf("%s: %v", ok, err)
		}
	}
	for _, bad := range []string{"", "drive.example.com", "http://drive.example.com", "https://drive.example.com/sub", "https://u:p@drive.example.com", "ftp://x"} {
		if _, err := ParseServer(bad); err == nil {
			t.Errorf("%q should be rejected", bad)
		}
	}
}

func TestKeychainRejectsMalformedValues(t *testing.T) {
	k := Keychain{}
	if err := k.Set("host; rm -rf", "ifd_ok"); err == nil {
		t.Error("bad host accepted")
	}
	if err := k.Set("drive.example.com", "ifd_ok\nadd-generic-password"); err == nil {
		t.Error("token with newline accepted")
	}
}

// Touches the real login keychain; run with INFOCUS_KEYCHAIN_TEST=1 on a Mac.
func TestKeychainRoundTrip(t *testing.T) {
	if os.Getenv("INFOCUS_KEYCHAIN_TEST") != "1" {
		t.Skip("set INFOCUS_KEYCHAIN_TEST=1 to use the real Keychain")
	}
	k, host := Keychain{}, "selftest.invalid"
	t.Cleanup(func() { k.Delete(host) })
	if err := k.Set(host, "ifd_selftest_ABC-123"); err != nil {
		t.Fatal(err)
	}
	if err := k.Set(host, "ifd_selftest_updated"); err != nil { // -U updates in place
		t.Fatal(err)
	}
	if got, err := k.Get(host); err != nil || got != "ifd_selftest_updated" {
		t.Fatalf("got %q, %v", got, err)
	}
	if err := k.Delete(host); err != nil {
		t.Fatal(err)
	}
	if _, err := k.Get(host); !errors.Is(err, ErrNoToken) {
		t.Fatalf("after delete: %v", err)
	}
}
