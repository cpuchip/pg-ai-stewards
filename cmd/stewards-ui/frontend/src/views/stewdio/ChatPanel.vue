<script setup lang="ts">
// Stewdio right panel — chat with the selected work item, grounded in its doc +
// corpus + sessions, on a local model. Each turn is dispatched via /api/chat/send
// (substrate dispatch_chat_turn → bgworker tool loop); replies stream back over
// the /api/chat/stream SSE relay. (P1)
// P4 adds: a conversation-history sidebar (multiple sessions per target) and
// per-message provenance chips (which facet each retrieval tool hit).
import { ref, computed, watch, nextTick, onMounted, onUnmounted } from 'vue'
import MarkdownIt from 'markdown-it'
import { api, type ChatSessionRow, type ChatWorkItemCard } from '@/api'
import { useStewdioStore } from '../../stores/stewdio'
import { makeLinkClick } from './useDocLinks'

defineOptions({ inheritAttrs: false })
const store = useStewdioStore()
const md = new MarkdownIt({ html: false, linkify: true, breaks: true })
// Arc A: links in assistant replies navigate (internal) or open (external).
const onLink = makeLinkClick(store)

// The grounding lens (b1). '' = follow the currently-selected doc/work item (the
// default); '__all__' = the whole pool; a project name = that corpus. An explicit
// lens WINS over the selected item, so a new chat can be grounded in a project even
// while a doc is open on the left — the selector is always available in the header.
const lens = ref('')
const projects = ref<{ name: string; doc_count: number }[]>([])
onMounted(async () => { try { projects.value = (await api.chatProjects()).projects } catch { /* none */ } })
// the effective conversation ref: an explicit lens wins; else the selected item.
const chatRef = computed(() => {
  if (lens.value === '__all__') return 'all'
  if (lens.value) return `project:${lens.value}`
  return store.selectedRef || ''
})

type Msg = { id: number; role: string; content: string; finish_reason?: string; tool_calls: number; tools?: string[]; images?: string[] }
const messages = ref<Msg[]>([])
const input = ref('')
const pending = ref(false)
const err = ref('')
const activeSession = ref('')
const sessions = ref<ChatSessionRow[]>([])
const showSessions = ref(false)
const log = ref<HTMLElement | null>(null)
let es: EventSource | null = null

// rich-docs P2/P3: files staged for the next turn. Images get a vision preview
// (object URL); documents (PDF/office/HTML/text/archive) get a 📄 chip and are
// extracted server-side (doc_extract) into safe subject material.
type Staged = { file: File; url: string; isImage: boolean }
const staged = ref<Staged[]>([])
const fileInput = ref<HTMLInputElement | null>(null)
const dragActive = ref(false)
function pickFiles() { fileInput.value?.click() }
function addFiles(files: FileList | File[] | null) {
  if (!files) return
  for (const f of Array.from(files)) {
    const isImage = f.type.startsWith('image/')
    staged.value.push({ file: f, url: isImage ? URL.createObjectURL(f) : '', isImage })
  }
}
function onFiles(e: Event) {
  addFiles((e.target as HTMLInputElement).files)
  if (fileInput.value) fileInput.value.value = '' // allow re-picking the same file
}
// Arc A: drag-and-drop files onto the chat → the same staged pipeline as 📎.
function onDragOver(e: DragEvent) { if (chatRef.value) { e.preventDefault(); dragActive.value = true } }
function onDragLeave() { dragActive.value = false }
function onDrop(e: DragEvent) {
  dragActive.value = false
  if (!chatRef.value) return
  e.preventDefault()
  addFiles(e.dataTransfer?.files ?? null)
}
function removeStaged(i: number) { const s = staged.value[i]; if (s?.url) URL.revokeObjectURL(s.url); staged.value.splice(i, 1) }

