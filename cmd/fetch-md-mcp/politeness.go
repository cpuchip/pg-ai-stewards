// Politeness floor for crawl-mode fetches (98-crawler, 2026-07-03).
//
// Two guardrails, both applied ONLY when a tool call sets
// `enforce_robots: true` (the purpose-crawler always does; interactive
// single-page callers keep today's behavior — changing the default would
// break existing use):
//
//  1. robots.txt — fetched + cached per scheme://host (TTL ~1h), parsed
//     per RFC 9309 (group selection by product token, longest-match rule
//     precedence, Allow wins ties, `*` and `$` in paths). A disallowed
//     URL returns a clear structured error, never a silent empty result.
//     Unreachable robots.txt (5xx / network error) FAILS CLOSED per RFC
//     9309 §2.3.1.4; 4xx (incl. 404) means "no restrictions".
//
//  2. Per-domain rate limit — a min-interval reservation ledger keyed by
//     scheme://host. Default 2s between requests; callers may tune via
//     `rate_ms` but the 500ms floor is structural (the LLM can only stay
//     UNDER the guardrail, never raise it). Concurrent fetch_urls
//     batches serialize per host by construction: each fetch reserves
//     the next slot under one mutex, then sleeps until its slot.
//
// The JS path (chromedp) gets the same robots + rate gate up front;
// redirects inside Chromium are not re-checked (noted limitation — the
// plain-HTTP path re-checks robots on every redirect hop via
// politeCheckRedirect).

package main

import (
	"context"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strings"
	"sync"
	"time"
)

const (
	// defaultRateMS is the per-domain min interval when enforce_robots is
	// on and the caller didn't tune rate_ms. ~1 req / 2s, the spec default.
	defaultRateMS = 2000
	// minRateMS is the structural floor: rate_ms below this is clamped UP.
	minRateMS = 500
	// robotsTTL is how long a fetched robots.txt is trusted.
	robotsTTL = time.Hour
	// robotsErrTTL retries an unreachable robots.txt sooner than a good one.
	robotsErrTTL = 5 * time.Minute
	// robotsMaxBytes caps the robots.txt body read (RFC 9309 says parse at
	// least 500 KiB; anything past this is ignored).
	robotsMaxBytes = 512 * 1024
)

// robotsRule is one Allow/Disallow line from the group that governs us.
type robotsRule struct {
	allow bool
	path  string
}

// robotsEntry is the cached verdict material for one scheme://host.
type robotsEntry struct {
	rules       []robotsRule
	expires     time.Time
	unreachable bool // 5xx / network error -> fail closed until re-probe
}

// politeGate holds the per-process robots cache and the per-domain
// rate-reservation ledger. One instance per server (see main.go).
type politeGate struct {
	client *http.Client
	ua     string

	mu     sync.Mutex
	robots map[string]*robotsEntry
	nextAt map[string]time.Time

	// now is swappable for tests.
	now func() time.Time
}

func newPoliteGate(client *http.Client, userAgent string) *politeGate {
	return &politeGate{
		client: client,
		ua:     userAgent,
		robots: map[string]*robotsEntry{},
		nextAt: map[string]time.Time{},
		now:    time.Now,
	}
}

// effectiveInterval clamps a caller's rate_ms to the structural floor.
func effectiveInterval(rateMS int) time.Duration {
	if rateMS <= 0 {
		rateMS = defaultRateMS
	}
	if rateMS < minRateMS {
		rateMS = minRateMS
	}
	return time.Duration(rateMS) * time.Millisecond
}

// hostKey normalizes a URL to its rate/robots cache key.
func hostKey(u *url.URL) string {
	return strings.ToLower(u.Scheme) + "://" + strings.ToLower(u.Host)
}

// uaProduct extracts the product token from a full User-Agent string
// ("fetch-md-mcp/0.1 (+https://...)" -> "fetch-md-mcp").
func uaProduct(ua string) string {
	tok := ua
	if i := strings.IndexAny(tok, "/ "); i >= 0 {
		tok = tok[:i]
	}
	return strings.ToLower(strings.TrimSpace(tok))
}

