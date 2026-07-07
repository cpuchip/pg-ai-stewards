<script setup lang="ts">
// Stewdio center panel — the artifact / plan-progress viewer. A doc renders its
// markdown; a work item shows its plan as a live checklist (Devin's "plan =
// progress": stages light up as they complete), polled while it runs. (P1 doc +
// P2 live plan=progress)
import { ref, computed, watch, onUnmounted } from 'vue'
import MarkdownIt from 'markdown-it'
import { api, type StudyDetail, type WorkItemDetail, type AttachmentMeta, type ObjectPage } from '@/api'
import { useStewdioStore } from '../../stores/stewdio'
import { makeLinkClick } from './useDocLinks'
import { extractPooledSlugs } from '@/stageArtifacts'
import SourcesPulledPanel from '../wiki/SourcesPulledPanel.vue'

defineOptions({ inheritAttrs: false })
const store = useStewdioStore()
const md = new MarkdownIt({ html: false, linkify: true, breaks: false })
// O2: give headings stable ids so intra-doc `#anchor` links can scroll to them.
const slugify = (s: string) =>
  s.toLowerCase().trim().replace(/[^\w\s-]/g, '').replace(/\s+/g, '-').replace(/-+/g, '-')
md.renderer.rules.heading_open = (tokens, idx, options, _env, self) => {
  const inline = tokens[idx + 1]
  const text = inline && inline.type === 'inline' ? inline.content : ''
  const id = slugify(text)
  if (id) tokens[idx]?.attrSet('id', id)
  return self.renderToken(tokens, idx, options)
}
// Arc A: clicking a link in the doc body navigates (internal) or opens (external).
const onLink = makeLinkClick(store.select)

// Object viewer — "paint the source back" (O1). A digested YouTube video gets its
// player painted above the notes (the cpuchip.net move). The id is read from the
// doc: explicit frontmatter wins, then a youtube URL in known fields, then the
// slug itself (the digester encodes it: `yt-<id>-…` / `videoyt-<id>-…`).
function ytId(d: StudyDetail): string | null {
  const fm = (d.frontmatter || {}) as Record<string, unknown>
  const explicit = String(fm.video_id ?? fm.youtube_id ?? '')
  if (/^[A-Za-z0-9_-]{11}$/.test(explicit)) return explicit
  const urlish = String(fm.url ?? fm.source_url ?? fm.source ?? '')
  const m = urlish.match(/(?:youtu\.be\/|[?&]v=|embed\/)([A-Za-z0-9_-]{11})/)
  if (m?.[1]) return m[1]
  const sm = d.slug.match(/^(?:video)?yt-([A-Za-z0-9_-]{11})(?:-|$)/)
  return sm?.[1] ?? null
}
const videoId = computed(() => {
  const d = doc.value
  if (!d) return null
  if (d.kind === 'video' || /^(?:video)?yt-[A-Za-z0-9_-]{11}/.test(d.slug)) return ytId(d)
  return null
})

// O3: a doc that knows the original it was extracted from carries an `att:<id>`
// locator in its frontmatter → offer to open the source page/image.
const sourceObject = computed(() => {
  const v = (doc.value?.frontmatter as Record<string, unknown> | undefined)?.source_object
  return typeof v === 'string' && /^att:\d+$/.test(v) ? v : null
})
function openSourceObject() {
  if (sourceObject.value) store.select(sourceObject.value, 'object', doc.value?.title || sourceObject.value)
}

const loading = ref(false)
const err = ref('')
const doc = ref<StudyDetail | null>(null)
// "Sources pulled" tab (WIKI-GRAPH item 4) — sits beside the rendered doc, not
// inside it, so it never competes with the content for prose width.
const docTab = ref<'doc' | 'sources'>('doc')
const wi = ref<WorkItemDetail | null>(null)
const obj = ref<AttachmentMeta | null>(null)        // O1: a stored binary object
const objPages = ref<ObjectPage[]>([])               // a document's rendered pages
const stages = ref<{ name: string; agent_family?: string; model?: string }[]>([])
let poll: number | null = null