// mirror the server's deterministic base session id (chat.go chatSessionFor)
function baseSessionFor(ref_: string): string {
  const s = 'stewdio-' + ref_.replace(/[^a-zA-Z0-9_-]+/g, '-').replace(/^-+|-+$/g, '')
  return s.length > 60 ? s.slice(0, 60) : s
}
const lsKey = (ref_: string) => `stewdio.chat.active.${ref_}`

// map a retrieval tool name → the facet it touched (provenance chips)
const FACET: Record<string, string> = {
  doc_get: 'doc', doc_search: 'doc', doc_similar: 'doc',
  doc_citations: 'citations',
  book_search: 'book', read_corpus_parents: 'corpus', result_search: 'corpus', result_read: 'corpus',
  investigate_session: 'sessions', investigate_doc: 'sessions', context_search: 'sessions', expand_message: 'sessions',
  work_item_show: 'work item', work_item_list: 'work item',
}
function facetChips(tools?: string[]): string[] {
  const set = new Set<string>()
  for (const t of tools || []) set.add(FACET[t] || t)
  return [...set]
}

// Rich artifact cards — a doc-build reply ends with a /api/chat/attachment/{id}
// download link; render each as an inline card (icon / filename / size / ⬇, or a
// thumbnail for images) instead of only a bare link.
type ArtMeta = { id: number; filename: string; mime_type: string; kind: string; byte_size: number }
const artifactMeta = ref<Record<number, ArtMeta>>({})
const ATT_RE = /\/api\/chat\/attachment\/(\d+)/g
function artifactIds(content: string): number[] {
  const ids = new Set<number>()
  let m: RegExpExecArray | null
  ATT_RE.lastIndex = 0
  while ((m = ATT_RE.exec(content)) !== null) ids.add(Number(m[1]))
  return [...ids]
}
async function fetchArtifactMeta(ids: number[]) {
  for (const id of ids) {
    if (artifactMeta.value[id]) continue
    try { artifactMeta.value[id] = await api.chatAttachmentMeta(id) } catch { /* ignore */ }
  }
}
// resolved (metadata-loaded) artifacts referenced in a reply — type-safe for the template
function resolvedArtifacts(content: string): ArtMeta[] {
  return artifactIds(content).map(id => artifactMeta.value[id]).filter((a): a is ArtMeta => !!a)
}
// structural — works for both reply artifacts (ArtMeta) and work-item card
// artifacts (WiCardArtifact); both carry mime_type / filename / kind.
function isImageArt(a: { kind?: string; mime_type?: string }) { return a.kind === 'image' || (a.mime_type || '').startsWith('image/') }
function artIcon(a: { mime_type?: string; filename: string }): string {
  const m = a.mime_type || '', f = a.filename
  if (m.includes('pdf')) return '📕'
  if (m.includes('spreadsheet') || /\.(xlsx|csv)$/.test(f)) return '📊'
  if (m.includes('presentation') || f.endsWith('.pptx')) return '📑'
  if (m.includes('word') || f.endsWith('.docx')) return '📘'
  if (m.includes('zip') || /\.(zip|tar|gz|tgz|7z)$/.test(f)) return '🗜'
  return '📄'
}
function fmtSize(n: number): string {
  return n < 1024 ? `${n} B` : n < 1048576 ? `${(n / 1024).toFixed(0)} KB` : `${(n / 1048576).toFixed(1)} MB`
}

