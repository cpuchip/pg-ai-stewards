package main

import (
	"context"
	"strings"
	"testing"
	"unicode/utf8"

	"github.com/modelcontextprotocol/go-sdk/mcp"
)

// sampleSeedData is a small, realistic overview: one pool WITH a description
// (the description-over-name case), one pool that is only a bare tag (slug
// fallback), a couple of intents, doc counts, and recent activity.
func sampleSeedData() seedData {
	return seedData{
		KindCounts: []kindCount{{"study", 42}, {"proposal", 8}, {"journal", 30}},
		Pools: []poolSummary{
			{
				Key:         "substrate",
				Name:        "pg-ai-stewards",
				Description: "The pg-ai-stewards OSS substrate: agents, pipelines, and memory",
				Count:       3,
				Titles:      []string{"Seed memory dual-channel overview", "The oracle is the switch"},
			},
			{
				// No matching projects row — only a bare project_association tag.
				Key:    "loose-tag",
				Count:  1,
				Titles: []string{"An untethered note"},
			},
		},
		Intents: []intentSummary{
			{Slug: "study-write", Purpose: "Produce a deep, honest scripture study\nsecond line ignored"},
			{Slug: "doc-construct", Purpose: "Build a document from tool-call diffs"},
		},
		Recent: []recentEntry{
			{Date: "2026-07-13", Kind: "study", Title: "Give away all my sins"},
		},
	}
}

// (c) description-over-name: a pool WITH a description shows the description,
// not just its slug; a pool without one falls back to the slug.
func TestRenderSeedDescriptionOverName(t *testing.T) {
	seed := renderSeed(sampleSeedData())

	const desc = "The pg-ai-stewards OSS substrate: agents, pipelines, and memory"
	if !strings.Contains(seed, desc) {
		t.Errorf("rendered seed missing pool description %q; got:\n%s", desc, seed)
	}
	// The described pool's line must carry the description alongside its key,
	// not the key alone.
	if !strings.Contains(seed, "substrate — "+desc) {
		t.Errorf("described pool did not render 'key — description'; got:\n%s", seed)
	}
	// The bare-tag pool has no description or name, so it renders as its slug
	// with no ' — ' label separator on its header line.
	if strings.Contains(seed, "loose-tag — ") {
		t.Errorf("bare-tag pool should render its slug alone, got a label separator:\n%s", seed)
	}
	if !strings.Contains(seed, "loose-tag (1 doc)") {
		t.Errorf("bare-tag pool header missing/incorrect; got:\n%s", seed)
	}
	// Semantic hooks (doc titles) and the doc-count line are present.
	if !strings.Contains(seed, "Seed memory dual-channel overview") {
		t.Errorf("rendered seed missing a doc-title semantic hook; got:\n%s", seed)
	}
	if !strings.Contains(seed, "42 studies") {
		t.Errorf("rendered seed missing doc-count-by-type line; got:\n%s", seed)
	}
	// firstLine must keep an intent purpose to one line.
	if strings.Contains(seed, "second line ignored") {
		t.Errorf("intent purpose leaked its second line; got:\n%s", seed)
	}
}

// Regression: attachTitles must bind titles to the RIGHT pool by key,
// including the first-built (largest) pools. The live-substrate smoke caught a
// version that stored pointers into the pools slice while still appending to
// it — append reallocated the backing array, so only the last pools kept their
// titles and every large pool rendered "…and N more" with nothing above it.
func TestAttachTitlesBindsEveryPool(t *testing.T) {
	pools := []poolSummary{
		{Key: "star-trek", Count: 114}, // largest, built first — the one that broke
		{Key: "books", Count: 74},
		{Key: "research", Count: 1}, // smallest, built last — worked even when buggy
	}
	titles := map[string][]string{
		"star-trek": {"The Naked Time", "Balance of Terror"},
		"books":     {"Deep Work"},
		"research":  {"A lone note"},
	}
	attachTitles(pools, titles)

	for _, p := range pools {
		if len(p.Titles) == 0 {
			t.Errorf("pool %q got no titles after attach (aliasing regression)", p.Key)
		}
	}
	if len(pools[0].Titles) != 2 || pools[0].Titles[0] != "The Naked Time" {
		t.Errorf("first/largest pool titles = %v, want the star-trek titles", pools[0].Titles)
	}
	// And it renders: the largest pool shows a real title, not just "…and N more".
	seed := renderSeed(seedData{Pools: pools})
	if !strings.Contains(seed, "The Naked Time") {
		t.Errorf("rendered seed missing the largest pool's title; got:\n%s", seed)
	}
}

// (a-cap) the cap holds: an oversized overview is bounded to maxSeedChars
// (rune-counted) and carries the truncation tail.
func TestRenderSeedCapHolds(t *testing.T) {
	// Build a pool with far more than the cap can hold.
	big := poolSummary{Key: "huge", Description: "a big pool", Count: 500}
	for i := 0; i < 500; i++ {
		big.Titles = append(big.Titles,
			"A deliberately long document title used to overflow the seed cap so truncation triggers")
	}
	// Give it plenty of "…and N more" headroom too.
	big.Titles = big.Titles[:maxDocTitlesPerPool] // renderer only shows N per pool anyway
	pools := make([]poolSummary, 0, 60)
	for i := 0; i < 60; i++ {
		p := big
		p.Key = "huge-" + string(rune('a'+i%26)) + strings.Repeat("x", i)
		pools = append(pools, p)
	}
	seed := renderSeed(seedData{Pools: pools})

	if n := utf8.RuneCountInString(seed); n > maxSeedChars {
		t.Fatalf("rendered seed is %d runes, exceeds cap %d", n, maxSeedChars)
	}
	if !strings.HasSuffix(seed, seedTruncTail) {
		t.Errorf("oversized seed missing truncation tail %q; ends with:\n%q",
			seedTruncTail, seed[max(0, len(seed)-80):])
	}
}

