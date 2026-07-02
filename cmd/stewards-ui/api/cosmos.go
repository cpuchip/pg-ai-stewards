// cosmos.go — the CROSS-SERVICE ("cosmos") view backing the Stewdio World
// panel's cosmos mode. Where world_graph(slug) shows ONE world's entity graph,
// this shows the whole constellation: each world (service) is a node, each
// stewards.cross_world_edges row a link, and the worlds cluster into GALAXIES —
// Louvain communities that read as candidate platforms (tightly-coupled service
// groups you could pull out together). The galaxy/modularity math is ported
// faithfully from lodestar's internal/gravity (deterministic, no LLM): sorted
// iteration throughout so the grouping is stable across runs.
//
// GET /api/world/cosmos?project=<slug>   (empty or "all" = the whole universe)

package api

import (
	"context"
	"net/http"
	"sort"
	"strings"
	"time"
)

// cwProtocolWeight — how heavily each protocol binds two services. A shared DB
// couples far harder than one HTTP call; pub-sub is looser (decoupled by
// design). Ported verbatim from lodestar/internal/gravity.protocolWeight — the
// gravity constants that drive the community detection.
var cwProtocolWeight = map[string]float64{
	"http": 1.0, "grpc": 1.0, "pubsub": 0.5,
	"schema": 2.0, "db": 3.0, "config": 1.5, "package": 1.5,
	// k8s: a declared deploy-time service dependency (Helm values ref) — a direct
	// runtime bind, on par with a shared schema. Kept in sync with lodestar/gravity.
	"k8s": 2.0,
}

func cwWeightOf(protocol string) float64 {
	if w, ok := cwProtocolWeight[protocol]; ok {
		return w
	}
	return 1.0
}

// cosmosEdge — one displayed world→world link (deduped per protocol+contract).
type cosmosEdge struct {
	From        string  `json:"from"`
	To          string  `json:"to"`
	Protocol    string  `json:"protocol"`
	ContractKey string  `json:"contract_key"`
	Confidence  float64 `json:"confidence"`
}

// cosmosWorld — one service node. label = slug without the "project/" prefix.
type cosmosWorld struct {
	Slug    string  `json:"slug"`
	Label   string  `json:"label"`
	Project string  `json:"project"`
	Mass    float64 `json:"mass"`
}

type cosmosResp struct {
	Worlds     []cosmosWorld `json:"worlds"`
	Edges      []cosmosEdge  `json:"edges"`
	Galaxies   [][]string    `json:"galaxies"` // Louvain communities, largest first
	Modularity float64       `json:"modularity"`
	BlackHole  bool          `json:"black_hole"`
}

// cosmosLabel strips the project scope from a "project/world" slug so the node
// shows just the service name. Falls back to the last path segment, then the
// whole slug (a contract/synthetic world with no slash keeps its slug).
func cosmosLabel(slug, project string) string {
	if project != "" && strings.HasPrefix(slug, project+"/") {
		return slug[len(project)+1:]
	}
	if i := strings.LastIndexByte(slug, '/'); i >= 0 {
		return slug[i+1:]
	}
	return slug
}