// b2: live work-item cards — the tasks this chat spawned (start_task / doc-build /
// brainstorm), each walking its pipeline stage path. Polled while the panel is
// open; the cadence speeds up while anything is in flight.
const workItems = ref<ChatWorkItemCard[]>([])
let wiTimer: ReturnType<typeof setTimeout> | null = null
const wiInFlight = (w: ChatWorkItemCard) => w.status === 'pending' || w.status === 'running' || w.status === 'in_progress'
function wiIcon(w: ChatWorkItemCard) { return w.status === 'completed' ? '✅' : w.status === 'failed' ? '⚠️' : '⏳' }
function wiStatusCls(w: ChatWorkItemCard) {
  return w.status === 'completed' ? 'text-emerald-400' : w.status === 'failed' ? 'text-rose-400' : 'text-amber-400'
}
function wiCurIdx(w: ChatWorkItemCard) { return w.stages.indexOf(w.current_stage || '') }
function stageMark(w: ChatWorkItemCard, i: number): string {
  const cur = wiCurIdx(w)
  if (w.status === 'completed' || (cur >= 0 && i < cur)) return '✓'
  if (i === cur) return w.status === 'failed' ? '✕' : '•'
  return '○'
}
function stagePillCls(w: ChatWorkItemCard, i: number): string {
  const cur = wiCurIdx(w)
  if (w.status === 'completed' || (cur >= 0 && i < cur)) return 'bg-emerald-900/30 text-emerald-300 border-emerald-800/50'
  if (i === cur) return w.status === 'failed'
    ? 'bg-rose-900/40 text-rose-300 border-rose-800/50'
    : 'bg-amber-900/40 text-amber-200 border-amber-700/50 animate-pulse'
  return 'bg-zinc-800/50 text-zinc-500 border-zinc-700/50'
}
async function pollWorkItems() {
  const sid = activeSession.value
  if (!sid) { workItems.value = []; return }
  try { workItems.value = (await api.chatWorkItems(sid)).work_items || [] } catch { /* keep last */ }
}
function scheduleWorkItems() {
  if (wiTimer) { clearTimeout(wiTimer); wiTimer = null }
  const active = pending.value || workItems.value.some(wiInFlight)
  wiTimer = setTimeout(async () => { await pollWorkItems(); scheduleWorkItems() }, active ? 4000 : 20000)
}
function refreshWork() { pollWorkItems().then(scheduleWorkItems) }

function closeStream() {
  if (es) { es.close(); es = null }
  if (wiTimer) { clearTimeout(wiTimer); wiTimer = null }
}

function openStream(sid: string) {
  closeStream()
  messages.value = []
  workItems.value = []
  refreshWork() // b2: load + start polling this session's spawned work items
  es = new EventSource(`/api/chat/stream?session_id=${encodeURIComponent(sid)}&after=0`)
  es.onmessage = (ev) => {
    let m: Msg
    try { m = JSON.parse(ev.data) } catch { return }
    if (messages.value.some(x => x.id === m.id)) return
    // drop an optimistic (negative-id) echo once the real row arrives
    if (m.role === 'user') messages.value = messages.value.filter(x => !(x.id < 0 && x.content === m.content))
    messages.value.push(m)
    if (m.role === 'assistant' && m.content) fetchArtifactMeta(artifactIds(m.content))
    if (m.role === 'assistant' && m.finish_reason && m.finish_reason !== 'tool_calls') pending.value = false
    nextTick(() => { if (log.value) log.value.scrollTop = log.value.scrollHeight })
  }
  es.onerror = () => { /* EventSource auto-reconnects; nothing to do */ }
}

async function loadSessions(ref_: string): Promise<string> {
  try {
    const r = await api.chatSessions(ref_)
    sessions.value = r.sessions
    return r.default_session
  } catch { sessions.value = []; return baseSessionFor(ref_) }
}

// Sessions panel → open a specific chat. Registered BEFORE the chatRef watcher
// so they're flushed first: requestedLens drives the empty-chat lens, then
// requestedSession opens the exact session once chatRef has settled. The flag
// tells the chatRef watcher to stand down while a request is being honored.
let honoringRequest = false
watch(() => store.requestedLens, (v) => {
  if (v === null) return
  lens.value = v // '' | '__all__' | a project name
  store.requestedLens = null
})
// b1: navigating to a doc/work item on the left re-grounds the chat to it (clears
// any pinned project lens) so the default is always "chat about what I'm looking
// at". honoringRequest stands down so the Sessions-panel open flow isn't clobbered.
watch(() => store.selectedRef, (v) => { if (v && !honoringRequest) lens.value = '' })
watch(() => store.requestedSession, async (sid) => {
  if (!sid) return
  honoringRequest = true
  store.requestedSession = null
  await nextTick() // let selectedRef / lens drive chatRef
  const ref_ = chatRef.value
  if (ref_) {
    await loadSessions(ref_)
    activeSession.value = sid
    localStorage.setItem(lsKey(ref_), sid)
    pending.value = false
    err.value = ''
    showSessions.value = false
    openStream(sid)
  }
  honoringRequest = false
})

