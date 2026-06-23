<script setup lang="ts">
// Stewdio right panel — chat with the selected work item, grounded in its doc +
// corpus + sessions, on a local model. Each turn is dispatched via /api/chat/send
// (substrate dispatch_chat_turn → bgworker tool loop); replies stream back over
// the /api/chat/stream SSE relay. (P1)
// P4 adds: a conversation-history sidebar (multiple sessions per target) and
// per-message provenance chips (which facet each retrieval tool hit).
import { ref, watch, nextTick, onUnmounted } from 'vue'
import MarkdownIt from 'markdown-it'
import { api, type ChatSessionRow } from '@/api'
import { useStewdioStore } from '../../stores/stewdio'

defineOptions({ inheritAttrs: false })
const store = useStewdioStore()
const md = new MarkdownIt({ html: false, linkify: true, breaks: true })

type Msg = { id: number; role: string; content: string; finish_reason?: string; tool_calls: number; tools?: string[] }
const messages = ref<Msg[]>([])
const input = ref('')
const pending = ref(false)
const err = ref('')
const activeSession = ref('')
const sessions = ref<ChatSessionRow[]>([])
const showSessions = ref(false)
const log = ref<HTMLElement | null>(null)
let es: EventSource | null = null

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

function closeStream() { if (es) { es.close(); es = null } }

function openStream(sid: string) {
  closeStream()
  messages.value = []
  es = new EventSource(`/api/chat/stream?session_id=${encodeURIComponent(sid)}&after=0`)
  es.onmessage = (ev) => {
    let m: Msg
    try { m = JSON.parse(ev.data) } catch { return }
    if (messages.value.some(x => x.id === m.id)) return
    // drop an optimistic (negative-id) echo once the real row arrives
    if (m.role === 'user') messages.value = messages.value.filter(x => !(x.id < 0 && x.content === m.content))
    messages.value.push(m)
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

watch(() => store.selectedRef, async (ref_) => {
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
  if (store.selectedRef) localStorage.setItem(lsKey(store.selectedRef), sid)
  showSessions.value = false
  pending.value = false
  openStream(sid)
}

function newSession() {
  if (!store.selectedRef) return
  const sid = `${baseSessionFor(store.selectedRef)}-${Date.now().toString(36)}`
  activeSession.value = sid
  localStorage.setItem(lsKey(store.selectedRef), sid)
  showSessions.value = false
  pending.value = false
  openStream(sid) // empty until the first turn lands
}

async function send() {
  const text = input.value.trim()
  if (!text || !store.selectedRef) return
  input.value = ''; err.value = ''; pending.value = true
  const tempId = -Date.now()
  messages.value.push({ id: tempId, role: 'user', content: text, tool_calls: 0 }) // optimistic echo
  nextTick(() => { if (log.value) log.value.scrollTop = log.value.scrollHeight })
  try {
    const r = await api.chatSend({
      session_id: activeSession.value || undefined,
      target_ref: store.selectedRef,
      message: text,
      model: store.chatModel,
    })
    if (r.session_id && r.session_id !== activeSession.value) {
      activeSession.value = r.session_id
      if (store.selectedRef) localStorage.setItem(lsKey(store.selectedRef), r.session_id)
      openStream(r.session_id)
    }
    // refresh the sidebar so a brand-new conversation shows up
    if (store.selectedRef) loadSessions(store.selectedRef)
  } catch (e) {
    err.value = String(e); pending.value = false
    messages.value = messages.value.filter(m => m.id !== tempId)
  }
}

// hide the first-turn grounding context line; render the rest
const visible = (m: Msg) => !(m.role === 'user' && m.content.startsWith('(Context:'))
function onKey(e: KeyboardEvent) { if (e.key === 'Enter' && !e.shiftKey) { e.preventDefault(); send() } }
</script>

<template>
  <div class="h-full flex flex-col bg-zinc-950">
    <div class="border-b border-zinc-800 px-3 py-2 flex items-center gap-2 text-xs">
      <button class="text-zinc-400 hover:text-zinc-200" :title="`${sessions.length} conversation(s)`"
              @click="showSessions = !showSessions">💬<span class="text-zinc-600 ml-0.5">{{ sessions.length || '' }}</span></button>
      <span class="text-zinc-600 truncate flex-1" :title="store.selectedRef || ''">
        {{ store.selectedTitle || '— select a work item' }}
      </span>
      <button v-if="store.selectedRef" class="text-sky-400 hover:text-sky-300" title="new conversation" @click="newSession">＋ New</button>
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
        <div v-if="visible(m) && m.role === 'user'" class="flex justify-end">
          <div class="max-w-[85%] bg-sky-600/20 border border-sky-700/40 text-zinc-100 rounded-lg px-3 py-2 text-sm whitespace-pre-wrap">{{ m.content }}</div>
        </div>
        <div v-else-if="m.role === 'assistant' && m.content.trim()" class="flex justify-start">
          <div class="max-w-[90%] bg-zinc-900 border border-zinc-800 rounded-lg px-3 py-2 text-sm prose prose-invert prose-sm max-w-none" v-html="md.render(m.content)"></div>
        </div>
        <div v-else-if="m.role === 'assistant' && m.tool_calls > 0" class="flex items-center gap-1 text-[11px] text-zinc-600">
          <span class="italic">🔧 retrieving</span>
          <span v-for="c in facetChips(m.tools)" :key="c"
                class="px-1.5 py-0.5 rounded bg-zinc-800 border border-zinc-700 text-zinc-400">{{ c }}</span>
        </div>
      </template>
      <div v-if="pending" class="text-zinc-500 text-xs italic">thinking…</div>
      <div v-if="!store.selectedRef" class="text-zinc-600 text-sm">
        Select a work item or doc on the left, then ask about it — grounded in its
        doc, source, and the sessions that built it.
      </div>
      <div v-if="err" class="text-rose-400 text-xs">{{ err }}</div>
    </div>

    <div class="border-t border-zinc-800 p-2">
      <textarea
        v-model="input"
        :disabled="!store.selectedRef"
        rows="2"
        placeholder="ask about this work item… (Enter to send)"
        class="w-full bg-zinc-900 border border-zinc-800 rounded px-3 py-2 text-sm text-zinc-200 resize-none disabled:opacity-50"
        @keydown="onKey"></textarea>
    </div>
  </div>
</template>
