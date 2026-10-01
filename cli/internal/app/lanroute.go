package app

import (
	"context"
	"crypto/rand"
	"encoding/base64"
	"net/url"
	"time"

	"github.com/neelsatyavolu/infocus-drive/cli/internal/api"
)

const (
	lanCheckEvery = 30 * time.Second
	lanProbeLimit = 3 * time.Second
	lanRenewAt    = 30 * time.Minute // renew the LAN token this long before it expires
)

// lanMonitor puts the helper on the Drive's LAN address while it's reachable
// (on the school network) and keeps it there. It never sends a token to a
// LAN host before that host proved it is this Drive, and it only ever sends
// the short-lived LAN token there. Leaving the network is handled by the
// client itself (any LAN failure falls back to the internet at once); this
// re-checks every 30 s and whenever the app says the network changed.
type lanMonitor struct {
	client *api.Client // its LAN route is what this manages
}

func (m *lanMonitor) run(ctx context.Context, probe <-chan struct{}) {
	m.check(ctx)
	ticker := time.NewTicker(lanCheckEvery)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
		case <-probe:
		}
		m.check(ctx)
	}
}

func (m *lanMonitor) check(ctx context.Context) {
	route := m.client.LAN
	if r := route.Get(); r != nil {
		probeCtx, cancel := context.WithTimeout(ctx, lanProbeLimit)
		healthy := m.client.Healthy(probeCtx, r.Base)
		cancel()
		if !healthy {
			route.Drop()
			return
		}
		if time.Until(r.Expires) > lanRenewAt {
			return
		}
	}
	if r, ok := m.connect(ctx); ok {
		route.Set(r)
	}
}

// connect finds the Drive's LAN address, checks it's reachable and genuinely
// this Drive, and gets a LAN token for it.
func (m *lanMonitor) connect(ctx context.Context) (*api.Route, bool) {
	internet := m.client.Internet()
	me, err := internet.Me(ctx)
	if err != nil || me.LANOrigin == "" {
		return nil, false
	}
	lan, err := url.Parse(me.LANOrigin)
	if err != nil || (lan.Scheme != "http" && lan.Scheme != "https") || lan.Host == "" {
		return nil, false
	}
	probeCtx, cancel := context.WithTimeout(ctx, lanProbeLimit)
	defer cancel()
	if !m.client.Healthy(probeCtx, lan) {
		return nil, false // not on the school network
	}
	raw := make([]byte, 32)
	if _, err := rand.Read(raw); err != nil {
		return nil, false
	}
	nonce := base64.RawURLEncoding.EncodeToString(raw)
	proof, err := m.client.LANProof(probeCtx, lan, nonce)
	if err != nil {
		return nil, false
	}
	grant, err := internet.LANToken(ctx, nonce, proof) // the Drive checks the proof over HTTPS
	if err != nil || grant.LANOrigin != me.LANOrigin {
		return nil, false
	}
	return &api.Route{Base: lan, Token: grant.Token, Expires: time.Now().Add(time.Duration(grant.ExpiresIn) * time.Second)}, true
}