watch(chatRef, async (ref_) => {
  if (honoringRequest) return // the requestedSession watcher owns this open
  err.value = ''; pending.value = false; showSessions.value = false
  if (!ref_) { closeStream(); messages.value = []; sessions.value = []; activeSession.value = ''; return }
  const def = await loadSessions(ref_)
  // resume the last-used session for this target if it still exists, else newest, else the base
  const remembered = localStorage.getItem(lsKey(ref_))
  const exists = (sid: string) => sessions.value.some(s => s.session_id === sid)
  activeSession.value = (remembered && exists(remembered)) ? remembered
    : (sessions.value[0]?.session_id ?? def)
  openStream(activeSession.value)
}, { immediate: true })

onUnmounted(closeStream)

function switchSession(sid: string) {
  if (sid === activeSession.value) { showSessions.value = false; return }
  activeSession.value = sid
  if (chatRef.value) localStorage.setItem(lsKey(chatRef.value), sid)
  showSessions.value = false
  pending.value = false
  openStream(sid)
}

function newSession() {
  const ref_ = chatRef.value
  if (!ref_) return
  const sid = `${baseSessionFor(ref_)}-${Date.now().toString(36)}`
  activeSession.value = sid
  localStorage.setItem(lsKey(ref_), sid)
  showSessions.value = false
  pending.value = false
  openStream(sid) // empty until the first turn lands
}

async function send() {
  const text = input.value.trim()
  const toUpload = staged.value.slice()
  const ref_ = chatRef.value
  // allow a media-only turn (a question is optional when a file is attached)
  if ((!text && toUpload.length === 0) || !ref_) return
  input.value = ''; err.value = ''; pending.value = true
  const tempId = -Date.now()
  // optimistic echo — show staged IMAGES instantly via their object URLs; a
  // document is extracted server-side (no inline preview) but note its name.
  const docNames = toUpload.filter(s => !s.isImage).map(s => s.file.name)
  const echo = docNames.length ? (text ? text + '\n' : '') + docNames.map(n => `📄 ${n}`).join('\n') : text
  messages.value.push({ id: tempId, role: 'user', content: echo, tool_calls: 0, images: toUpload.filter(s => s.isImage).map(s => s.url) })
  staged.value = []
  nextTick(() => { if (log.value) log.value.scrollTop = log.value.scrollHeight })
  try {
    // upload any attachments first (under this session), collect their ids
    let attachmentIds: number[] | undefined
    if (toUpload.length) {
      const sid = activeSession.value || undefined
      const ups = await Promise.all(toUpload.map(s =>
        api.chatAttach(s.file, { session_id: sid, target_ref: ref_ })))
      attachmentIds = ups.map(u => u.id)
    }
    const r = await api.chatSend({
      session_id: activeSession.value || undefined,
      target_ref: ref_,
      message: text,
      model: store.chatModel,
      attachment_ids: attachmentIds,
    })
    if (r.session_id && r.session_id !== activeSession.value) {
      activeSession.value = r.session_id
      localStorage.setItem(lsKey(ref_), r.session_id)
      openStream(r.session_id)
    }
    // refresh the sidebar so a brand-new conversation shows up
    loadSessions(ref_)
    // b2: a turn may spawn a task (start_task / doc-build / brainstorm) — poll
    // soon so its card appears, then the scheduler keeps it live.
    setTimeout(refreshWork, 2000)
  } catch (e) {
    err.value = String(e); pending.value = false
    messages.value = messages.value.filter(m => m.id !== tempId)
  }
}

