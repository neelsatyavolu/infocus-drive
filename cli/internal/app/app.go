// Package app implements the `infocus` commands.
package app

import (
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"net/http"
	"os"
	"strings"

	"github.com/neelsatyavolu/infocus-drive/cli/internal/api"
	"github.com/neelsatyavolu/infocus-drive/cli/internal/config"
)

// Exit codes (documented in `infocus help agents`).
const (
	ExitOK       = 0
	ExitError    = 1
	ExitUsage    = 2
	ExitAuth     = 3
	ExitConflict = 4
	ExitNotFound = 5
)

// Build info, set with -ldflags "-X …/app.Version=… -X …/app.Commit=…".
var (
	Version = "dev"
	Commit  = "none"
)

// Env is everything a command touches outside the process (swapped in tests).
type Env struct {
	Stdin       io.Reader
	Stdout      io.Writer
	Stderr      io.Writer
	StdinIsTTY  bool
	ConfigDir   string
	Tokens      config.TokenStore
	HTTP        *http.Client
	OpenBrowser func(string) error
	RunEditor   func(path string) error
	DeviceName  func() string
	Getenv      func(string) string
}

// globals are flags accepted before or after the command name.
type globals struct {
	json   bool
	share  string
	server string
	help   bool
}

type cmdFunc func(ctx context.Context, r *runner, args []string) error

type command struct {
	run     cmdFunc
	usage   string
	summary string
}

var commands map[string]command

func init() {
	commands = map[string]command{
		"login":   {cmdLogin, "login [--server URL] [--device NAME] [--no-browser]", "Sign this terminal in (opens your browser)"},
		"logout":  {cmdLogout, "logout", "Sign this terminal out and revoke its token"},
		"whoami":  {cmdWhoami, "whoami", "Show the signed-in account and active share"},
		"shares":  {cmdShares, "shares", "List the shares you can use"},
		"share":   {cmdShare, "share use NAME", "Set the default share for later commands"},
		"ls":      {cmdLs, "ls [PATH]", "List a folder"},
		"tree":    {cmdTree, "tree [PATH] [--depth N]", "List a folder recursively (default depth 3)"},
		"search":  {cmdSearch, "search QUERY [--path P] [--limit N]", "Search file and folder names"},
		"cat":     {cmdCat, "cat PATH", "Print a file to stdout"},
		"get":     {cmdGet, "get PATH [LOCAL|-] [--force]", "Download a file (folders download as .zip)"},
		"put":     {cmdPut, "put LOCAL|- REMOTE [--force]", "Upload a file or stdin (won't overwrite without --force)"},
		"edit":    {cmdEdit, "edit PATH", "Edit a file in $EDITOR and save it back safely"},
		"mkdir":   {cmdMkdir, "mkdir PATH [-p]", "Create a folder (-p: parents too, ok if it exists)"},
		"mv":      {cmdMv, "mv SRC... DEST_FOLDER", "Move items into a folder"},
		"rename":  {cmdRename, "rename PATH NEW_NAME", "Rename an item in place"},
		"rm":      {cmdRm, "rm PATH... [-y]", "Move items to the Recycle bin"},
		"version": {cmdVersion, "version", "Print the CLI version"},
		"help":    {cmdHelp, "help [agents]", "Show help (help agents: guide for AI agents)"},
	}
}

var commandOrder = []string{
	"login", "logout", "whoami", "shares", "share",
	"ls", "tree", "search", "cat", "get", "put", "edit",
	"mkdir", "mv", "rename", "rm", "version", "help",
}

// runner is one invocation's state.
type runner struct {
	env    Env
	g      globals
	cfg    config.Config
	client *api.Client // set by signedIn()
}

// usageError is a bad invocation (exit 2).
type usageError struct{ msg string }

func (e usageError) Error() string { return e.msg }

func usagef(format string, args ...any) error { return usageError{fmt.Sprintf(format, args...)} }

// Run executes argv (without the program name) and returns the exit code.
func Run(ctx context.Context, argv []string, env Env) int {
	g, rest, err := splitGlobals(argv)
	r := &runner{env: env, g: g}
	if err != nil {
		return r.fail(err)
	}
	if len(rest) == 0 {
		printUsage(env.Stdout)
		return ExitOK
	}
	name, args := rest[0], rest[1:]
	cmd, ok := commands[name]
	if !ok {
		return r.fail(usagef("unknown command %q (see infocus help)", name))
	}
	if g.help {
		fmt.Fprintf(env.Stdout, "usage: infocus %s\n  %s\n", cmd.usage, cmd.summary)
		return ExitOK
	}
	cfg, err := config.Load(env.ConfigDir)
	if err != nil {
		return r.fail(err)
	}
	r.cfg = cfg
	return r.fail(cmd.run(ctx, r, args))
}