// Check is the whole politeness gate for one outbound fetch: robots
// verdict first (clear error when disallowed), then a rate-slot
// reservation + sleep. Returns nil when the fetch may proceed.
func (g *politeGate) Check(ctx context.Context, target string, rateMS int) error {
	u, err := url.Parse(target)
	if err != nil {
		return fmt.Errorf("politeness: parse %q: %w", target, err)
	}
	if u.Scheme != "http" && u.Scheme != "https" {
		return fmt.Errorf("politeness: %q is not http(s)", target)
	}
	interval := effectiveInterval(rateMS)

	if err := g.robotsAllow(ctx, u, interval); err != nil {
		return err
	}
	return g.rateWait(ctx, hostKey(u), interval)
}

// robotsAllow returns nil when robots.txt permits fetching u, else a
// structured error naming the rule (or the fail-closed condition).
func (g *politeGate) robotsAllow(ctx context.Context, u *url.URL, interval time.Duration) error {
	entry, err := g.robotsFor(ctx, u, interval)
	if err != nil {
		return err
	}
	if entry.unreachable {
		return fmt.Errorf(
			"politeness: robots.txt for %s is unreachable (server error) — failing closed per RFC 9309; retry after %s",
			hostKey(u), robotsErrTTL)
	}
	pathQ := u.EscapedPath()
	if pathQ == "" {
		pathQ = "/"
	}
	if u.RawQuery != "" {
		pathQ += "?" + u.RawQuery
	}
	if ok, rule := robotsVerdict(entry.rules, pathQ); !ok {
		return fmt.Errorf(
			"politeness: robots.txt disallows %q for User-Agent %q (matched rule: Disallow: %s)",
			u.String(), g.ua, rule)
	}
	return nil
}

// robotsFor returns the cached (or freshly fetched) robots entry for
// u's scheme://host. The robots.txt fetch itself consumes a rate slot.
func (g *politeGate) robotsFor(ctx context.Context, u *url.URL, interval time.Duration) (*robotsEntry, error) {
	key := hostKey(u)

	g.mu.Lock()
	if e, ok := g.robots[key]; ok && g.now().Before(e.expires) {
		g.mu.Unlock()
		return e, nil
	}
	g.mu.Unlock()

	// Be polite to the robots.txt endpoint too.
	if err := g.rateWait(ctx, key, interval); err != nil {
		return nil, err
	}

	robotsURL := u.Scheme + "://" + u.Host + "/robots.txt"
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, robotsURL, nil)
	if err != nil {
		return nil, fmt.Errorf("politeness: build robots request: %w", err)
	}
	req.Header.Set("User-Agent", g.ua)

	entry := &robotsEntry{expires: g.now().Add(robotsTTL)}
	resp, err := g.client.Do(req)
	if err != nil {
		entry.unreachable = true
		entry.expires = g.now().Add(robotsErrTTL)
	} else {
		defer resp.Body.Close()
		switch {
		case resp.StatusCode >= 200 && resp.StatusCode < 300:
			body, rerr := io.ReadAll(io.LimitReader(resp.Body, robotsMaxBytes))
			if rerr != nil {
				entry.unreachable = true
				entry.expires = g.now().Add(robotsErrTTL)
			} else {
				entry.rules = parseRobots(string(body), uaProduct(g.ua))
			}
		case resp.StatusCode >= 400 && resp.StatusCode < 500:
			// No robots.txt (or forbidden to us) = no restrictions.
			entry.rules = nil
		default:
			// 3xx (client didn't follow) / 5xx: fail closed, re-probe soon.
			entry.unreachable = true
			entry.expires = g.now().Add(robotsErrTTL)
		}
	}

	g.mu.Lock()
	g.robots[key] = entry
	g.mu.Unlock()
	return entry, nil
}

// rateWait reserves the next per-host slot and sleeps until it. The
// reservation happens under one mutex, so concurrent goroutines (a
// fetch_urls batch) serialize per host with correct spacing.
func (g *politeGate) rateWait(ctx context.Context, key string, interval time.Duration) error {
	g.mu.Lock()
	now := g.now()
	at := g.nextAt[key]
	if at.Before(now) {
		at = now
	}
	g.nextAt[key] = at.Add(interval)
	g.mu.Unlock()

	wait := at.Sub(now)
	if wait <= 0 {
		return nil
	}
	t := time.NewTimer(wait)
	defer t.Stop()
	select {
	case <-ctx.Done():
		return ctx.Err()
	case <-t.C:
		return nil
	}
}

// ---------------------------------------------------------------------
// robots.txt parsing (RFC 9309 subset)
// ---------------------------------------------------------------------

