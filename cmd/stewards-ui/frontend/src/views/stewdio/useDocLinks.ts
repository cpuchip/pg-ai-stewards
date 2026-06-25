// Arc A — make links in rendered markdown work, in both the chat bubbles and the
// doc viewer. External URLs open in a new tab; internal references navigate
// within the cockpit (select that doc / work item, which drives the artifact +
// chat panels). One handler, shared by ChatPanel and ArtifactPanel.
import type { useStewdioStore } from '../../stores/stewdio'

type Store = ReturnType<typeof useStewdioStore>

// Links "just work" (O2). Resolution order:
//   #anchor                       → scroll within the rendered doc (intra-doc ref)
//   http(s)/mailto/tel            → open in a new tab (external)
//   doc:<slug>                    → open that doc
//   wi:<id> / work_item:<id> / #<digits> → open that work item
//   <path>/<name>.md  or  <name>.md      → open the doc with that basename slug
//   bare token (no slash/dot)     → open it as a doc slug
// A trailing #anchor on a cross-doc link is dropped (we open the doc; same-doc
// anchors are handled by the first arm).
export function makeLinkClick(store: Store) {
  return (e: MouseEvent) => {
    const a = (e.target as HTMLElement)?.closest?.('a')
    if (!a) return
    const href = (a.getAttribute('href') || '').trim()
    if (!href) return

    // intra-doc anchor → scroll to the heading id within the rendered body.
    if (href.startsWith('#')) {
      const id = decodeURIComponent(href.slice(1))
      // #123 (digits) is a work-item shorthand, not an anchor.
      if (/^\d+$/.test(id)) { e.preventDefault(); store.select(id, 'work_item', id); return }
      e.preventDefault()
      const root = (a.closest('.prose') as Element | null) ?? document
      const target = root.querySelector?.(`#${cssEscape(id)}`) ?? document.getElementById(id)
      target?.scrollIntoView({ behavior: 'smooth', block: 'start' })
      return
    }

    if (/^(https?:)?\/\//i.test(href) || /^(mailto:|tel:)/i.test(href)) {
      e.preventDefault()
      window.open(href, '_blank', 'noopener,noreferrer')
      return
    }

    // internal navigation
    let ref = href
    let kind: 'doc' | 'work_item' = 'doc'
    if (href.startsWith('doc:')) { ref = href.slice(4) }
    else if (href.startsWith('work_item:')) { ref = href.slice(10); kind = 'work_item' }
    else if (href.startsWith('wi:')) { ref = href.slice(3); kind = 'work_item' }
    // a relative markdown doc link (cross-doc hyperlink): take the basename,
    // drop any #anchor and the .md extension → the doc slug.
    else if (/\.md(#.*)?$/i.test(href) || href.includes('/')) {
      const path = href.split('#')[0] ?? href
      ref = path.slice(path.lastIndexOf('/') + 1).replace(/\.md$/i, '')
    }
    // else: a bare token (no slash, no dot) → a doc slug as-is

    ref = ref.trim()
    if (!ref) return
    e.preventDefault()
    store.select(ref, kind, ref)
  }
}

// CSS.escape isn't in every jsdom/test env; fall back to a minimal escaper.
function cssEscape(s: string): string {
  const g = globalThis as unknown as { CSS?: { escape?: (v: string) => string } }
  if (typeof g.CSS?.escape === 'function') return g.CSS.escape(s)
  return s.replace(/[^a-zA-Z0-9_-]/g, (c) => '\\' + c)
}
