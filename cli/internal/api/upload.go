package api

import (
	"context"
	"errors"
	"fmt"
	"io"
	"mime/multipart"
	"net/http"
	"net/url"
	"os"
	"strconv"
	"sync"
)

const (
	// ChunkThreshold matches the web app: larger files use chunked upload so no
	// single request exceeds the tunnel's body limit.
	ChunkThreshold  = 8 << 20
	chunkSize       = 32 << 20
	chunkStreams    = 4
	chunkMaxRetries = 3
)

// MustNotExist asks the server to refuse the upload if the target exists.
const MustNotExist int64 = -1

// UploadOptions controls overwrite behavior. ExpectMtimeNS nil = overwrite freely;
// MustNotExist = only create; otherwise the target's mtime_ns must still match.
type UploadOptions struct {
	ExpectMtimeNS *int64
}

func (o UploadOptions) apply(form url.Values) {
	if o.ExpectMtimeNS != nil {
		form.Set("expect_mtime_ns", strconv.FormatInt(*o.ExpectMtimeNS, 10))
	}
}

// UploadFile uploads a local file to dir/name, choosing simple or chunked upload.
func (c *Client) UploadFile(ctx context.Context, dir, name string, file *os.File, opts UploadOptions) (Entry, error) {
	info, err := file.Stat()
	if err != nil {
		return Entry{}, err
	}
	if info.Size() >= ChunkThreshold {
		return c.uploadChunked(ctx, dir, name, file, info.Size(), opts)
	}
	return c.uploadSimple(ctx, dir, name, file, info.Size(), opts)
}

func (c *Client) uploadSimple(ctx context.Context, dir, name string, body io.Reader, size int64, opts UploadOptions) (Entry, error) {
	pr, pw := io.Pipe()
	writer := multipart.NewWriter(pw)
	go func() {
		form := url.Values{"path": {CleanPath(dir)}}
		opts.apply(form)
		for key, values := range form {
			for _, v := range values {
				if err := writer.WriteField(key, v); err != nil {
					pw.CloseWithError(err)
					return
				}
			}
		}
		part, err := writer.CreateFormFile("file", name)
		if err == nil {
			_, err = io.Copy(part, body)
		}
		if err == nil {
			err = writer.Close()
		}
		pw.CloseWithError(err)
	}()
	req, err := c.newRequest(ctx, http.MethodPost, "/api/upload", nil, pr)
	if err != nil {
		pr.Close()
		return Entry{}, err
	}
	req.Header.Set("Content-Type", writer.FormDataContentType())
	var entry Entry
	err = c.doJSON(req, &entry)
	pr.Close()
	return entry, err
}

type chunkSession struct {
	UploadID    string `json:"upload_id"`
	ChunkSize   int64  `json:"chunk_size"`
	TotalChunks int    `json:"total_chunks"`
}

func (c *Client) uploadChunked(ctx context.Context, dir, name string, file io.ReaderAt, size int64, opts UploadOptions) (Entry, error) {
	var session chunkSession
	err := c.postForm(ctx, "/api/upload/init", url.Values{
		"path": {CleanPath(dir)}, "name": {name},
		"size": {strconv.FormatInt(size, 10)}, "chunk_size": {strconv.Itoa(chunkSize)},
	}, &session)
	if err != nil {
		return Entry{}, err
	}
	if err := c.sendChunks(ctx, session, file, size); err != nil {
		c.abortUpload(session.UploadID)
		return Entry{}, err
	}
	form := url.Values{"upload_id": {session.UploadID}}
	opts.apply(form)
	var entry Entry
	if err := c.postForm(ctx, "/api/upload/complete", form, &entry); err != nil {
		c.abortUpload(session.UploadID)
		return Entry{}, err
	}
	return entry, nil
}

func (c *Client) sendChunks(ctx context.Context, session chunkSession, file io.ReaderAt, size int64) error {
	ctx, cancel := context.WithCancel(ctx)
	defer cancel()
	indices := make(chan int)
	errs := make(chan error, chunkStreams)
	var wg sync.WaitGroup
	for w := 0; w < chunkStreams; w++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for index := range indices {
				if err := c.sendChunkWithRetry(ctx, session, file, size, index); err != nil {
					errs <- err
					cancel()
					return
				}
			}
		}()
	}
feed:
	for index := 0; index < session.TotalChunks; index++ {
		select {
		case indices <- index:
		case <-ctx.Done():
			break feed
		}
	}
	close(indices)
	wg.Wait()
	close(errs)
	if err := <-errs; err != nil {
		return err
	}
	return ctx.Err()
}

func (c *Client) sendChunkWithRetry(ctx context.Context, session chunkSession, file io.ReaderAt, size int64, index int) error {
	offset := int64(index) * session.ChunkSize
	length := min(session.ChunkSize, size-offset)
	var err error
	for attempt := 0; attempt < chunkMaxRetries; attempt++ {
		err = c.sendChunk(ctx, session.UploadID, index, io.NewSectionReader(file, offset, length), length)
		var apiErr *Error
		if err == nil || ctx.Err() != nil || (errors.As(err, &apiErr) && apiErr.Status < 500) {
			return err
		}
	}
	return fmt.Errorf("upload piece %d failed after %d tries: %w", index, chunkMaxRetries, err)
}

func (c *Client) sendChunk(ctx context.Context, uploadID string, index int, body io.Reader, length int64) error {
	q := url.Values{"upload_id": {uploadID}, "index": {strconv.Itoa(index)}}
	req, err := c.newRequest(ctx, http.MethodPut, "/api/upload/chunk", q, body)
	if err != nil {
		return err
	}
	req.ContentLength = length
	req.Header.Set("Content-Type", "application/octet-stream")
	return c.doJSON(req, nil)
}

func (c *Client) abortUpload(uploadID string) {
	// Best effort: the server also expires abandoned sessions on its own.
	_ = c.postForm(context.Background(), "/api/upload/abort", url.Values{"upload_id": {uploadID}}, nil)
}
