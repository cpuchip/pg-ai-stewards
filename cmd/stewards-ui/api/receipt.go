// The Receipt — GET /api/work-items/receipt.
//
// War-game 2026-07-07, converged finding #2: the gate's SUBSTANCE (sessions,
// steward_actions, gate_decisions, cost_events, hinge verdicts) exceeds what
// a reviewer needs, but its PRESENTATION is an operator's audit log. The
// receipt is the reviewer-shaped distillation — three plain questions, one
// round trip:
//
//   What was read   — derived from the ledger's tool-call records across the
//                     item's sessions (doc opens, searches, URL fetches) plus
//                     the citations its produced docs carry. HONESTY: this is
//                     what the agent FETCHED, not necessarily what it used;
//                     when the ledger holds no tool calls we say so instead
//                     of fabricating a source list (notes[] carries why).
//   What changed    — docs created/updated by this item (docs.work_item_id,
//                     the real provenance stamp) + the file materialization.
//   What needs you  — stewards.needs_attention rows tied to this item (the
//                     89-attention union: gate/ask/hinge/a2a_question/review).
//
// Empty sections return empty arrays, never vanish — the receipt's value is
// that it always answers the same three questions.

package api

import (
	"context"
	"encoding/json"
	"net/http"
	"sort"
	"strings"
	"time"
)

type receiptDocRead struct {
	Slug  string `json:"slug"`
	Times int    `json:"times"`
}

type receiptSearch struct {
	Query string `json:"query"`
	Times int    `json:"times"`
}

type receiptURL struct {
	URL   string `json:"url"`
	Times int    `json:"times"`
}

type receiptToolTally struct {
	Tool  string `json:"tool"`
	Count int    `json:"count"`
}

type receiptCitation struct {
	DocSlug string `json:"doc_slug"` // the produced doc doing the citing
	Ref     string `json:"ref"`      // what it cites (relative path or URL)
	Count   int    `json:"count"`
}

type receiptRead struct {
	SessionCount   int                `json:"session_count"`
	ToolCallCount  int                `json:"tool_call_count"`
	DocsOpened     []receiptDocRead   `json:"docs_opened"`
	SearchesRun    []receiptSearch    `json:"searches_run"`
	URLsFetched    []receiptURL       `json:"urls_fetched"`
	OtherTools     []receiptToolTally `json:"other_tools"`
	CitedByOutputs []receiptCitation  `json:"cited_by_outputs"`
}

type receiptChangedDoc struct {
	Slug  string     `json:"slug"`
	Title string     `json:"title,omitempty"`
	Kind  string     `json:"kind,omitempty"`
	Verb  string     `json:"verb"` // created | updated
	At    *time.Time `json:"at,omitempty"`
}

type receiptChanged struct {
	Docs            []receiptChangedDoc `json:"docs"`
	FileDestination string              `json:"file_destination,omitempty"`
	FileEnqueuedAt  *time.Time          `json:"file_enqueued_at,omitempty"`
}

type receiptNeed struct {
	Kind      string     `json:"kind"` // needs_attention.source_kind
	ID        string     `json:"id"`   // needs_attention.source_id
	Title     string     `json:"title"`
	Question  string     `json:"question,omitempty"`
	CreatedAt *time.Time `json:"created_at,omitempty"`
}

type receiptResp struct {
	WorkItemID string         `json:"work_item_id"`
	Slug       string         `json:"slug"`
	Status     string         `json:"status"`
	Read       receiptRead    `json:"read"`
	Changed    receiptChanged `json:"changed"`
	NeedsYou   []receiptNeed  `json:"needs_you"`
	// Ledger-fidelity honesty labels — why a section is thinner than the
	// work actually was ("sessions recorded no tool calls", …). Rendered
	// verbatim by the panel; never fabricated sources.
	Notes []string `json:"notes,omitempty"`
}

// openAI-shape tool call as stored verbatim in stewards.messages.tool_calls.
type storedToolCall struct {
	Function struct {
		Name      string `json:"name"`
		Arguments string `json:"arguments"`
	} `json:"function"`
}