// worldCosmosHandler — the cross-service graph for a project (or the whole
// universe). Joins cross_world_edges → entities → worlds, dedups to world→world
// links, then computes mass + galaxies + modularity in Go. Mirrors
// worldGraphHandler's shape (context timeout, writeErr/writeJSON).
func (d *Deps) worldCosmosHandler(w http.ResponseWriter, r *http.Request) {
	ctx, cancel := context.WithTimeout(r.Context(), 12*time.Second)
	defer cancel()

	project := strings.TrimSpace(r.URL.Query().Get("project"))
	if project == "all" {
		project = ""
	}
	// include_docs=1 widens beyond the deterministic code-graph: ALSO show
	// non-lodestar cross-world edges — e.g. doc-world ↔ code-world links (a market
	// taxonomy entity resolved to the service it touches). This is how a research
	// corpus (a market world) appears in the same constellation as the services it
	// describes. Default OFF so the service-to-service view stays clean.
	includeDocs := r.URL.Query().Get("include_docs") == "1"

	// evidence='lodestar' = the deterministic code-graph cross-service edges
	// (entity↔entity across worlds). The HTTP resolver's produces/consumes edges
	// hub through synthetic "<root>-contracts" worlds; excluding them keeps the
	// default view service-to-service. include_docs widens to every evidence
	// EXCEPT those synthetic contract hubs.
	rows, err := d.Pool.Query(ctx, `
		SELECT ws.slug, coalesce(ws.project,''),
		       wd.slug, coalesce(wd.project,''),
		       coalesce(ce.protocol,''), coalesce(ce.contract_key,''),
		       coalesce(ce.confidence, 0)::float8
		  FROM stewards.cross_world_edges ce
		  JOIN stewards.world_entities se ON se.entity_id = ce.src_entity
		  JOIN stewards.world_entities de ON de.entity_id = ce.dst_entity
		  JOIN stewards.worlds ws ON ws.world_id = se.world_id
		  JOIN stewards.worlds wd ON wd.world_id = de.world_id
		 WHERE (ce.evidence = 'lodestar'
		        OR ($2 AND ws.slug NOT LIKE '%-contracts' AND wd.slug NOT LIKE '%-contracts'))
		   AND ws.world_id <> wd.world_id
		   AND ($1 = '' OR (ws.project = $1 AND wd.project = $1))`,
		project, includeDocs)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}
	defer rows.Close()

	projectOf := map[string]string{} // world slug → its project (for label + node badge)
	seenEdge := map[string]bool{}    // dedup display edges on from|to|protocol|key
	var edges []cosmosEdge
	for rows.Next() {
		var fromSlug, fromProj, toSlug, toProj, protocol, key string
		var conf float64
		if err := rows.Scan(&fromSlug, &fromProj, &toSlug, &toProj, &protocol, &key, &conf); err != nil {
			continue
		}
		projectOf[fromSlug] = fromProj
		projectOf[toSlug] = toProj
		ek := fromSlug + "\x00" + toSlug + "\x00" + protocol + "\x00" + key
		if seenEdge[ek] {
			continue
		}
		seenEdge[ek] = true
		edges = append(edges, cosmosEdge{From: fromSlug, To: toSlug, Protocol: protocol, ContractKey: key, Confidence: conf})
	}
	if err := rows.Err(); err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}

	// deterministic ordering — sorted worlds + sorted edges so the whole payload
	// (and the galaxy grouping computed from it) is stable run-to-run.
	worlds := make([]string, 0, len(projectOf))
	for s := range projectOf {
		worlds = append(worlds, s)
	}
	sort.Strings(worlds)
	sort.SliceStable(edges, func(i, j int) bool {
		if edges[i].From != edges[j].From {
			return edges[i].From < edges[j].From
		}
		if edges[i].To != edges[j].To {
			return edges[i].To < edges[j].To
		}
		if edges[i].Protocol != edges[j].Protocol {
			return edges[i].Protocol < edges[j].Protocol
		}
		return edges[i].ContractKey < edges[j].ContractKey
	})

	galaxies, modularity, blackHole, mass := cosmosCompute(worlds, edges)

	out := cosmosResp{
		Worlds:     make([]cosmosWorld, 0, len(worlds)),
		Edges:      edges,
		Galaxies:   galaxies,
		Modularity: modularity,
		BlackHole:  blackHole,
	}
	if out.Edges == nil {
		out.Edges = []cosmosEdge{}
	}
	if out.Galaxies == nil {
		out.Galaxies = [][]string{}
	}
	for _, s := range worlds {
		out.Worlds = append(out.Worlds, cosmosWorld{
			Slug:    s,
			Label:   cosmosLabel(s, projectOf[s]),
			Project: projectOf[s],
			Mass:    mass[s],
		})
	}
	// heaviest services first (tie → slug) so the node list reads like the masses.
	sort.SliceStable(out.Worlds, func(i, j int) bool {
		if out.Worlds[i].Mass != out.Worlds[j].Mass {
			return out.Worlds[i].Mass > out.Worlds[j].Mass
		}
		return out.Worlds[i].Slug < out.Worlds[j].Slug
	})

	writeJSON(w, http.StatusOK, out)
}