// Arc A: stop a running turn — cancel the queued chat row + stop the spinner.
async function stop() {
  pending.value = false
  try { if (activeSession.value) await api.chatStop(activeSession.value) } catch { /* best effort */ }
}

// Arc A: message actions.
async function copyMsg(m: Msg) { try { await navigator.clipboard.writeText(m.content) } catch { /* clipboard blocked */ } }
function regenerateLast() {
  // re-ask the most recent user turn
  for (let i = messages.value.length - 1; i >= 0; i--) {
    const m = messages.value[i]
    if (m && m.role === 'user' && visible(m)) { input.value = m.content; send(); return }
  }
}
function startTaskFrom(m: Msg) {
  // prefill the composer with a delegate framing; the agent's start_task does the rest
  input.value = 'Start a task: ' + m.content
}

// Arc A: slash-command palette — type "/" to surface the substrate's capabilities.
type Slash = { cmd: string; label: string; insert?: string; action?: () => void }
const SLASH: Slash[] = [
  { cmd: '/task',     label: 'Delegate — spawn a pipeline',           insert: 'Start a task: ' },
  { cmd: '/generate', label: 'Generate a document (pdf/xlsx/pptx/zip)', insert: 'Generate a document: ' },
  { cmd: '/extract',  label: 'Extract the attached document',          insert: 'Extract the attached document, then ' },
  { cmd: '/import',   label: 'Import an attached archive as a corpus',  insert: 'Import the attached archive as a project corpus named ' },
  { cmd: '/export',   label: 'Export this conversation (markdown)',     action: () => {
      if (activeSession.value) window.open(`/api/chat/export?session_id=${encodeURIComponent(activeSession.value)}&format=md`, '_blank') } },
]
const slashIdx = ref(0)
const slashMatches = computed(() => {
  const t = input.value
  if (!t.startsWith('/') || t.includes(' ')) return [] as Slash[]
  return SLASH.filter(c => c.cmd.startsWith(t.toLowerCase()))
})
function applySlash(c: Slash) {
  if (c.action) { c.action(); input.value = '' }
  else { input.value = c.insert || '' }
  slashIdx.value = 0
}

// hide the first-turn grounding context line; render the rest
const visible = (m: Msg) => !(m.role === 'user' && m.content.startsWith('(Context:'))
function onKey(e: KeyboardEvent) {
  const matches = slashMatches.value
  if (matches.length) {
    if (e.key === 'ArrowDown') { e.preventDefault(); slashIdx.value = (slashIdx.value + 1) % matches.length; return }
    if (e.key === 'ArrowUp')   { e.preventDefault(); slashIdx.value = (slashIdx.value - 1 + matches.length) % matches.length; return }
    if (e.key === 'Enter' || e.key === 'Tab') { e.preventDefault(); const c = matches[slashIdx.value] ?? matches[0]; if (c) applySlash(c); return }
    if (e.key === 'Escape')    { input.value = ''; return }
  }
  if (e.key === 'Enter' && !e.shiftKey) { e.preventDefault(); send() }
}
</script>

