//go:build windows

package update

import (
	"fmt"
	"os"
)

// replaceExe swaps the new binary in. Windows can't overwrite a running .exe,
// but it can rename one: the old copy moves to infocus.exe.old (removed next
// time) and the new one takes its name. If that fails, the old one goes back.
func replaceExe(next, exe string) error {
	old := exe + ".old"
	os.Remove(old) // a previous update's leftover (fails harmlessly if in use)
	if err := os.Rename(exe, old); err != nil && !os.IsNotExist(err) {
		return fmt.Errorf("move the running infocus.exe aside: %w", err)
	}
	if err := os.Rename(next, exe); err != nil {
		os.Rename(old, exe) //nolint:errcheck // best effort: restore the old binary
		return err
	}
	os.Remove(old) // works when nothing runs it; otherwise next time
	return nil
}
