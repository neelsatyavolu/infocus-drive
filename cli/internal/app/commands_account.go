package app

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"io"
	"slices"

	"github.com/neelsatyavolu/infocus-drive/cli/internal/auth"
	"github.com/neelsatyavolu/infocus-drive/cli/internal/config"
)

func cmdLogin(ctx context.Context, r *runner, args []string) error {
	fs := flag.NewFlagSet("login", flag.ContinueOnError)
	device := fs.String("device", "", "name shown in Terminal sign-ins")
	server := fs.String("server", "", "Drive URL")
	noBrowser := fs.Bool("no-browser", false, "print the approval URL instead of opening it")
	rest, err := parseFlags(fs, args)
	if err != nil {
		return err
	}
	if len(rest) > 0 {
		return usagef("usage: infocus login [--server URL] [--device NAME] [--no-browser]")
	}
	if *server != "" {
		r.g.server = *server
	}
	serverURL, err := config.ParseServer(r.serverURLString())
	if err != nil {
		return usageError{err.Error()}
	}
	name := *device
	if name == "" {
		name = r.env.DeviceName()
	}
	open := r.env.OpenBrowser
	if *noBrowser {
		open = nil
	}
	notify := r.env.Stderr
	result, err := auth.Login(ctx, auth.Options{
		Server: serverURL, Device: name, OpenBrowser: open,
		Notify: notify, HTTP: r.env.HTTP,
	})
	if err != nil {
		return exitError{ExitAuth, err.Error()}
	}
	if err := r.env.Tokens.Set(serverURL.Host, result.Token); err != nil {
		return err
	}
	if r.cfg.Server != serverURL.String() {
		r.cfg.Server = serverURL.String()
		if err := config.Save(r.env.ConfigDir, r.cfg); err != nil {
			return err
		}
	}
	out := map[string]string{"username": result.Username, "device": result.Device, "server": serverURL.String()}
	return r.emit(out, func(w io.Writer) {
		fmt.Fprintf(w, "Signed in to %s as %s.\n", serverURL.Host, result.Username)
	})
}

func cmdLogout(ctx context.Context, r *runner, args []string) error {
	if len(args) > 0 {
		return usagef("usage: infocus logout")
	}
	client, err := r.signedIn()
	if errors.Is(err, config.ErrNoToken) {
		return r.emit(map[string]bool{"signed_out": true}, func(w io.Writer) {
			fmt.Fprintln(w, "Already signed out.")
		})
	}
	if err != nil {
		return err
	}
	var warning string
	if err := client.Logout(ctx); err != nil {
		// Still forget the local token; the server one expires on its own.
		warning = err.Error()
	}
	if err := r.env.Tokens.Delete(client.Base.Host); err != nil {
		return err
	}
	out := map[string]any{"signed_out": true}
	if warning != "" {
		out["warning"] = warning
	}
	return r.emit(out, func(w io.Writer) {
		fmt.Fprintf(w, "Signed out of %s.\n", client.Base.Host)
		if warning != "" {
			fmt.Fprintf(w, "(The Drive didn't confirm: %s)\n", warning)
		}
	})
}

func cmdWhoami(ctx context.Context, r *runner, args []string) error {
	if len(args) > 0 {
		return usagef("usage: infocus whoami")
	}
	client, err := r.signedIn()
	if err != nil {
		return err
	}
	me, err := client.Me(ctx)
	if err != nil {
		return err
	}
	if !me.Authenticated {
		return exitError{ExitAuth, "sign-in expired or revoked; run infocus login"}
	}
	return r.emit(me, func(w io.Writer) {
		fmt.Fprintf(w, "%s (%s)\nshare: %s\nserver: %s\n", me.Username, me.Email, me.Share, client.Base.Host)
	})
}

func cmdShares(ctx context.Context, r *runner, args []string) error {
	if len(args) > 0 {
		return usagef("usage: infocus shares")
	}
	client, err := r.signedIn()
	if err != nil {
		return err
	}
	me, err := client.Me(ctx)
	if err != nil {
		return err
	}
	out := map[string]any{"active": me.Share, "shares": me.Shares}
	return r.emit(out, func(w io.Writer) {
		for _, s := range me.Shares {
			mark := "  "
			if s == me.Share {
				mark = "* "
			}
			fmt.Fprintln(w, mark+s)
		}
	})
}

func cmdShare(ctx context.Context, r *runner, args []string) error {
	if len(args) != 2 || args[0] != "use" {
		return usagef("usage: infocus share use NAME")
	}
	client, err := r.signedIn()
	if err != nil {
		return err
	}
	me, err := client.Me(ctx)
	if err != nil {
		return err
	}
	if !slices.Contains(me.Shares, args[1]) {
		return exitError{ExitNotFound, fmt.Sprintf("no share named %q (see infocus shares)", args[1])}
	}
	r.cfg.Share = args[1]
	if err := config.Save(r.env.ConfigDir, r.cfg); err != nil {
		return err
	}
	return r.emit(map[string]string{"share": args[1]}, func(w io.Writer) {
		fmt.Fprintf(w, "Now using share %q.\n", args[1])
	})
}

func cmdVersion(_ context.Context, r *runner, _ []string) error {
	return r.emit(map[string]string{"version": Version, "commit": Commit}, func(w io.Writer) {
		fmt.Fprintf(w, "infocus %s (%s)\n", Version, Commit)
	})
}

func cmdHelp(_ context.Context, r *runner, args []string) error {
	if len(args) == 1 && args[0] == "agents" {
		fmt.Fprint(r.env.Stdout, agentGuide)
		return nil
	}
	if len(args) == 1 {
		if cmd, ok := commands[args[0]]; ok {
			fmt.Fprintf(r.env.Stdout, "usage: infocus %s\n  %s\n", cmd.usage, cmd.summary)
			return nil
		}
	}
	printUsage(r.env.Stdout)
	return nil
}

const agentGuide = `InFocus Drive CLI — guide for AI agents

The human has already run "infocus login"; you act with their Drive permissions.
Every command accepts --json: results go to stdout as JSON, errors to stderr as
{"error": "...", "exit_code": N, "status": HTTP}. Nothing prompts when stdin is
not a terminal.

Paths are relative to the share root: "Shows/Episode 1/script.md".
Use --share NAME (or "infocus share use NAME") for other shares; "infocus shares"
lists them.

Read:
  infocus --json ls "Shows"               folder listing (items[].mtime_ns, size, is_dir)
  infocus --json tree "Shows" --depth 2   recursive listing
  infocus --json search "interview"       name search
  infocus cat "Shows/notes.md"            file contents to stdout

Write:
  infocus put local.txt "Shows/notes.md"          create (fails with exit 4 if it exists)
  infocus put --force local.txt "Shows/notes.md"  overwrite
  printf 'text' | infocus put - "Shows/notes.md"  from stdin
  infocus mkdir -p "Shows/New/Assets"
  infocus mv "Shows/a.mp4" "Archive"              move into a folder
  infocus rename "Shows/a.mp4" "b.mp4"
  infocus rm "Shows/old.mp4"                      moves to the Recycle bin

Safe edit without clobbering someone else's change:
  1. infocus --json ls "Shows" → note the file's mtime_ns
  2. infocus cat "Shows/notes.md" > notes.md ; edit locally
  3. infocus put --expect-mtime-ns <mtime_ns> notes.md "Shows/notes.md"
     exit 4 means the file changed on the Drive meanwhile: re-read and retry.

Exit codes: 0 ok · 1 error · 2 bad usage · 3 not signed in (ask the human to run
"infocus login") · 4 conflict / already exists · 5 not found or no permission.
`