// (a) + (b) the real path: build the actual MCP server the way main.go /
// http.go do, connect an in-memory client, and assert BOTH channels carry the
// overview — the initialize `instructions` field (channel 1) and the
// doc_search tool description (channel 2). Registering with a nil pool is safe
// here: handlers close over the pool but are never invoked (we only initialize
// and list tools).
func TestSeedDualChannelInjectionRealPath(t *testing.T) {
	ctx := context.Background()
	seed := renderSeed(sampleSeedData())
	const poolDesc = "The pg-ai-stewards OSS substrate: agents, pipelines, and memory"

	srv := mcp.NewServer(&mcp.Implementation{Name: "pg-ai-stewards", Version: "test"},
		&mcp.ServerOptions{Instructions: seedInstructions(seed)})
	registerDocTools(srv, nil, seed)

	client, server := mcp.NewInMemoryTransports()
	ss, err := srv.Connect(ctx, server, nil)
	if err != nil {
		t.Fatalf("server.Connect: %v", err)
	}
	defer ss.Close()

	c := mcp.NewClient(&mcp.Implementation{Name: "probe", Version: "0"}, nil)
	cs, err := c.Connect(ctx, client, nil)
	if err != nil {
		t.Fatalf("client.Connect: %v", err)
	}
	defer cs.Close()

	// Channel 1 — the initialize instructions carry the overview (and thus at
	// least one pool description). The cap already held in TestRenderSeedCapHolds.
	instr := cs.InitializeResult().Instructions
	if !strings.Contains(instr, "MEMORY OVERVIEW") {
		t.Errorf("initialize instructions missing the overview header; got:\n%s", instr)
	}
	if !strings.Contains(instr, poolDesc) {
		t.Errorf("initialize instructions missing pool description %q; got:\n%s", poolDesc, instr)
	}

	// Channel 2 — the doc_search tool description carries the overview.
	lt, err := cs.ListTools(ctx, nil)
	if err != nil {
		t.Fatalf("ListTools: %v", err)
	}
	var docSearch *mcp.Tool
	for _, tool := range lt.Tools {
		if tool.Name == "doc_search" {
			docSearch = tool
			break
		}
	}
	if docSearch == nil {
		t.Fatal("doc_search tool not found in tools/list")
	}
	if !strings.Contains(docSearch.Description, "CURRENT MEMORY OVERVIEW") {
		t.Errorf("doc_search description missing overview marker; got:\n%s", docSearch.Description)
	}
	if !strings.Contains(docSearch.Description, poolDesc) {
		t.Errorf("doc_search description missing pool description %q; got:\n%s", poolDesc, docSearch.Description)
	}
	// The base description must survive alongside the appended overview.
	if !strings.Contains(docSearch.Description, docSearchBaseDescription) {
		t.Errorf("doc_search description dropped its base text; got:\n%s", docSearch.Description)
	}
}

// The STEWARDS_SEED_MEMORY=false toggle path: an empty seed no-ops BOTH
// channels — instructions empty, doc_search description back to base. This is
// the clean A/B that lets the injection be reversed to prior behavior.
func TestSeedDisabledNoOpsBothChannels(t *testing.T) {
	if got := seedInstructions(""); got != "" {
		t.Errorf("seedInstructions(\"\") = %q, want empty (disabled → no instructions)", got)
	}
	if got := docSearchDescription(""); got != docSearchBaseDescription {
		t.Errorf("docSearchDescription(\"\") = %q, want base description", got)
	}

	ctx := context.Background()
	srv := mcp.NewServer(&mcp.Implementation{Name: "pg-ai-stewards", Version: "test"},
		&mcp.ServerOptions{Instructions: seedInstructions("")})
	registerDocTools(srv, nil, "")

	client, server := mcp.NewInMemoryTransports()
	ss, err := srv.Connect(ctx, server, nil)
	if err != nil {
		t.Fatalf("server.Connect: %v", err)
	}
	defer ss.Close()
	c := mcp.NewClient(&mcp.Implementation{Name: "probe", Version: "0"}, nil)
	cs, err := c.Connect(ctx, client, nil)
	if err != nil {
		t.Fatalf("client.Connect: %v", err)
	}
	defer cs.Close()

	if instr := cs.InitializeResult().Instructions; instr != "" {
		t.Errorf("disabled seed still set instructions: %q", instr)
	}
	lt, err := cs.ListTools(ctx, nil)
	if err != nil {
		t.Fatalf("ListTools: %v", err)
	}
	for _, tool := range lt.Tools {
		if tool.Name == "doc_search" {
			if strings.Contains(tool.Description, "CURRENT MEMORY OVERVIEW") {
				t.Errorf("disabled seed still appended overview to doc_search: %s", tool.Description)
			}
		}
	}
}

// seedMemoryEnabled honors the env toggle.
func TestSeedMemoryEnabledToggle(t *testing.T) {
	cases := map[string]bool{
		"":      true,
		"true":  true,
		"1":     true,
		"yes":   true,
		"false": false,
		"FALSE": false,
		"0":     false,
		"no":    false,
		"off":   false,
	}
	for v, want := range cases {
		t.Setenv("STEWARDS_SEED_MEMORY", v)
		if got := seedMemoryEnabled(); got != want {
			t.Errorf("seedMemoryEnabled() with STEWARDS_SEED_MEMORY=%q = %v, want %v", v, got, want)
		}
	}
}
