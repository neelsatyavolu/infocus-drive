// Package api is a small client for the InFocus Drive HTTP API.
package api

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"path"
	"strings"
)

// Error is a non-2xx response from the Drive.
type Error struct {
	Status int
	Detail string
}

func (e *Error) Error() string {
	if e.Detail != "" {
		return e.Detail
	}
	return fmt.Sprintf("the Drive returned HTTP %d", e.Status)
}

// Client talks to one Drive server as one signed-in user.
type Client struct {
	Base      *url.URL
	Token     string
	Share     string
	HTTP      *http.Client
	UserAgent string
}

// Entry is one file or folder, as returned by /api/files and friends.
type Entry struct {
	Name    string `json:"name"`
	Path    string `json:"path"`
	IsDir   bool   `json:"is_dir"`
	Size    int64  `json:"size"`
	Mtime   string `json:"mtime"`
	MtimeNS int64  `json:"mtime_ns"`
}

// Listing is a folder listing.
type Listing struct {
	Path  string  `json:"path"`
	Share string  `json:"share"`
	Items []Entry `json:"items"`
}

// Share is one share the account can open. ID is what X-Drive-Share takes
// (personal folders look like "~username"); Name is for display.
type Share struct {
	ID       string `json:"id"`
	Name     string `json:"name"`
	Kind     string `json:"kind"`
	CanWrite bool   `json:"can_write"`
}

// Me is the signed-in account (/api/me).
type Me struct {
	Authenticated bool    `json:"authenticated"`
	Email         string  `json:"email"`
	Username      string  `json:"nas_username"`
	IsAdmin       bool    `json:"is_admin"`
	Share         string  `json:"share"`
	Shares        []Share `json:"shares"`
}

// FindShare matches a share by id, then by display name.
func (m Me) FindShare(idOrName string) (Share, bool) {
	for _, s := range m.Shares {
		if s.ID == idOrName {
			return s, true
		}
	}
	for _, s := range m.Shares {
		if s.Name == idOrName {
			return s, true
		}
	}
	return Share{}, false
}

// SearchResult is /api/search output.
type SearchResult struct {
	Query     string  `json:"query"`
	Results   []Entry `json:"results"`
	Truncated bool    `json:"truncated"`
	HasMore   bool    `json:"has_more"`
}

// DeleteResult says whether an item went to the recycle bin or was removed.
type DeleteResult struct {
	Action string `json:"action"`
	Path   string `json:"path"`
}

// CleanPath turns user input like "/Shows//Ep1/" into "Shows/Ep1".
func CleanPath(p string) string {
	p = strings.ReplaceAll(strings.TrimSpace(p), "\\", "/")
	cleaned := path.Clean("/" + p)
	return strings.TrimPrefix(cleaned, "/")
}

// SplitPath returns the parent folder and final name of a remote path.
func SplitPath(p string) (dir, name string) {
	p = CleanPath(p)
	dir, name = path.Split(p)
	return strings.TrimSuffix(dir, "/"), name
}

func (c *Client) httpClient() *http.Client {
	if c.HTTP != nil {
		return c.HTTP
	}
	return http.DefaultClient
}

func (c *Client) newRequest(ctx context.Context, method, endpoint string, query url.Values, body io.Reader) (*http.Request, error) {
	u := *c.Base
	u.Path = endpoint
	if query != nil {
		u.RawQuery = query.Encode()
	}
	req, err := http.NewRequestWithContext(ctx, method, u.String(), body)
	if err != nil {
		return nil, err
	}
	if c.Token != "" {
		req.Header.Set("Authorization", "Bearer "+c.Token)
	}
	if c.Share != "" {
		req.Header.Set("X-Drive-Share", c.Share)
	}
	if c.UserAgent != "" {
		req.Header.Set("User-Agent", c.UserAgent)
	}
	return req, nil
}

// do sends req and turns non-2xx responses into *Error.
func (c *Client) do(req *http.Request) (*http.Response, error) {
	res, err := c.httpClient().Do(req)
	if err != nil {
		return nil, fmt.Errorf("can't reach %s: %w", c.Base.Host, err)
	}
	if res.StatusCode >= 200 && res.StatusCode < 300 {
		return res, nil
	}
	defer res.Body.Close()
	var body struct {
		Detail any `json:"detail"`
	}
	raw, _ := io.ReadAll(io.LimitReader(res.Body, 64<<10))
	apiErr := &Error{Status: res.StatusCode}
	if json.Unmarshal(raw, &body) == nil && body.Detail != nil {
		if s, ok := body.Detail.(string); ok {
			apiErr.Detail = s
		} else {
			encoded, _ := json.Marshal(body.Detail)
			apiErr.Detail = string(encoded)
		}
	}
	return nil, apiErr
}

