// Shared helpers for reading a work item's `stage_results` in the UI.
//
// A pipeline stage stores its result as `{ model, output, tokens_in,
// tokens_out, completed_at, finish_reason }` (see 04-work-items.sql
// work_item_dispatch_stage). `output` is markdown authored by the stage's
// model. The raw object rendered as escaped JSON is unreadable (visible \n / \"
// and unrendered markdown) — so both the work-item detail view and the Stewdio
// artifact panel normalise it through here.

export type StageResult = {
  name: string
  model?: string
  /** markdown body to render. When a stage has no `output` string we fall back
   *  to a fenced json block so the single render path still shows something. */
  output: string
  /** true when `output` came from the stage's own `output` field (real prose),
   *  false when we synthesised a json fallback. */
  hasOutput: boolean
  tokens_in?: number
  tokens_out?: number
  completed_at?: string
  finish_reason?: string
}

function asRecord(v: unknown): Record<string, unknown> | null {
  return v && typeof v === 'object' && !Array.isArray(v) ? (v as Record<string, unknown>) : null
}

/** Normalise `stage_results` (an object keyed by stage name) into an ordered
 *  list. Ordered by `completed_at` when present (pipeline order — gather →
 *  build → critique), else the object's own key order. */
export function parseStageResults(stageResults: unknown): StageResult[] {
  const rec = asRecord(stageResults)
  if (!rec) return []
  const out: StageResult[] = []
  for (const [name, raw] of Object.entries(rec)) {
    const r = asRecord(raw)
    if (r && typeof r.output === 'string') {
      out.push({
        name,
        model: typeof r.model === 'string' ? r.model : undefined,
        output: r.output,
        hasOutput: true,
        tokens_in: typeof r.tokens_in === 'number' ? r.tokens_in : undefined,
        tokens_out: typeof r.tokens_out === 'number' ? r.tokens_out : undefined,
        completed_at: typeof r.completed_at === 'string' ? r.completed_at : undefined,
        finish_reason: typeof r.finish_reason === 'string' ? r.finish_reason : undefined,
      })
    } else if (typeof raw === 'string') {
      out.push({ name, output: raw, hasOutput: true })
    } else {
      // no prose output — keep the object visible as a code block so nothing is lost
      out.push({
        name,
        output: '```json\n' + JSON.stringify(raw, null, 2) + '\n```',
        hasOutput: false,
        model: r && typeof r.model === 'string' ? r.model : undefined,
        completed_at: r && typeof r.completed_at === 'string' ? r.completed_at : undefined,
      })
    }
  }
  out.sort((a, b) => {
    if (a.completed_at && b.completed_at) return a.completed_at.localeCompare(b.completed_at)
    if (a.completed_at) return -1
    if (b.completed_at) return 1
    return 0
  })
  return out
}

// A finalized doc is announced in a stage's JOURNAL prose as: "…pooled as
// `some-slug-<hash>`." (see 34-doc-builder.sql doc_finalize_tool). There is no
// docs→work_item foreign key, and the pooled doc's own `session` frontmatter
// does not always trace back to the dispatching work item (a doc built in a
// separate agent session and merely referenced by the run carries that
// session, not `wi--<uuid8>`). So the reliable tie for THIS run is the text
// mention. Precision over recall: require the word "pool" and a backticked,
// hyphenated slug so we never surface a stray token (e.g. a `draft-handle`).
const POOLED_RE = /\bpool(?:ed|ing)?\b[^`\n]{0,80}`([a-z0-9][a-z0-9._-]*-[a-z0-9._-]+)`/gi

/** Doc slugs a run pooled, scraped from its stage outputs. Deduped, order-preserved. */
export function extractPooledSlugs(stageResults: unknown): string[] {
  const stages = parseStageResults(stageResults)
  const seen = new Set<string>()
  const slugs: string[] = []
  for (const s of stages) {
    POOLED_RE.lastIndex = 0
    let m: RegExpExecArray | null
    while ((m = POOLED_RE.exec(s.output)) !== null) {
      const slug = m[1]
      if (slug && !seen.has(slug)) {
        seen.add(slug)
        slugs.push(slug)
      }
    }
  }
  return slugs
}