// cosmosCompute turns the world→world edge set into the gravity report: each
// world's mass (weighted degree), the galaxies (Louvain communities), the
// partition's modularity, and whether the system has collapsed into a "black
// hole" (dense yet structureless — a distributed monolith). Pure + deterministic
// so it is unit-testable without a DB. Physics is undirected: a world-pair's
// coupling is counted once per distinct protocol+contract, symmetric.
func cosmosCompute(worlds []string, edges []cosmosEdge) (galaxies [][]string, modularity float64, blackHole bool, mass map[string]float64) {
	adj := map[string]map[string]float64{}
	add := func(a, b string, wt float64) {
		if a == b {
			return
		}
		if adj[a] == nil {
			adj[a] = map[string]float64{}
		}
		adj[a][b] += wt
	}
	seen := map[string]bool{} // canonical (unordered pair, protocol, key) → counted once
	for _, e := range edges {
		if e.From == e.To {
			continue
		}
		a, b := e.From, e.To
		if a > b {
			a, b = b, a
		}
		k := a + "\x00" + b + "\x00" + e.Protocol + "\x00" + e.ContractKey
		if seen[k] {
			continue
		}
		seen[k] = true
		wt := cwWeightOf(e.Protocol)
		add(e.From, e.To, wt)
		add(e.To, e.From, wt)
	}

	// world mass = weighted degree; twoM = 2·(total edge weight).
	deg := map[string]float64{}
	var twoM float64
	for a, nbrs := range adj {
		for _, wt := range nbrs {
			deg[a] += wt
			twoM += wt
		}
	}

	comm := cwDetectCommunities(worlds, adj, deg, twoM)
	modularity = cwRound4(cwModularity(adj, deg, twoM, comm))
	galaxies = cwGalaxies(comm)

	// density = bound pairs / possible pairs, over the full world set.
	pairEdges := 0
	for a, nbrs := range adj {
		for b := range nbrs {
			if a < b {
				pairEdges++
			}
		}
	}
	n := len(worlds)
	possible := n * (n - 1) / 2
	density := 0.0
	if possible > 0 {
		density = float64(pairEdges) / float64(possible)
	}
	// several worlds, densely bound, yet no community structure → nothing separates.
	blackHole = n >= 4 && density >= 0.5 && modularity < 0.2

	return galaxies, modularity, blackHole, deg
}

// cwDetectCommunities runs Louvain local-moving: each world starts alone, then
// is moved to the neighbour community that most increases modularity — and only
// if that beats staying alone. The modularity-gain test won't avalanche two
// tight clusters into one across a single weak bridge. Deterministic: worlds in
// sorted order, ties → lowest community label. Ported from lodestar gravity.
func cwDetectCommunities(worlds []string, adj map[string]map[string]float64, deg map[string]float64, twoM float64) map[string]string {
	comm := map[string]string{}
	for _, w := range worlds {
		comm[w] = w
	}
	if twoM == 0 {
		return comm
	}
	sigmaTot := map[string]float64{} // total degree currently in each community
	for _, w := range worlds {
		sigmaTot[w] = deg[w]
	}
	for iter := 0; iter < 100; iter++ {
		changed := false
		for _, i := range worlds {
			ci := comm[i]
			sigmaTot[ci] -= deg[i] // tentatively remove i from its community

			kIn := map[string]float64{} // weight from i into each community
			for nbr, wt := range adj[i] {
				kIn[comm[nbr]] += wt
			}
			// gain(C) = k_i_in(C) - sigmaTot(C)*deg_i/2m; staying alone = 0.
			best, bestGain := i, 0.0
			cands := []string{ci}
			for c := range kIn {
				cands = append(cands, c)
			}
			sort.Strings(cands)
			for _, c := range cands {
				gain := kIn[c] - sigmaTot[c]*deg[i]/twoM
				if gain > bestGain || (gain == bestGain && c < best) {
					best, bestGain = c, gain
				}
			}
			sigmaTot[best] += deg[i]
			if best != ci {
				comm[i] = best
				changed = true
			}
		}
		if !changed {
			break
		}
	}
	return comm
}

// cwModularity is weighted Newman modularity Q for the partition.
// Q = Σ_c [ L_c/m - (D_c/2m)^2 ], with m = total edge weight = twoM/2.
func cwModularity(adj map[string]map[string]float64, deg map[string]float64, twoM float64, comm map[string]string) float64 {
	if twoM == 0 {
		return 0
	}
	m := twoM / 2
	lIn := map[string]float64{}  // internal weight per community (undirected, once)
	dTot := map[string]float64{} // total degree per community
	for a, nbrs := range adj {
		dTot[comm[a]] += deg[a]
		for b, wt := range nbrs {
			if comm[a] == comm[b] && a < b {
				lIn[comm[a]] += wt
			}
		}
	}
	var q float64
	for _, l := range lIn {
		q += l / m
	}
	for _, d := range dTot {
		frac := d / twoM
		q -= frac * frac
	}
	return q
}

// cwGalaxies groups the community map into member lists, each sorted, largest
// galaxy first (tie → first member). These are the candidate platforms.
func cwGalaxies(comm map[string]string) [][]string {
	groups := map[string][]string{}
	for wld, c := range comm {
		groups[c] = append(groups[c], wld)
	}
	out := make([][]string, 0, len(groups))
	for _, members := range groups {
		sort.Strings(members)
		out = append(out, members)
	}
	sort.SliceStable(out, func(i, j int) bool {
		if len(out[i]) != len(out[j]) {
			return len(out[i]) > len(out[j])
		}
		return out[i][0] < out[j][0]
	})
	return out
}

func cwRound4(f float64) float64 {
	return float64(int(f*10000+0.5)) / 10000
}