<template>
  <div class="h-full flex flex-col bg-zinc-950 relative"
       :class="dragActive ? 'ring-2 ring-sky-500/60 ring-inset' : ''"
       @dragover="onDragOver" @dragleave="onDragLeave" @drop="onDrop">
    <!-- Arc A: drag-and-drop overlay -->
    <div v-if="dragActive" class="absolute inset-0 z-20 bg-sky-950/40 border-2 border-dashed border-sky-500/60 rounded flex items-center justify-center pointer-events-none">
      <span class="text-sky-200 text-sm">drop a document, image, or zip to attach</span>
    </div>
    <div class="border-b border-zinc-800 px-3 py-2 flex items-center gap-2 text-xs">
      <button class="text-zinc-400 hover:text-zinc-200" :title="`${sessions.length} conversation(s)`"
              @click="showSessions = !showSessions">💬<span class="text-zinc-600 ml-0.5">{{ sessions.length || '' }}</span></button>
      <a v-if="activeSession && messages.length" :href="`/api/chat/export?session_id=${encodeURIComponent(activeSession)}&format=md`"
         class="text-zinc-500 hover:text-sky-300" title="export this conversation as markdown" download>⬇</a>
      <!-- b1: grounding selector, always available. The default ('') follows the
           doc/work item selected on the left; pick a project or Everything to
           override (so a new chat can be grounded in a project even with a doc open). -->
      <div class="flex-1 flex items-center gap-1.5 min-w-0">
        <span class="text-zinc-600">in</span>
        <select v-model="lens" class="bg-zinc-900 border border-zinc-800 rounded px-1.5 py-0.5 text-[11px] text-zinc-300 max-w-[70%] truncate"
                :title="store.selectedRef ? 'grounded in the selected item — pick a project to override' : 'ground this chat in a project/corpus (doc_search scopes to it)'">
          <option value="">{{ store.selectedRef ? `📄 ${store.selectedTitle || store.selectedRef}` : '— pick a project —' }}</option>
          <option value="__all__">✸ Everything (whole pool)</option>
          <option v-for="p in projects" :key="p.name" :value="p.name">{{ p.name }}<span v-if="p.doc_count"> ({{ p.doc_count }})</span></option>
        </select>
      </div>
      <button v-if="chatRef" class="text-sky-400 hover:text-sky-300" title="new conversation" @click="newSession">＋ New</button>
      <select v-model="store.chatModel" class="bg-zinc-900 border border-zinc-800 rounded px-1.5 py-0.5 text-[11px] text-zinc-300">
        <option value="reason">reason</option>
        <option value="ingest">ingest</option>
        <option value="critic">critic</option>
      </select>
    </div>

    <!-- conversation-history sidebar (P4) -->
    <div v-if="showSessions" class="border-b border-zinc-800 bg-zinc-900/60 max-h-48 overflow-auto">
      <div v-if="!sessions.length" class="px-3 py-2 text-zinc-600 text-xs">no past conversations — ask something to start one</div>
      <button v-for="s in sessions" :key="s.session_id"
              class="w-full text-left px-3 py-1.5 border-b border-zinc-900 hover:bg-zinc-800/60"
              :class="s.session_id === activeSession ? 'bg-zinc-800' : ''"
              @click="switchSession(s.session_id)">
        <div class="text-zinc-300 text-xs truncate">{{ s.preview || '(empty conversation)' }}</div>
        <div class="text-zinc-600 text-[10px]">{{ s.last_at || 'new' }} · {{ s.msg_count }} msgs<span v-if="s.is_default"> · default</span></div>
      </button>
    </div>

    <div ref="log" class="flex-1 overflow-auto px-3 py-3 space-y-3">
      <template v-for="m in messages" :key="m.id">
        <div v-if="visible(m) && m.role === 'user'" class="flex flex-col items-end group">
          <div class="max-w-[85%] bg-sky-600/20 border border-sky-700/40 text-zinc-100 rounded-lg px-3 py-2 text-sm">
            <div v-if="m.images && m.images.length" class="flex flex-wrap gap-1.5 mb-1.5">
              <img v-for="(src, i) in m.images" :key="i" :src="src"
                   class="max-h-40 max-w-full rounded border border-sky-700/40 object-contain" alt="attachment" />
            </div>
            <div v-if="m.content" class="whitespace-pre-wrap">{{ m.content }}</div>
          </div>
          <button class="mt-0.5 mr-1 text-[10px] text-zinc-600 hover:text-zinc-300 opacity-0 group-hover:opacity-100 transition"
                  title="copy" @click="copyMsg(m)">⧉ copy</button>
        </div>
        <div v-else-if="m.role === 'assistant' && m.content.trim()" class="flex flex-col items-start group">
          <div class="max-w-[90%] bg-zinc-900 border border-zinc-800 rounded-lg px-3 py-2 text-sm prose prose-invert prose-sm max-w-none" v-html="md.render(m.content)" @click="onLink"></div>
          <!-- rich artifact cards: generated docs (doc-build exports) referenced in the reply -->
          <div v-for="a in resolvedArtifacts(m.content)" :key="a.id" class="mt-1.5 max-w-[90%]">
            <img v-if="isImageArt(a)" :src="`/api/chat/attachment/${a.id}`" :alt="a.filename"
                 class="max-h-56 rounded-lg border border-zinc-800" />
            <a v-else :href="`/api/chat/attachment/${a.id}?download=1`" download
               class="flex items-center gap-2.5 bg-zinc-900 border border-zinc-800 rounded-lg px-3 py-2 hover:border-sky-700/60 transition group/card no-underline">
              <span class="text-2xl leading-none">{{ artIcon(a) }}</span>
              <span class="min-w-0 flex-1">
                <span class="block text-zinc-200 text-xs truncate">{{ a.filename || 'artifact' }}</span>
                <span class="block text-zinc-600 text-[10px]">{{ fmtSize(a.byte_size) }} · download</span>
              </span>
              <span class="text-zinc-500 group-hover/card:text-sky-300 text-lg">⬇</span>
            </a>
          </div>
          <div class="flex gap-2 mt-0.5 ml-1 text-[10px] text-zinc-600 opacity-0 group-hover:opacity-100 transition">
            <button class="hover:text-zinc-300" title="copy" @click="copyMsg(m)">⧉ copy</button>
            <button class="hover:text-zinc-300" title="re-ask the last question" @click="regenerateLast()">↻ retry</button>
            <button class="hover:text-zinc-300" title="start a task from this" @click="startTaskFrom(m)">⊕ task</button>
          </div>
        </div>
        <div v-else-if="m.role === 'assistant' && m.tool_calls > 0" class="flex items-center gap-1 text-[11px] text-zinc-600">
          <span class="italic">🔧 retrieving</span>
          <span v-for="c in facetChips(m.tools)" :key="c"
                class="px-1.5 py-0.5 rounded bg-zinc-800 border border-zinc-700 text-zinc-400">{{ c }}</span>
        </div>
      </template>

      <!-- b2: live work-item cards — the tasks this chat spawned (start_task /
           doc-build / brainstorm), each walking its pipeline stage path. They
           update in place as the work advances; a completed build's artifact
           surfaces here even when the export landed without a reply link. -->
      <div v-for="w in workItems" :key="w.id"
           class="rounded-lg border border-zinc-800 bg-zinc-900/70 px-3 py-2 text-xs">
        <div class="flex items-center gap-2 mb-1.5">
          <span>{{ wiIcon(w) }}</span>
          <span class="text-zinc-300 truncate flex-1" :title="w.id">{{ w.slug || w.pipeline_family || 'task' }}</span>
          <span class="text-[10px] uppercase tracking-wide" :class="wiStatusCls(w)">{{ w.status }}</span>
        </div>
        <div v-if="w.stages.length" class="flex items-center gap-1 flex-wrap">
          <template v-for="(s, i) in w.stages" :key="s">
            <span class="px-1.5 py-0.5 rounded border text-[10px]" :class="stagePillCls(w, i)">{{ stageMark(w, i) }} {{ s }}</span>
            <span v-if="i < w.stages.length - 1" class="text-zinc-700">›</span>
          </template>
        </div>
        <div v-if="w.error" class="text-rose-400/80 mt-1 text-[10px] line-clamp-2" :title="w.error">{{ w.error }}</div>
        <template v-for="a in (w.artifacts || [])" :key="a.id">
          <img v-if="isImageArt(a)" :src="a.url" :alt="a.filename" class="mt-1.5 max-h-44 rounded-lg border border-zinc-800" />
          <a v-else :href="`${a.url}?download=1`" download
             class="mt-1.5 flex items-center gap-2.5 bg-zinc-900 border border-zinc-800 rounded-lg px-2.5 py-1.5 hover:border-sky-700/60 transition no-underline">
            <span class="text-xl leading-none">{{ artIcon(a) }}</span>
            <span class="min-w-0 flex-1">
              <span class="block text-zinc-200 truncate">{{ a.filename || 'artifact' }}</span>
              <span class="block text-zinc-600 text-[10px]">{{ fmtSize(a.byte_size) }} · download</span>
            </span>
            <span class="text-zinc-500 text-base">⬇</span>
          </a>
        </template>
      </div>

      <div v-if="pending" class="flex items-center gap-2 text-xs">
        <span class="text-zinc-500 italic">thinking…</span>
        <button class="text-rose-400 hover:text-rose-300 border border-zinc-800 rounded px-1.5 py-0.5" title="stop" @click="stop">■ stop</button>
      </div>
      <div v-if="!chatRef" class="text-zinc-600 text-sm">
        Select a work item or doc on the left to chat grounded in it — or pick a
        <span class="text-zinc-400">project lens</span> above to chat over a whole corpus.
        Attach a PDF, Office doc, or a zipped folder with 📎 and it becomes safe,
        searchable subject material.
      </div>
      <div v-if="err" class="text-rose-400 text-xs">{{ err }}</div>
    </div>

    <div class="border-t border-zinc-800 p-2">
      <!-- rich-docs P2/P3: staged attachments preview (image thumb or 📄 chip) -->
      <div v-if="staged.length" class="flex flex-wrap gap-2 mb-2">
        <div v-for="(s, i) in staged" :key="i" class="relative group">
          <img v-if="s.isImage" :src="s.url" class="h-14 w-14 object-cover rounded border border-zinc-700" :alt="s.file.name" />
          <div v-else class="h-14 max-w-[10rem] px-2 flex items-center gap-1 rounded border border-zinc-700 bg-zinc-900 text-[11px] text-zinc-300"
               :title="s.file.name">📄<span class="truncate">{{ s.file.name }}</span></div>
          <button class="absolute -top-1.5 -right-1.5 bg-zinc-800 border border-zinc-600 rounded-full w-4 h-4 text-[10px] leading-none text-zinc-300 hover:text-rose-400"
                  title="remove" @click="removeStaged(i)">×</button>
        </div>
      </div>
      <!-- Arc A: slash-command palette -->
      <div v-if="slashMatches.length" class="mb-2 rounded border border-zinc-800 bg-zinc-900 overflow-hidden">
        <button v-for="(c, i) in slashMatches" :key="c.cmd"
                class="w-full text-left px-2 py-1 text-xs flex items-center gap-2"
                :class="i === slashIdx ? 'bg-zinc-800' : 'hover:bg-zinc-800/60'"
                @mouseenter="slashIdx = i" @click="applySlash(c)">
          <span class="text-sky-300 font-mono">{{ c.cmd }}</span>
          <span class="text-zinc-500">{{ c.label }}</span>
        </button>
      </div>
      <div class="flex items-end gap-2">
        <button class="text-zinc-400 hover:text-sky-300 disabled:opacity-40 pb-2 text-lg leading-none"
                :disabled="!chatRef" title="attach a document, image, or zipped folder" @click="pickFiles">📎</button>
        <input ref="fileInput" type="file" multiple class="hidden" @change="onFiles"
               accept="image/*,.pdf,.docx,.xlsx,.pptx,.odt,.epub,.html,.htm,.txt,.md,.csv,.json,.rtf,.zip,.7z,.tar,.gz,.tgz,.bz2,.xz,.rar" />
        <textarea
          v-model="input"
          :disabled="!chatRef"
          rows="2"
          placeholder="ask about this — attach a doc/image/zip with 📎; Enter to send"
          class="flex-1 bg-zinc-900 border border-zinc-800 rounded px-3 py-2 text-sm text-zinc-200 resize-none disabled:opacity-50"
          @keydown="onKey"></textarea>
      </div>
    </div>
  </div>
</template>
