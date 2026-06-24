// Arc A — make links in rendered markdown work, in both the chat bubbles and the
// doc viewer. External URLs open in a new tab; internal references navigate
// within the cockpit (select that doc / work item, which drives the artifact +
// chat panels). One handler, shared by ChatPanel and ArtifactPanel.
import type { useStewdioStore } from '../../stores/stewdio'

type Store = ReturnType<typeof useStewdioStore>

// An internal link is written as `doc:<slug>`, `wi:<id>` / `work_item:<id>`, or a
// bare relative token (no scheme, no slash) — treated as a doc slug. Anything
// with http(s)/mailto/tel is external.
export function makeLinkClick(store: Store) {
  return (e: MouseEvent) => {
    const a = (e.target as HTMLElement)?.closest?.('a')
    if (!a) return
    const href = (a.getAttribute('href') || '').trim()
    if (!href || href.startsWith('#')) return

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
    // a bare token (no slash, no dot-path) → a doc slug; otherwise leave it alone
    else if (href.includes('/') || href.includes('.')) { return }

    ref = ref.trim()
    if (!ref) return
    e.preventDefault()
    store.select(ref, kind, ref)
  }
}