func splitGlobals(argv []string) (globals, []string, error) {
	var g globals
	var rest []string
	for i := 0; i < len(argv); i++ {
		arg := argv[i]
		name, value, hasValue := strings.Cut(arg, "=")
		switch name {
		case "--json":
			g.json = true
		case "-h", "--help":
			g.help = true
		case "--share", "--server":
			if !hasValue {
				if i+1 >= len(argv) {
					return g, nil, usagef("%s needs a value", name)
				}
				i++
				value = argv[i]
			}
			if name == "--share" {
				g.share = value
			} else {
				g.server = value
			}
		case "--":
			return g, append(rest, argv[i+1:]...), nil
		default:
			rest = append(rest, arg)
		}
	}
	return g, rest, nil
}

// parseFlags parses flags that may appear anywhere among the positionals.
func parseFlags(fs *flag.FlagSet, args []string) ([]string, error) {
	fs.SetOutput(io.Discard)
	var positional []string
	for {
		if err := fs.Parse(args); err != nil {
			return nil, usagef("%v", err)
		}
		args = fs.Args()
		if len(args) == 0 {
			return positional, nil
		}
		if args[0] == "-" { // stdin marker, not a flag
			positional = append(positional, args[0])
			args = args[1:]
			continue
		}
		positional = append(positional, args[0])
		args = args[1:]
	}
}

// fail reports err (if any) and maps it to an exit code.
func (r *runner) fail(err error) int {
	if err == nil {
		return ExitOK
	}
	code, status := ExitError, 0
	var apiErr *api.Error
	var usage usageError
	var exit exitError
	switch {
	case errors.As(err, &usage):
		code = ExitUsage
	case errors.Is(err, config.ErrNoToken):
		code = ExitAuth
		err = errors.New("not signed in; run infocus login")
	case errors.As(err, &apiErr):
		status = apiErr.Status
		switch apiErr.Status {
		case http.StatusUnauthorized:
			code = ExitAuth
		case http.StatusConflict:
			code = ExitConflict
		case http.StatusForbidden, http.StatusNotFound:
			code = ExitNotFound
		}
	case errors.As(err, &exit):
		code = exit.code
	}
	if r.g.json {
		out := map[string]any{"error": err.Error(), "exit_code": code}
		if status != 0 {
			out["status"] = status
		}
		json.NewEncoder(r.env.Stderr).Encode(out) //nolint:errcheck
	} else {
		fmt.Fprintf(r.env.Stderr, "infocus: %v\n", err)
	}
	return code
}

// exitError carries a specific exit code for non-API failures.
type exitError struct {
	code int
	msg  string
}

func (e exitError) Error() string { return e.msg }

func (r *runner) serverURLString() string {
	if r.g.server != "" {
		return r.g.server
	}
	if v := r.env.Getenv("INFOCUS_SERVER"); v != "" {
		return v
	}
	return r.cfg.Server
}

// signedIn prepares an API client with the saved token.
func (r *runner) signedIn() (*api.Client, error) {
	server, err := config.ParseServer(r.serverURLString())
	if err != nil {
		return nil, usageError{err.Error()}
	}
	token, err := r.env.Tokens.Get(server.Host)
	if err != nil {
		return nil, err
	}
	share := r.g.share
	if share == "" {
		share = r.cfg.Share
	}
	r.client = &api.Client{
		Base: server, Token: token, Share: share, HTTP: r.env.HTTP,
		UserAgent: "infocus-cli/" + Version,
	}
	return r.client, nil
}

// emit prints v as JSON in --json mode, otherwise calls human().
func (r *runner) emit(v any, human func(w io.Writer)) error {
	if r.g.json {
		enc := json.NewEncoder(r.env.Stdout)
		enc.SetIndent("", "  ")
		return enc.Encode(v)
	}
	human(r.env.Stdout)
	return nil
}

func printUsage(w io.Writer) {
	fmt.Fprintln(w, "infocus — InFocus Drive from your terminal")
	fmt.Fprintln(w, "\nusage: infocus [--json] [--share NAME] [--server URL] <command> [args]")
	fmt.Fprintln(w, "\ncommands:")
	for _, name := range commandOrder {
		cmd := commands[name]
		fmt.Fprintf(w, "  %-38s %s\n", cmd.usage, cmd.summary)
	}
	fmt.Fprintln(w, "\nPaths are relative to the share root, e.g. \"Shows/Episode 1/cut.mp4\".")
	fmt.Fprintln(w, "AI agents: run  infocus help agents")
}

// DefaultEnv is the real terminal environment.
func DefaultEnv() (Env, error) {
	dir, err := config.Dir()
	if err != nil {
		return Env{}, err
	}
	info, _ := os.Stdin.Stat()
	return Env{
		Stdin:       os.Stdin,
		Stdout:      os.Stdout,
		Stderr:      os.Stderr,
		StdinIsTTY:  info != nil && info.Mode()&os.ModeCharDevice != 0,
		ConfigDir:   dir,
		Tokens:      config.Keychain{},
		HTTP:        &http.Client{},
		OpenBrowser: openBrowser,
		RunEditor:   runEditor,
		DeviceName:  deviceName,
		Getenv:      os.Getenv,
	}, nil
}