func (c *Client) doJSON(req *http.Request, out any) error {
	res, err := c.do(req)
	if err != nil {
		return err
	}
	defer res.Body.Close()
	if out == nil {
		_, err = io.Copy(io.Discard, res.Body)
		return err
	}
	if err := json.NewDecoder(res.Body).Decode(out); err != nil {
		return fmt.Errorf("unexpected response from the Drive: %w", err)
	}
	return nil
}

func (c *Client) getJSON(ctx context.Context, endpoint string, query url.Values, out any) error {
	req, err := c.newRequest(ctx, http.MethodGet, endpoint, query, nil)
	if err != nil {
		return err
	}
	return c.doJSON(req, out)
}

func (c *Client) postForm(ctx context.Context, endpoint string, form url.Values, out any) error {
	req, err := c.newRequest(ctx, http.MethodPost, endpoint, nil, strings.NewReader(form.Encode()))
	if err != nil {
		return err
	}
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	return c.doJSON(req, out)
}

// Me returns the account behind the token.
func (c *Client) Me(ctx context.Context) (Me, error) {
	var me Me
	err := c.getJSON(ctx, "/api/me", nil, &me)
	return me, err
}

// List returns the contents of a folder.
func (c *Client) List(ctx context.Context, dir string) (Listing, error) {
	var listing Listing
	err := c.getJSON(ctx, "/api/files", url.Values{"path": {CleanPath(dir)}}, &listing)
	return listing, err
}

// Stat finds one entry by listing its parent. The share root is a folder.
func (c *Client) Stat(ctx context.Context, p string) (Entry, bool, error) {
	p = CleanPath(p)
	if p == "" {
		return Entry{Name: "", Path: "", IsDir: true}, true, nil
	}
	dir, name := SplitPath(p)
	listing, err := c.List(ctx, dir)
	if err != nil {
		return Entry{}, false, err
	}
	for _, item := range listing.Items {
		if item.Name == name {
			return item, true, nil
		}
	}
	return Entry{}, false, nil
}

// Search runs the Drive's recursive name search.
func (c *Client) Search(ctx context.Context, query, under string, limit int) (SearchResult, error) {
	var result SearchResult
	q := url.Values{"q": {query}, "path": {CleanPath(under)}}
	if limit > 0 {
		q.Set("limit", fmt.Sprint(limit))
	}
	err := c.getJSON(ctx, "/api/search", q, &result)
	return result, err
}

// Download streams a file's bytes. The caller closes the reader.
func (c *Client) Download(ctx context.Context, p string) (io.ReadCloser, error) {
	req, err := c.newRequest(ctx, http.MethodGet, "/api/download", url.Values{"path": {CleanPath(p)}, "inline": {"0"}}, nil)
	if err != nil {
		return nil, err
	}
	res, err := c.do(req)
	if err != nil {
		return nil, err
	}
	return res.Body, nil
}

// DownloadZip streams a zip of the given files/folders.
func (c *Client) DownloadZip(ctx context.Context, paths ...string) (io.ReadCloser, error) {
	q := url.Values{}
	for _, p := range paths {
		q.Add("path", CleanPath(p))
	}
	req, err := c.newRequest(ctx, http.MethodGet, "/api/download/zip", q, nil)
	if err != nil {
		return nil, err
	}
	res, err := c.do(req)
	if err != nil {
		return nil, err
	}
	return res.Body, nil
}

// Mkdir creates one folder named name inside parent.
func (c *Client) Mkdir(ctx context.Context, parent, name string) (Entry, error) {
	var entry Entry
	err := c.postForm(ctx, "/api/mkdir", url.Values{"path": {CleanPath(parent)}, "name": {name}}, &entry)
	return entry, err
}

// Rename renames an item in place.
func (c *Client) Rename(ctx context.Context, p, newName string) error {
	return c.postForm(ctx, "/api/rename", url.Values{"path": {CleanPath(p)}, "new_name": {newName}}, nil)
}

// Move moves an item into destDir.
func (c *Client) Move(ctx context.Context, p, destDir string) error {
	return c.postForm(ctx, "/api/move", url.Values{"path": {CleanPath(p)}, "dest": {CleanPath(destDir)}}, nil)
}

// Delete moves an item to the share's recycle bin (or deletes it when there is none).
func (c *Client) Delete(ctx context.Context, p string) (DeleteResult, error) {
	var result DeleteResult
	err := c.postForm(ctx, "/api/delete", url.Values{"path": {CleanPath(p)}}, &result)
	return result, err
}

// Logout revokes the token on the server.
func (c *Client) Logout(ctx context.Context) error {
	req, err := c.newRequest(ctx, http.MethodPost, "/api/cli/logout", nil, nil)
	if err != nil {
		return err
	}
	return c.doJSON(req, nil)
}