func (d *Deps) workItemsReceiptHandler(w http.ResponseWriter, r *http.Request) {
	ctx, cancel := context.WithTimeout(r.Context(), 10*time.Second)
	defer cancel()

	id := r.URL.Query().Get("id")
	if id == "" {
		writeErr(w, http.StatusBadRequest, "id query param required")
		return
	}

	resp := receiptResp{
		Read: receiptRead{
			DocsOpened:     []receiptDocRead{},
			SearchesRun:    []receiptSearch{},
			URLsFetched:    []receiptURL{},
			OtherTools:     []receiptToolTally{},
			CitedByOutputs: []receiptCitation{},
		},
		Changed:  receiptChanged{Docs: []receiptChangedDoc{}},
		NeedsYou: []receiptNeed{},
	}

	// 1. The work item core — sessions + file materialization + created_at
	//    (the created/updated watermark for produced docs).
	var (
		sessionIDs []string
		wiCreated  time.Time
	)
	err := d.Pool.QueryRow(ctx,
		`SELECT id::text, coalesce(slug, ''), status,
		        coalesce(session_ids, ARRAY[]::text[]),
		        created_at,
		        coalesce(file_destination, ''), file_enqueued_at
		   FROM stewards.work_items
		  WHERE id = $1::uuid`,
		id,
	).Scan(&resp.WorkItemID, &resp.Slug, &resp.Status,
		&sessionIDs, &wiCreated,
		&resp.Changed.FileDestination, &resp.Changed.FileEnqueuedAt)
	if err != nil {
		writeErr(w, http.StatusNotFound, "work_item not found: "+err.Error())
		return
	}
	resp.Read.SessionCount = len(sessionIDs)

	// 2. What was read — every tool call the item's sessions recorded.
	//    Classification happens here in Go (the arguments field is a JSON
	//    string inside jsonb; parsing it in SQL would RAISE on any model
	//    that emitted malformed arguments).
	if len(sessionIDs) > 0 {
		rows, qerr := d.Pool.Query(ctx,
			`SELECT m.tool_calls
			   FROM stewards.messages m
			  WHERE m.session_id = ANY($1)
			    AND m.role = 'assistant'
			    AND m.tool_calls IS NOT NULL
			  ORDER BY m.id`,
			sessionIDs,
		)
		if qerr == nil {
			docReads := map[string]int{}
			searches := map[string]int{}
			urls := map[string]int{}
			other := map[string]int{}
			defer rows.Close()
			for rows.Next() {
				var raw []byte
				if err := rows.Scan(&raw); err != nil {
					continue
				}
				var calls []storedToolCall
				if err := json.Unmarshal(raw, &calls); err != nil {
					continue // not an array / unexpected shape — skip, never guess
				}
				for _, c := range calls {
					name := c.Function.Name
					if name == "" {
						continue
					}
					resp.Read.ToolCallCount++
					var args map[string]any
					_ = json.Unmarshal([]byte(c.Function.Arguments), &args)
					switch classifyReadTool(name) {
					case "doc":
						if slug := argString(args, "slug"); slug != "" {
							docReads[slug]++
						} else {
							other[name]++
						}
					case "search":
						if q := firstArgString(args, "query", "q"); q != "" {
							searches[q]++
						} else {
							other[name]++
						}
					case "url":
						if u := argString(args, "url"); u != "" {
							urls[u]++
						} else {
							other[name]++
						}
					default:
						other[name]++
					}
				}
			}
			for s, n := range docReads {
				resp.Read.DocsOpened = append(resp.Read.DocsOpened, receiptDocRead{Slug: s, Times: n})
			}
			for q, n := range searches {
				resp.Read.SearchesRun = append(resp.Read.SearchesRun, receiptSearch{Query: q, Times: n})
			}
			for u, n := range urls {
				resp.Read.URLsFetched = append(resp.Read.URLsFetched, receiptURL{URL: u, Times: n})
			}
			for t, n := range other {
				resp.Read.OtherTools = append(resp.Read.OtherTools, receiptToolTally{Tool: t, Count: n})
			}
			sort.Slice(resp.Read.DocsOpened, func(i, j int) bool { return resp.Read.DocsOpened[i].Slug < resp.Read.DocsOpened[j].Slug })
			sort.Slice(resp.Read.SearchesRun, func(i, j int) bool { return resp.Read.SearchesRun[i].Query < resp.Read.SearchesRun[j].Query })
			sort.Slice(resp.Read.URLsFetched, func(i, j int) bool { return resp.Read.URLsFetched[i].URL < resp.Read.URLsFetched[j].URL })
			sort.Slice(resp.Read.OtherTools, func(i, j int) bool {
				if resp.Read.OtherTools[i].Count != resp.Read.OtherTools[j].Count {
					return resp.Read.OtherTools[i].Count > resp.Read.OtherTools[j].Count
				}
				return resp.Read.OtherTools[i].Tool < resp.Read.OtherTools[j].Tool
			})
		} else {
			resp.Notes = append(resp.Notes, "The session message log could not be read: "+qerr.Error())
		}
		if resp.Read.ToolCallCount == 0 {
			resp.Notes = append(resp.Notes,
				"This item's sessions recorded no tool calls in the ledger, so what was read cannot be reconstructed from them.")
		}
	} else {
		resp.Notes = append(resp.Notes,
			"No sessions are linked to this item yet — nothing to derive reads from.")
	}

	// 3. What changed — docs stamped with this item's id (doc_finalize's
	//    provenance link). verb: created if the doc was born during this
	//    item's lifetime, updated if the item re-stamped an older doc.
	docRows, err := d.Pool.Query(ctx,
		`SELECT slug, coalesce(title, ''), coalesce(kind, ''),
		        (created_at >= $2::timestamptz) AS created_by_item,
		        updated_at
		   FROM stewards.docs
		  WHERE work_item_id = $1::uuid
		  ORDER BY updated_at DESC`,
		id, wiCreated,
	)
	if err == nil {
		defer docRows.Close()
		for docRows.Next() {
			var (
				cd      receiptChangedDoc
				created bool
			)
			if err := docRows.Scan(&cd.Slug, &cd.Title, &cd.Kind, &created, &cd.At); err == nil {
				cd.Verb = "updated"
				if created {
					cd.Verb = "created"
				}
				resp.Changed.Docs = append(resp.Changed.Docs, cd)
			}
		}
	} else {
		resp.Notes = append(resp.Notes, "Produced docs could not be read: "+err.Error())
	}

	// What-was-read, part 2: the citations the produced docs actually carry
	// (CITES edges from the relational graph — stewards.doc_citations).
	// These are the sources the OUTPUT claims, which is a different (and
	// complementary) fidelity than the tool-call fetches above.
	if len(resp.Changed.Docs) > 0 {
		citRows, cerr := d.Pool.Query(ctx,
			`SELECT d.slug, c.cited_uri, c.citation_count
			   FROM stewards.docs d
			  CROSS JOIN LATERAL stewards.doc_citations(d.slug) c
			  WHERE d.work_item_id = $1::uuid
			  LIMIT 100`,
			id,
		)
		if cerr == nil {
			defer citRows.Close()
			for citRows.Next() {
				var c receiptCitation
				if err := citRows.Scan(&c.DocSlug, &c.Ref, &c.Count); err == nil {
					resp.Read.CitedByOutputs = append(resp.Read.CitedByOutputs, c)
				}
			}
		}
	}

	// 4. What needs you — the unified human-blocking view, scoped to this
	//    item. Gate holds, hinge reviews, blocking A2A questions, paused
	//    stages: one shape (89-attention).
	needRows, err := d.Pool.Query(ctx,
		`SELECT source_kind, source_id, title, coalesce(question, ''), created_at
		   FROM stewards.needs_attention
		  WHERE work_item_id = $1::uuid
		  ORDER BY created_at`,
		id,
	)
	if err == nil {
		defer needRows.Close()
		for needRows.Next() {
			var n receiptNeed
			if err := needRows.Scan(&n.Kind, &n.ID, &n.Title, &n.Question, &n.CreatedAt); err == nil {
				resp.NeedsYou = append(resp.NeedsYou, n)
			}
		}
	} else {
		resp.Notes = append(resp.Notes, "The needs-attention view could not be read: "+err.Error())
	}

	writeJSON(w, http.StatusOK, resp)
}

// classifyReadTool buckets a recorded tool name into the receipt's read
// shapes. Matching is substring-based so mcp-prefixed or suffixed variants
// (doc_get vs stewards_doc_get) still classify; anything unrecognized lands
// in the OtherTools tally — shown, not hidden.
func classifyReadTool(name string) string {
	n := strings.ToLower(name)
	switch {
	case strings.Contains(n, "doc_get"),
		strings.Contains(n, "investigate_doc"),
		strings.Contains(n, "summarize_doc"),
		strings.Contains(n, "read_corpus_parents"):
		return "doc"
	case strings.Contains(n, "search"):
		return "search"
	case strings.Contains(n, "url"), strings.Contains(n, "fetch"):
		return "url"
	default:
		return "other"
	}
}

func argString(args map[string]any, key string) string {
	if args == nil {
		return ""
	}
	if v, ok := args[key].(string); ok {
		return strings.TrimSpace(v)
	}
	return ""
}

func firstArgString(args map[string]any, keys ...string) string {
	for _, k := range keys {
		if v := argString(args, k); v != "" {
			return v
		}
	}
	return ""
}
