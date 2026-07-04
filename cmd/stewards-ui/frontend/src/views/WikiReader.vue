<script setup lang="ts">
// The wiki reader (WIKI-GRAPH mission, item 1) — a wikis switcher + page list
// at /wiki, an individual page view at /wiki/page/:slug (the address every
// wiki-link resolves to), a "Graph" mode over the same route for the
// wiki-scoped live graph (item 2), and a corner Obsidian-style local graph on
// each page view (item 3). Follows the doc-theme convention (style.css) and
// the existing mode-toggle idiom (WorldGraphPanel's World/Cosmos switch)
// rather than inventing new UI language.
//
// Everything here degrades cleanly when WIKI-CORE (92)'s schema hasn't landed
// — see api/wiki.go's contract note — via the `available` flag every
// endpoint returns.
import { ref, computed, watch, onMounted } from 'vue'
import { useRoute, useRouter } from 'vue-router'
import MarkdownIt from 'markdown-it'
import { api, type WikiBrief, type WikiPageBrief, type WikiPageDetail } from '@/api'
import WikiGraphPanel from './wiki/WikiGraphPanel.vue'
import WikiLocalGraph from './wiki/WikiLocalGraph.vue'

const route = useRoute()
const router = useRouter()

// ── markdown + wikilink resolution ──────────────────────────────────────
const md = new MarkdownIt({ html: false, linkify: true, breaks: false })
// stable heading ids (same convention as ArtifactPanel's O2 anchor support).
const slugify = (s: string) => s.toLowerCase().trim().replace(/[^\w\s-]/g, '').replace(/\s+/g, '-').replace(/-+/g, '-')
md.renderer.rules.heading_open = (tokens, idx, options, _env, self) => {
  const inline = tokens[idx + 1]
  const text = inline && inline.type === 'inline' ? inline.content : ''
  const id = slugify(text)
  if (id) tokens[idx]?.attrSet('id', id)
  return self.renderToken(tokens, idx, options)
}
// [[slug]] / [[slug|Display text]] → a normal md link tagged with a private
// scheme so the link_open override below can find it unambiguously even
// though markdown-it's own linkify already ran.
function preprocessWikilinks(body: string): string {
  return body.replace(/\[\[([^\]|]+)(?:\|([^\]]+))?]]/g, (_m, slug: string, label?: string) => {
    const s = slug.trim()
    const text = (label ?? s).trim()
    return `[${text}](wikilink:${encodeURIComponent(s)})`
  })
}
// existing-page slugs the CURRENT page's server response already told us
// about (outbound[].exists) — enough to color-code without a second
// round-trip. A link to a slug outside that set (rare — content added a link
// the outbound extraction missed) falls back to "exists" so we never
// falsely red-link something real; a genuinely broken link surfaces once the
// user clicks it and the page 404s.
const knownExisting = computed(() => new Set((page.value?.outbound ?? []).filter((l) => l.exists).map((l) => l.to_slug)))
const defaultLinkOpen =
  md.renderer.rules.link_open || ((tokens, idx, options, _env, self) => self.renderToken(tokens, idx, options))
