//go:build windows

package transfer

import "os"

// Backups are a Mac app feature; on Windows runs aren't locked against each other.
func lockFile(*os.File) error { return nil }

func unlockFile(*os.File) {}