const objIsImage = computed(() => obj.value?.mime_type?.startsWith('image/') ?? false)
const objUrl = (id: number, download = false) =>
  `/api/chat/attachment/${id}${download ? '?download=1' : ''}`
const prettyBytes = (n?: number) => {
  if (!n) return ''
  if (n < 1024) return `${n} B`
  if (n < 1048576) return `${(n / 1024).toFixed(1)} KB`
  return `${(n / 1048576).toFixed(1)} MB`
}

function stopPoll() { if (poll !== null) { clearInterval(poll); poll = null } }
const terminal = (s?: string) => s === 'completed' || s === 'failed' || s === 'cancelled'

function stageState(name: string): 'done' | 'active' | 'pending' {
  const results = (wi.value?.stage_results as Record<string, unknown>) || {}
  if (name in results) return 'done'
  if (wi.value?.current_stage === name && !terminal(wi.value?.status)) return 'active'
  return 'pending'
}

// A completed run that pooled a doc announces it in a stage's JOURNAL prose
// ("…pooled as `slug`"). Surface those as openable artifact cards so the
// produced doc isn't stranded in the Docs list — the plan checklist alone left
// this panel an empty void once a run finished. Text-derived: there is no
// docs→work_item link in the schema (see stageArtifacts.ts for why).
const producedSlugs = computed(() => extractPooledSlugs(wi.value?.stage_results))
function openProduced(slug: string) { store.select(slug, 'doc', slug) }

async function refreshWorkItem(id: string) {
  try {
    wi.value = await api.workItemGet(id)
    if (terminal(wi.value.status) || wi.value.status === 'awaiting_review') stopPoll()
  } catch (e) { err.value = String(e); stopPoll() }
}

async function load() {
  stopPoll(); doc.value = null; wi.value = null; obj.value = null; objPages.value = []
  stages.value = []; err.value = ''; docTab.value = 'doc'
  if (!store.selectedRef || !store.selectedKind) return
  loading.value = true
  try {
    if (store.selectedKind === 'doc') {
      doc.value = await api.studyGet(store.selectedRef)
    } else if (store.selectedKind === 'object') {
      // locator is `att:<id>` (or a bare numeric id) → the object viewer.
      const id = parseInt(store.selectedRef.replace(/^att:/, ''), 10)
      if (Number.isNaN(id)) throw new Error('bad object locator')
      obj.value = await api.attachmentMeta(id)
      // a document attachment may have rendered page images (PDF flip).
      if (!objIsImage.value) {
        try { objPages.value = (await api.objectPages(id)).pages } catch { objPages.value = [] }
      }
    } else {
      wi.value = await api.workItemGet(store.selectedRef)
      try { stages.value = (await api.pipelineGet(wi.value.pipeline)).stages } catch { stages.value = [] }
      if (!terminal(wi.value.status)) poll = window.setInterval(() => refreshWorkItem(store.selectedRef!), 3000)
    }
  } catch (e) { err.value = String(e) } finally { loading.value = false }
}
watch(() => [store.selectedRef, store.selectedKind], load, { immediate: true })
onUnmounted(stopPoll)
</script>