// parseRobots extracts the Allow/Disallow rules that govern product.
// Group selection: if any group's User-agent line matches our product
// token (case-insensitive substring per common practice), the union of
// all matching specific groups applies and `*` groups are ignored;
// otherwise the union of `*` groups applies.
func parseRobots(body, product string) []robotsRule {
	type group struct {
		agents []string
		rules  []robotsRule
	}
	var groups []group
	var cur *group
	inAgents := false // consecutive User-agent lines share one group

	for _, raw := range strings.Split(body, "\n") {
		line := raw
		if i := strings.Index(line, "#"); i >= 0 {
			line = line[:i]
		}
		line = strings.TrimSpace(line)
		if line == "" {
			continue
		}
		i := strings.Index(line, ":")
		if i < 0 {
			continue
		}
		field := strings.ToLower(strings.TrimSpace(line[:i]))
		value := strings.TrimSpace(line[i+1:])

		switch field {
		case "user-agent":
			if !inAgents {
				groups = append(groups, group{})
				cur = &groups[len(groups)-1]
				inAgents = true
			}
			cur.agents = append(cur.agents, strings.ToLower(value))
		case "allow", "disallow":
			inAgents = false
			if cur == nil || value == "" {
				continue // rules before any group, or empty path: no-op
			}
			cur.rules = append(cur.rules, robotsRule{
				allow: field == "allow",
				path:  value,
			})
		default:
			// crawl-delay, sitemap, unknown fields: end the agent run but
			// stay in the current group.
			inAgents = false
		}
	}

	matches := func(agent string) bool {
		return agent != "*" && strings.Contains(product, agent)
	}
	var specific, wildcard []robotsRule
	for _, gr := range groups {
		isSpecific, isWild := false, false
		for _, a := range gr.agents {
			if matches(a) {
				isSpecific = true
			}
			if a == "*" {
				isWild = true
			}
		}
		if isSpecific {
			specific = append(specific, gr.rules...)
		} else if isWild {
			wildcard = append(wildcard, gr.rules...)
		}
	}
	if specific != nil {
		return specific
	}
	return wildcard
}

// robotsVerdict applies longest-match precedence (Allow wins ties).
// Returns (allowed, matched-disallow-rule-path-for-the-error-message).
func robotsVerdict(rules []robotsRule, path string) (bool, string) {
	bestLen := -1
	allowed := true
	rule := ""
	for _, r := range rules {
		if !matchRobotsPattern(r.path, path) {
			continue
		}
		switch {
		case len(r.path) > bestLen:
			bestLen = len(r.path)
			allowed = r.allow
			rule = r.path
		case len(r.path) == bestLen && r.allow && !allowed:
			allowed = true // Allow wins the tie
		}
	}
	if allowed {
		return true, ""
	}
	return false, rule
}

// matchRobotsPattern matches an RFC 9309 path pattern (`*` = any
// sequence, trailing `$` = end anchor) against a request path.
func matchRobotsPattern(pattern, path string) bool {
	anchored := strings.HasSuffix(pattern, "$")
	if anchored {
		pattern = strings.TrimSuffix(pattern, "$")
	}
	parts := strings.Split(pattern, "*")

	pos := 0
	for i, part := range parts {
		if part == "" {
			continue
		}
		if i == 0 {
			if !strings.HasPrefix(path, part) {
				return false
			}
			pos = len(part)
			continue
		}
		idx := strings.Index(path[pos:], part)
		if idx < 0 {
			return false
		}
		pos += idx + len(part)
	}
	if anchored {
		// A pattern ending in `*$` matches any tail.
		if parts[len(parts)-1] == "" {
			return true
		}
		return pos == len(path)
	}
	return true
}

// politeCheckRedirect re-checks robots on every redirect hop of a
// plain-HTTP fetch in enforce mode (a permitted URL must not smuggle us
// onto a disallowed one via 301). Rate slots are NOT re-reserved per
// hop — redirects are part of the original request's budget.
func (g *politeGate) politeCheckRedirect(req *http.Request, via []*http.Request) error {
	if len(via) >= 10 {
		return fmt.Errorf("politeness: stopped after 10 redirects")
	}
	if req.URL.Scheme != "http" && req.URL.Scheme != "https" {
		return fmt.Errorf("politeness: redirect to non-http(s) URL %q", req.URL)
	}
	// interval only matters if the hop's host needs a fresh robots.txt.
	return g.robotsAllow(req.Context(), req.URL, effectiveInterval(0))
}
