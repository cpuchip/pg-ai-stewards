package api

import (
	"reflect"
	"testing"
)

// httpEdge is a convenience for an undirected http coupling between two worlds.
func httpEdge(a, b string) cosmosEdge {
	return cosmosEdge{From: a, To: b, Protocol: "http", ContractKey: ""}
}

// TestCosmosComputeTwoGalaxies — two tight triangles joined by a single weak
// bridge must resolve to two galaxies (the modularity-gain test must not
// avalanche them across the bridge), with the heavier bridge nodes carrying more
// mass. This is the core "candidate platform" clustering the panel visualizes.
func TestCosmosComputeTwoGalaxies(t *testing.T) {
	worlds := []string{"a", "b", "c", "d", "e", "f"}
	edges := []cosmosEdge{
		httpEdge("a", "b"), httpEdge("b", "c"), httpEdge("a", "c"), // cluster 1
		httpEdge("d", "e"), httpEdge("e", "f"), httpEdge("d", "f"), // cluster 2
		httpEdge("c", "d"), // the single bridge
	}

	galaxies, modularity, blackHole, mass := cosmosCompute(worlds, edges)

	if len(galaxies) != 2 {
		t.Fatalf("expected 2 galaxies, got %d: %v", len(galaxies), galaxies)
	}
	// largest-first, tie broken by first member → [{a,b,c},{d,e,f}].
	want := [][]string{{"a", "b", "c"}, {"d", "e", "f"}}
	if !reflect.DeepEqual(galaxies, want) {
		t.Fatalf("galaxies = %v, want %v", galaxies, want)
	}
	if modularity <= 0 {
		t.Fatalf("expected positive modularity for clustered graph, got %v", modularity)
	}
	if blackHole {
		t.Fatalf("clustered graph must not be flagged a black hole")
	}
	// bridge endpoints (degree 3) outweigh the leaves (degree 2).
	if mass["c"] <= mass["a"] {
		t.Fatalf("bridge node c (mass %v) should outweigh leaf a (mass %v)", mass["c"], mass["a"])
	}
	if mass["a"] != 2 || mass["c"] != 3 {
		t.Fatalf("unexpected masses: a=%v c=%v (want 2, 3)", mass["a"], mass["c"])
	}
}

// TestCosmosComputeBlackHole — a fully-connected clique of services (everything
// calls everything) is a distributed monolith: dense, no community structure.
// It must collapse to one galaxy and raise the black_hole flag.
func TestCosmosComputeBlackHole(t *testing.T) {
	worlds := []string{"w", "x", "y", "z"}
	edges := []cosmosEdge{
		httpEdge("w", "x"), httpEdge("w", "y"), httpEdge("w", "z"),
		httpEdge("x", "y"), httpEdge("x", "z"), httpEdge("y", "z"),
	}

	galaxies, modularity, blackHole, _ := cosmosCompute(worlds, edges)

	if len(galaxies) != 1 {
		t.Fatalf("expected a single galaxy for the clique, got %d: %v", len(galaxies), galaxies)
	}
	if !blackHole {
		t.Fatalf("a dense structureless clique should be flagged a black hole (modularity=%v)", modularity)
	}
}

// TestCosmosLabel — the node label strips the project scope from a project/world
// slug, falls back to the last segment, then the raw slug.
func TestCosmosLabel(t *testing.T) {
	cases := []struct{ slug, project, want string }{
		{"otel-demo/frontend", "otel-demo", "frontend"},
		{"otel-demo/checkout", "", "checkout"},                      // no project → last segment
		{"otel-demo-contracts", "otel-demo", "otel-demo-contracts"}, // no slash → raw
	}
	for _, c := range cases {
		if got := cosmosLabel(c.slug, c.project); got != c.want {
			t.Errorf("cosmosLabel(%q,%q) = %q, want %q", c.slug, c.project, got, c.want)
		}
	}
}
