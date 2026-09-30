// Package updatetest builds fake release archives for tests.
package updatetest

import (
	"archive/tar"
	"archive/zip"
	"bytes"
	"compress/gzip"
	"strings"

	"github.com/neelsatyavolu/infocus-drive/cli/internal/update"
)

// Archive packs binary the way this platform's release asset is packed.
func Archive(binary []byte) []byte {
	var buf bytes.Buffer
	if strings.HasSuffix(update.Asset, ".zip") {
		zw := zip.NewWriter(&buf)
		w, _ := zw.Create(update.BinaryName)
		w.Write(binary)
		zw.Close()
		return buf.Bytes()
	}
	gz := gzip.NewWriter(&buf)
	tw := tar.NewWriter(gz)
	tw.WriteHeader(&tar.Header{Name: update.BinaryName, Mode: 0o755, Size: int64(len(binary))})
	tw.Write(binary)
	tw.Close()
	gz.Close()
	return buf.Bytes()
}