<template>
  <div class="h-full overflow-auto bg-zinc-950 px-5 py-4 text-sm">
    <div v-if="loading && !wi && !doc && !obj" class="text-zinc-500">loading…</div>
    <div v-else-if="err" class="text-rose-400">{{ err }}</div>

    <div v-else-if="doc">
      <div class="flex items-start justify-between gap-2 mb-1">
        <div class="text-zinc-100 text-base font-medium">{{ doc.title || doc.slug }}</div>
        <a :href="`/api/studies/export?slug=${encodeURIComponent(doc.slug)}&format=md`"
           class="shrink-0 text-[11px] text-sky-400 hover:text-sky-300 border border-zinc-800 rounded px-1.5 py-0.5"
           title="download this document as markdown" download>⬇ .md</a>
      </div>
      <div class="text-zinc-600 text-xs mb-3 flex items-center gap-2">
        <span>{{ doc.kind }} · {{ doc.slug }}</span>
        <button v-if="sourceObject" class="text-emerald-400 hover:text-emerald-300 border border-emerald-800/50 rounded px-1.5 py-0.5"
                title="open the original source document (PDF / image) this was extracted from"
                @click="openSourceObject">🖼 view source</button>
      </div>

      <!-- Doc ⇄ Sources pulled tab strip (WIKI-GRAPH item 4) -->
      <div class="inline-flex rounded overflow-hidden border border-zinc-700 text-xs mb-4">
        <button class="px-2 py-1" :class="docTab === 'doc' ? 'bg-sky-900/50 text-sky-200' : 'text-zinc-400 hover:bg-zinc-800'"
                @click="docTab = 'doc'">Doc</button>
        <button class="px-2 py-1 border-l border-zinc-700" :class="docTab === 'sources' ? 'bg-sky-900/50 text-sky-200' : 'text-zinc-400 hover:bg-zinc-800'"
                @click="docTab = 'sources'">Sources pulled</button>
      </div>

      <template v-if="docTab === 'doc'">
        <!-- O1: paint the source back. A digested YouTube video shows its player
             above the notes — watch the source without leaving the cockpit. -->
        <div v-if="videoId" class="mb-4">
          <div class="relative w-full overflow-hidden rounded-lg border border-zinc-800 bg-black" style="aspect-ratio: 16 / 9;">
            <iframe
              class="absolute inset-0 h-full w-full"
              :src="`https://www.youtube-nocookie.com/embed/${videoId}`"
              title="source video"
              frameborder="0"
              allow="accelerometer; clipboard-write; encrypted-media; gyroscope; picture-in-picture"
              referrerpolicy="strict-origin-when-cross-origin"
              allowfullscreen></iframe>
          </div>
          <a :href="`https://youtu.be/${videoId}`" target="_blank" rel="noopener noreferrer"
             class="text-[11px] text-zinc-500 hover:text-sky-400">▶ open on YouTube</a>
        </div>

        <div class="doc-theme prose prose-invert max-w-none" v-html="md.render(doc.body || '')" @click="onLink"></div>
      </template>
      <SourcesPulledPanel v-else :doc-ref="doc.slug" @open="(ref) => store.select(ref, 'doc', ref)" />
    </div>

    <!-- O1: a stored binary object — paint the original back (image / PDF pages /
         download). The bytes are the durable source the world/digest was built from. -->
    <div v-else-if="obj">
      <div class="flex items-start justify-between gap-2 mb-1">
        <div class="text-zinc-100 text-base font-medium break-all">{{ obj.filename }}</div>
        <a :href="objUrl(obj.id, true)"
           class="shrink-0 text-[11px] text-sky-400 hover:text-sky-300 border border-zinc-800 rounded px-1.5 py-0.5"
           title="download the original file" download>⬇ file</a>
      </div>
      <div class="text-zinc-600 text-xs mb-4">{{ obj.mime_type }}<span v-if="obj.byte_size"> · {{ prettyBytes(obj.byte_size) }}</span></div>

      <!-- an image renders inline -->
      <img v-if="objIsImage" :src="objUrl(obj.id)" :alt="obj.filename"
           class="max-w-full rounded-lg border border-zinc-800 bg-zinc-900" />

      <!-- a document with rendered page images → flip through the pages -->
      <div v-else-if="objPages.length" class="space-y-3">
        <div class="text-zinc-500 text-[11px] uppercase tracking-wide">{{ objPages.length }} page{{ objPages.length === 1 ? '' : 's' }}</div>
        <img v-for="(p, i) in objPages" :key="p.id" :src="p.url" :alt="`page ${i + 1}`"
             loading="lazy" class="w-full rounded border border-zinc-800 bg-white" />
      </div>

      <!-- no preview path (e.g. a raw document with no page render) → offer the file -->
      <div v-else class="text-zinc-500 text-sm">
        No inline preview for this type.
        <a :href="objUrl(obj.id, true)" class="text-sky-400 hover:text-sky-300" download>Download the file</a>
        to open it.
      </div>
    </div>

    <div v-else-if="wi">
      <div class="text-zinc-100 text-base font-medium mb-1">{{ wi.slug || wi.id }}</div>
      <div class="text-zinc-500 text-xs mb-4">
        <!-- pipeline family + maturity are ops jargon → Developer only; status (done/failed/running) stays -->
        <span v-if="store.dev">{{ wi.pipeline }} · </span>
        <span :class="wi.status === 'completed' ? 'text-emerald-400' : wi.status === 'failed' || wi.status === 'cancelled' ? 'text-rose-400' : 'text-amber-400'">{{ wi.status }}</span>
        <span v-if="store.dev && wi.maturity"> · {{ wi.maturity }}</span>
        <span v-if="poll !== null" class="text-amber-400 animate-pulse"> · live</span>
      </div>

      <div class="text-zinc-500 text-[11px] uppercase tracking-wide mb-2">Plan</div>
      <ol class="space-y-1.5 mb-4">
        <li v-for="s in stages" :key="s.name" class="flex items-center gap-2 text-sm">
          <span v-if="stageState(s.name) === 'done'" class="text-emerald-400">✓</span>
          <span v-else-if="stageState(s.name) === 'active'" class="text-amber-400 animate-pulse">▸</span>
          <span v-else class="text-zinc-600">○</span>
          <span :class="stageState(s.name) === 'done' ? 'text-zinc-300' : stageState(s.name) === 'active' ? 'text-amber-300' : 'text-zinc-500'">{{ s.name }}</span>
          <span v-if="store.dev" class="text-zinc-700 text-[11px]">{{ s.model }}</span>
        </li>
        <li v-if="!stages.length" class="text-zinc-600 text-xs">no stage plan<span v-if="store.dev"> for {{ wi.pipeline }}</span></li>
      </ol>

      <!-- Produced artifact(s): the doc(s) this run pooled. Without this the
           panel showed the plan checklist and nothing else once a run finished,
           and the output had to be hunted in the Docs list. Click → open it here. -->
      <template v-if="producedSlugs.length">
        <div class="text-zinc-500 text-[11px] uppercase tracking-wide mb-2">Produced</div>
        <ul class="space-y-1.5 mb-4">
          <li v-for="slug in producedSlugs" :key="slug">
            <button
              class="group flex w-full items-center gap-2 rounded border border-zinc-800 bg-zinc-900/40 px-2.5 py-2 text-left hover:border-sky-700/60 hover:bg-sky-950/30"
              :title="`open ${slug}`"
              @click="openProduced(slug)"
            >
              <span class="text-sky-400">📄</span>
              <span class="min-w-0 flex-1 truncate text-sm text-zinc-200 group-hover:text-sky-200">{{ slug }}</span>
              <span class="shrink-0 text-[11px] text-zinc-600 group-hover:text-sky-400">open →</span>
            </button>
          </li>
        </ul>
      </template>

      <details v-if="store.dev && wi.input" class="text-xs">
        <summary class="text-zinc-500 cursor-pointer">input</summary>
        <pre class="text-zinc-400 whitespace-pre-wrap mt-1">{{ JSON.stringify(wi.input, null, 2) }}</pre>
      </details>
    </div>

    <div v-else class="text-zinc-600">
      Select a work item or doc on the left to view it here, or ＋ New task to kick one off.
    </div>
  </div>
</template>
