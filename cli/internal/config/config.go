// Package config stores the CLI's non-secret settings (server URL, default
// share) in ~/.config/infocus/config.json. Tokens live in the Keychain.
package config

import (
	"encoding/json"
	"errors"
	"fmt"
	"net/url"
	"os"
	"path/filepath"
	"strings"
)

// Config is the on-disk settings file.
type Config struct {
	Server string `json:"server"`
	Share  string `json:"share,omitempty"`
}

// Dir returns the settings directory (INFOCUS_CONFIG_DIR overrides it).
func Dir() (string, error) {
	if dir := os.Getenv("INFOCUS_CONFIG_DIR"); dir != "" {
		return dir, nil
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return "", fmt.Errorf("find home directory: %w", err)
	}
	return filepath.Join(home, ".config", "infocus"), nil
}

// Load reads config.json from dir; a missing file is an empty Config.
func Load(dir string) (Config, error) {
	var cfg Config
	raw, err := os.ReadFile(filepath.Join(dir, "config.json"))
	if errors.Is(err, os.ErrNotExist) {
		return cfg, nil
	}
	if err != nil {
		return cfg, fmt.Errorf("read settings: %w", err)
	}
	if err := json.Unmarshal(raw, &cfg); err != nil {
		return cfg, fmt.Errorf("settings file %s is not valid JSON: %w", filepath.Join(dir, "config.json"), err)
	}
	return cfg, nil
}

// Save writes config.json atomically with owner-only permissions.
func Save(dir string, cfg Config) error {
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return fmt.Errorf("create settings folder: %w", err)
	}
	raw, err := json.MarshalIndent(cfg, "", "  ")
	if err != nil {
		return err
	}
	tmp, err := os.CreateTemp(dir, ".config-*.json")
	if err != nil {
		return fmt.Errorf("write settings: %w", err)
	}
	defer os.Remove(tmp.Name())
	if _, err := tmp.Write(append(raw, '\n')); err != nil {
		tmp.Close()
		return fmt.Errorf("write settings: %w", err)
	}
	if err := tmp.Close(); err != nil {
		return fmt.Errorf("write settings: %w", err)
	}
	if err := os.Chmod(tmp.Name(), 0o600); err != nil {
		return fmt.Errorf("write settings: %w", err)
	}
	return os.Rename(tmp.Name(), filepath.Join(dir, "config.json"))
}

// ParseServer validates a Drive base URL: https, or http only for localhost.
func ParseServer(raw string) (*url.URL, error) {
	raw = strings.TrimRight(strings.TrimSpace(raw), "/")
	if raw == "" {
		return nil, errors.New("no Drive server configured; pass --server https://drive.example.com")
	}
	u, err := url.Parse(raw)
	if err != nil || u.Host == "" || u.Path != "" || u.RawQuery != "" || u.User != nil {
		return nil, fmt.Errorf("invalid server URL %q (expected e.g. https://drive.example.com)", raw)
	}
	local := u.Hostname() == "localhost" || u.Hostname() == "127.0.0.1"
	if u.Scheme != "https" && !(u.Scheme == "http" && local) {
		return nil, fmt.Errorf("server URL must use https: %q", raw)
	}
	return u, nil
}
