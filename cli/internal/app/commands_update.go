package app

import (
	"context"
	"fmt"
	"io"
	"time"

	"github.com/neelsatyavolu/infocus-drive/cli/internal/config"
	"github.com/neelsatyavolu/infocus-drive/cli/internal/update"
)

func (r *runner) updater() update.Updater {
	repo := r.env.UpdateRepo
	if repo == "" {
		repo = update.DefaultRepo
	}
	return update.Updater{Repo: repo, HTTP: r.env.HTTP}
}

func (r *runner) executable() (string, error) {
	if r.env.Executable == nil {
		return update.Executable()
	}
	return r.env.Executable()
}

func (r *runner) autoUpdateOn() bool {
	if r.env.Getenv("INFOCUS_NO_UPDATE") == "1" {
		return false
	}
	return r.cfg.AutoUpdate == nil || *r.cfg.AutoUpdate
}

// maybeAutoUpdate runs after a successful command: at most daily, only for a
// person at a terminal, never for --json/agents or development builds.
func (r *runner) maybeAutoUpdate(ctx context.Context, command string) {
	switch command {
	case "update", "version", "help", "config":
		return
	}
	if !r.env.StdinIsTTY || !r.env.StderrIsTTY || r.g.json || ctx.Err() != nil || !r.autoUpdateOn() {
		return
	}
	if !update.Valid(Version) {
		return
	}
	now := r.now()
	if !update.Due(r.env.ConfigDir, now) {
		return
	}
	checkCtx, cancel := context.WithTimeout(ctx, 3*time.Second)
	latest, err := r.updater().Latest(checkCtx)
	cancel()
	update.MarkChecked(r.env.ConfigDir, now, latest)
	if err != nil || !update.Newer(latest, Version) {
		return
	}
	fmt.Fprintf(r.env.Stderr, "Updating infocus %s → %s…\n", Version, latest)
	if err := r.install(ctx, latest, 60*time.Second); err != nil {
		fmt.Fprintf(r.env.Stderr, "infocus %s is available — run infocus update (%v)\n", latest, err)
		return
	}
	fmt.Fprintln(r.env.Stderr, "Updated.")
}

func (r *runner) install(ctx context.Context, version string, limit time.Duration) error {
	exe, err := r.executable()
	if err != nil {
		return fmt.Errorf("find the infocus binary: %w", err)
	}
	ctx, cancel := context.WithTimeout(ctx, limit)
	defer cancel()
	return r.updater().Install(ctx, version, exe)
}

func cmdUpdate(ctx context.Context, r *runner, args []string) error {
	if len(args) > 0 {
		return usagef("usage: infocus update")
	}
	out := map[string]any{"from": Version, "to": Version, "updated": false}
	if !update.Valid(Version) {
		return r.emit(out, func(w io.Writer) { fmt.Fprintln(w, "This is a development build; not updating.") })
	}
	checkCtx, cancel := context.WithTimeout(ctx, 15*time.Second)
	latest, err := r.updater().Latest(checkCtx)
	cancel()
	if err != nil {
		return err
	}
	update.MarkChecked(r.env.ConfigDir, r.now(), latest)
	if !update.Newer(latest, Version) {
		return r.emit(out, func(w io.Writer) { fmt.Fprintf(w, "infocus %s is up to date.\n", Version) })
	}
	if err := r.install(ctx, latest, 2*time.Minute); err != nil {
		return err
	}
	out["to"], out["updated"] = latest, true
	return r.emit(out, func(w io.Writer) { fmt.Fprintf(w, "Updated infocus %s → %s.\n", Version, latest) })
}

func cmdConfig(_ context.Context, r *runner, args []string) error {
	switch {
	case len(args) == 0:
		return r.emit(map[string]any{"server": r.cfg.Server, "share": r.cfg.Share, "auto_update": r.autoUpdateOn()},
			func(w io.Writer) {
				fmt.Fprintf(w, "server: %s\nshare: %s\nauto-update: %v\n", r.cfg.Server, r.cfg.Share, r.autoUpdateOn())
			})
	case len(args) == 2 && args[0] == "auto-update" && (args[1] == "on" || args[1] == "off"):
		on := args[1] == "on"
		r.cfg.AutoUpdate = &on
		if err := config.Save(r.env.ConfigDir, r.cfg); err != nil {
			return err
		}
		return r.emit(map[string]bool{"auto_update": on}, func(w io.Writer) {
			fmt.Fprintf(w, "Auto-update is %s.\n", args[1])
		})
	}
	return usagef("usage: infocus config [auto-update on|off]")
}
