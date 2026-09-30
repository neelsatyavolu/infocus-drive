//go:build !windows

package update

import "os"

// replaceExe atomically swaps the new binary in (same folder, so rename).
func replaceExe(next, exe string) error {
	return os.Rename(next, exe)
}