md.renderer.rules.link_open = (tokens, idx, options, _env, self) => {
  const token = tokens[idx]
  const hrefIdx = token?.attrIndex('href') ?? -1
  if (token && hrefIdx >= 0 && token.attrs) {
    let href = token.attrs[hrefIdx]?.[1] ?? ''
    let isWiki = false
    if (href.startsWith('wikilink:')) {
      href = decodeURIComponent(href.slice('wikilink:'.length))
      isWiki = true
    } else if (!/^([a-z][a-z0-9+.-]*:)?\/\//i.test(href) && !href.startsWith('#') && !/^(mailto:|tel:)/i.test(href)) {
      // a bare/relative reference with no scheme — treat as a wiki page slug
      // ("or md links" per the mission spec).
      href = href.replace(/\.md(#.*)?$/i, '')
      isWiki = true
    }
    if (isWiki) {
      const slug = href
      const exists = knownExisting.value.has(slug)
      token.attrSet('href', `/wiki/page/${encodeURIComponent(slug)}`)
      token.attrSet('data-wiki-slug', slug)
      token.attrJoin('class', exists ? 'wiki-link' : 'wiki-link wiki-redlink')
      token.attrSet('title', exists ? slug : `${slug} — no page yet, click to create`)
    }
  }
  return defaultLinkOpen(tokens, idx, options, _env, self)
}
const renderedBody = computed(() => (page.value ? md.render(preprocessWikilinks(page.value.content || '')) : ''))

function onContentClick(e: MouseEvent) {
  const a = (e.target as HTMLElement)?.closest?.('a[data-wiki-slug]') as HTMLAnchorElement | null
  if (!a) return
  e.preventDefault()
  const slug = a.getAttribute('data-wiki-slug') || ''
  if (!slug) return
  if (a.classList.contains('wiki-redlink')) {
    creatingSlug.value = slug
    return
  }
  router.push(`/wiki/page/${encodeURIComponent(slug)}`)
}

// ── data ─────────────────────────────────────────────────────────────────
const available = ref(true)
const wikis = ref<WikiBrief[]>([])
const WIKI_KEY = 'stewards-ui.wiki.selected'
const selectedWiki = ref(localStorage.getItem(WIKI_KEY) || '')
watch(selectedWiki, (v) => { try { localStorage.setItem(WIKI_KEY, v) } catch { /* quota */ } })

const pages = ref<WikiPageBrief[]>([])
const pagesLoading = ref(false)
const statusFilter = ref('')

const mode = ref<'pages' | 'graph'>('pages')

const pageSlug = computed(() => (route.name === 'wiki-page' ? String(route.params.slug ?? '') : ''))
const page = ref<WikiPageDetail | null>(null)
const pageLoading = ref(false)
const pageErr = ref('')

const creatingSlug = ref('')
const creating = ref(false)

const STATUS_BADGE: Record<string, string> = {
  published: 'text-emerald-300 border-emerald-700/60 bg-emerald-900/20',
  draft: 'text-sky-300 border-sky-700/60 bg-sky-900/20',
  stub: 'text-zinc-400 border-zinc-700 bg-zinc-900/40 border-dashed',
  superseded: 'text-rose-300 border-rose-700/60 bg-rose-900/20',
}
const statusBadge = (s: string) => STATUS_BADGE[s] ?? 'text-zinc-400 border-zinc-700 bg-zinc-900/40'

async function loadWikis() {
  try {
    const r = await api.wikiWikis()
    available.value = r.available
    wikis.value = r.items
    if (!selectedWiki.value && wikis.value[0]) selectedWiki.value = wikis.value[0].slug
  } catch { /* leave defaults — a network error is not "schema absent" */ }
}
async function loadPages() {
  pagesLoading.value = true
  try {
    const r = await api.wikiPages(selectedWiki.value, statusFilter.value)
    available.value = r.available
    pages.value = r.items
  } finally {
    pagesLoading.value = false
  }
}
async function loadPage(slug: string) {
  pageLoading.value = true
  pageErr.value = ''
  page.value = null
  try {
    const r = await api.wikiPage(slug)
    available.value = r.available
    page.value = r.page ?? null
    if (r.available && !r.page) pageErr.value = 'page not found'
  } catch (e) {
    pageErr.value = String(e)
  } finally {
    pageLoading.value = false
  }
}
async function confirmCreateStub(slug: string) {
  creating.value = true
  try {
    await api.wikiCreateStub(slug, selectedWiki.value || page.value?.wiki)
    creatingSlug.value = ''
    router.push(`/wiki/page/${encodeURIComponent(slug)}`)
  } catch (e) {
    pageErr.value = String(e)
  } finally {
    creating.value = false
  }
}

function openPage(slug: string) {
  router.push(`/wiki/page/${encodeURIComponent(slug)}`)
}

onMounted(async () => {
  await loadWikis()
  if (pageSlug.value) await loadPage(pageSlug.value)
  else await loadPages()
})
watch(pageSlug, (s) => { if (s) { mode.value = 'pages'; loadPage(s) } })
watch(selectedWiki, () => { if (!pageSlug.value) loadPages() })
watch(statusFilter, () => { if (!pageSlug.value) loadPages() })
watch(() => route.name, (n) => { if (n === 'wiki' && !pageSlug.value) loadPages() })
</script>

<template>
  <div class="space-y-3">
    <div class="flex items-center gap-2 flex-wrap">
      <h2 class="text-2xl font-semibold tracking-tight mr-2">Wiki</h2>

      <select v-model="selectedWiki" class="bg-zinc-900/80 border border-zinc-800 rounded px-2 py-1 text-sm text-zinc-200 max-w-[200px]"
              title="choose a wiki">
        <option value="">all wikis</option>
        <option v-for="w in wikis" :key="w.slug" :value="w.slug">{{ w.name }} ({{ w.page_count }})</option>
      </select>

      <!-- mode toggle: Pages ⇄ Graph, same idiom as WorldGraphPanel's World/Cosmos toggle -->
      <div class="inline-flex rounded overflow-hidden border border-zinc-700 text-xs">
        <button class="px-2 py-1" :class="mode === 'pages' ? 'bg-sky-900/50 text-sky-200' : 'text-zinc-400 hover:bg-zinc-800'"
                @click="mode = 'pages'">📄 Pages</button>
        <button class="px-2 py-1 border-l border-zinc-700" :class="mode === 'graph' ? 'bg-sky-900/50 text-sky-200' : 'text-zinc-400 hover:bg-zinc-800'"
                @click="mode = 'graph'">✦ Graph</button>
      </div>

      <select v-if="mode === 'pages' && !pageSlug" v-model="statusFilter"
              class="bg-zinc-900/80 border border-zinc-800 rounded px-2 py-1 text-xs text-zinc-400 ml-auto">
        <option value="">any status</option>
        <option value="published">published</option>
        <option value="draft">draft</option>
        <option value="stub">stub</option>
        <option value="superseded">superseded</option>
      </select>
    </div>

    <div v-if="!available" class="rounded border border-amber-800/50 bg-amber-900/20 text-amber-300 text-xs px-3 py-2">
      Wiki schema isn't available yet in this database — WIKI-CORE hasn't landed. This reader lights up automatically once it does.
    </div>

    <!-- GRAPH mode -->
    <WikiGraphPanel v-if="mode === 'graph'" :wiki="selectedWiki" class="h-[70vh]" @open-page="openPage" />

    <!-- PAGES mode -->
    <template v-else>
      <!-- page list (no page selected) -->
      <div v-if="!pageSlug">
        <p v-if="pagesLoading" class="text-sm text-zinc-500">loading…</p>
        <p v-else-if="!pages.length" class="text-sm text-zinc-600">
          No pages yet{{ selectedWiki ? ` in ${selectedWiki}` : '' }}.
        </p>
        <ul v-else class="divide-y divide-zinc-800/50 rounded-md border border-zinc-800 bg-zinc-900/30 overflow-hidden">
          <li v-for="p in pages" :key="p.slug">
            <button class="w-full text-left px-4 py-2.5 flex items-center gap-3 hover:bg-zinc-800/50" @click="openPage(p.slug)">
              <span class="text-zinc-200 truncate">{{ p.title || p.slug }}</span>
              <span class="rounded-full border px-1.5 py-0.5 text-[10px] shrink-0" :class="statusBadge(p.status)">{{ p.status }}</span>
              <span class="text-zinc-600 text-xs ml-auto shrink-0">{{ p.updated_at ? new Date(p.updated_at).toLocaleDateString() : '' }}</span>
            </button>
          </li>
        </ul>
      </div>

      <!-- page view -->
      <div v-else class="relative">
        <button class="text-xs text-zinc-500 hover:text-zinc-300 mb-3" @click="router.push('/wiki')">← all pages</button>

        <p v-if="pageLoading" class="text-sm text-zinc-500">loading…</p>
        <p v-else-if="pageErr" class="text-sm text-rose-400">{{ pageErr }}</p>

        <template v-else-if="page">
          <!-- corner local graph (item 3) -->
          <div class="absolute right-0 top-8 z-10 hidden lg:block">
            <WikiLocalGraph :slug="page.slug" @open-page="openPage" />
          </div>

          <header class="border-b border-zinc-800 pb-4 mb-4 pr-0 lg:pr-60">
            <div class="flex items-center gap-2 flex-wrap">
              <h3 class="text-xl font-semibold tracking-tight">{{ page.title || page.slug }}</h3>
              <span class="rounded-full border px-1.5 py-0.5 text-[10px]" :class="statusBadge(page.status)">{{ page.status }}</span>
            </div>
            <div class="text-xs text-zinc-500 mt-2 flex gap-3 font-mono">
              <span>wiki: {{ page.wiki }}</span>
              <span>slug: {{ page.slug }}</span>
              <span v-if="page.updated_at">updated: {{ new Date(page.updated_at).toLocaleString() }}</span>
            </div>
            <div v-if="page.superseded_by" class="mt-2 text-xs rounded border border-rose-800/50 bg-rose-900/20 text-rose-300 px-2 py-1 inline-block">
              superseded by
              <button class="underline hover:text-rose-100" @click="openPage(page.superseded_by)">{{ page.superseded_by }}</button>
            </div>
          </header>

          <article class="doc-theme prose prose-invert max-w-none pr-0 lg:pr-60" v-html="renderedBody" @click="onContentClick"></article>

          <!-- red-link "create page?" confirm -->
          <div v-if="creatingSlug" class="mt-4 rounded border border-amber-800/50 bg-amber-900/20 px-3 py-2 flex items-center gap-3 text-sm">
            <span class="text-amber-300">Create page "{{ creatingSlug }}"?</span>
            <button class="text-xs px-2 py-1 rounded bg-emerald-600 text-white disabled:opacity-50" :disabled="creating" @click="confirmCreateStub(creatingSlug)">
              {{ creating ? '…' : 'Create' }}
            </button>
            <button class="text-xs text-zinc-400 hover:text-zinc-200" @click="creatingSlug = ''">Cancel</button>
          </div>

          <!-- backlinks -->
          <section v-if="page.backlinks.length" class="mt-6 pr-0 lg:pr-60">
            <div class="text-zinc-500 text-[11px] uppercase tracking-wide mb-1.5">Pages that link here ({{ page.backlinks.length }})</div>
            <ul class="flex flex-wrap gap-2">
              <li v-for="b in page.backlinks" :key="b.from_slug">
                <button class="text-xs rounded border border-zinc-800 bg-zinc-900/50 text-sky-400 hover:text-sky-300 px-2 py-1" @click="openPage(b.from_slug)">
                  {{ b.title || b.from_slug }}
                </button>
              </li>
            </ul>
          </section>

          <!-- sources footer (click → the real doc/asset) -->
          <section v-if="page.sources.length" class="mt-6 pr-0 lg:pr-60 border-t border-zinc-800 pt-3">
            <div class="text-zinc-500 text-[11px] uppercase tracking-wide mb-1.5">Sources ({{ page.sources.length }})</div>
            <ul class="space-y-1">
              <li v-for="(s, i) in page.sources" :key="i" class="text-xs text-zinc-500 font-mono truncate">
                {{ JSON.stringify(s) }}
              </li>
            </ul>
          </section>
        </template>
      </div>
    </template>
  </div>
</template>

<style scoped>
/* red links: distinct from the doc-theme's normal sky link so an unwritten
   page reads at a glance, without inventing a whole new palette. */
:deep(.doc-theme a.wiki-redlink) {
  color: #fb7185; /* rose-400 */
  text-decoration-style: dashed;
  text-decoration-color: rgba(251, 113, 133, 0.5);
}
:deep(.doc-theme a.wiki-redlink:hover) { text-decoration-color: #fb7185; }
</style>
