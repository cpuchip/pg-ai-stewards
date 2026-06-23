<script setup lang="ts">
// Stewdio right panel — chat with the selected work item, grounded in its doc +
// corpus + sessions, on a local model. Each turn is dispatched via /api/chat/send
// (substrate dispatch_chat_turn → bgworker tool loop); replies stream back over
// the /api/chat/stream SSE relay. (Stewdio P1)
import { ref, watch, nextTick, onUnmounted } from 'vue'
import MarkdownIt from 'markdown-it'
import { api } from '@/api'
import { useStewdioStore } from '../../stores/stewdio'

defineOptions({ inheritAttrs: false })
const store = useStewdioStore()
const md = new MarkdownIt({ html: false, linkify: true, breaks: true })

type Msg = { id: number; role: string; content: string; finish_reason?: string; tool_calls: number }
const messages = ref<Msg[]>([])
const input = ref('')
const pending = ref(false)
const err = ref('')
const sessionId = ref('')
const log = ref<HTMLElement | null>(null)
let es: EventSource | null = null

// mirror the server's deterministic session id (chat.go chatSessionFor)
function sessionFor(ref_: string): string {
  let s = 'stewdio-' + ref_.replace(/[^a-zA-Z0-9_-]+/g, '-').replace(/^-+|-+$/g, '')
  return s.length > 60 ? s.slice(0, 60) : s
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
    messages.value.push(m)
    if (m.role === 'assistant' && m.finish_reason && m.finish_reason !== 'tool_calls') pending.value = false
    nextTick(() => { if (log.value) log.value.scrollTop = log.value.scrollHeight })
  }
  es.onerror = () => { /* EventSource auto-reconnects; nothing to do */ }
}

watch(() => store.selectedRef, (ref_) => {
  err.value = ''; pending.value = false
  if (!ref_) { closeStream(); messages.value = []; sessionId.value = ''; return }
  sessionId.value = sessionFor(ref_)
  openStream(sessionId.value)
}, { immediate: true })

onUnmounted(closeStream)

async function send() {
  const text = input.value.trim()
  if (!text || !store.selectedRef) return
  input.value = ''; err.value = ''; pending.value = true
  try {
    const r = await api.chatSend({
      session_id: sessionId.value || undefined,
      target_ref: store.selectedRef,
      message: text,
      model: store.chatModel,
    })
    if (r.session_id && r.session_id !== sessionId.value) { sessionId.value = r.session_id; openStream(r.session_id) }
  } catch (e) { err.value = String(e); pending.value = false }
}

// hide the first-turn grounding context line; render the rest
const visible = (m: Msg) => !(m.role === 'user' && m.content.startsWith('(Context:'))
function onKey(e: KeyboardEvent) { if (e.key === 'Enter' && !e.shiftKey) { e.preventDefault(); send() } }
</script>

<template>
  <div class="h-full flex flex-col bg-zinc-950">
    <div class="border-b border-zinc-800 px-3 py-2 flex items-center gap-2 text-xs">
      <span class="text-zinc-400">Chat</span>
      <span class="text-zinc-600 truncate flex-1" :title="store.selectedRef || ''">
        {{ store.selectedTitle || '— select a work item' }}
      </span>
      <select v-model="store.chatModel" class="bg-zinc-900 border border-zinc-800 rounded px-1.5 py-0.5 text-[11px] text-zinc-300">
        <option value="reason">reason</option>
        <option value="ingest">ingest</option>
        <option value="critic">critic</option>
      </select>
    </div>

    <div ref="log" class="flex-1 overflow-auto px-3 py-3 space-y-3">
      <template v-for="m in messages" :key="m.id">
        <div v-if="visible(m) && m.role === 'user'" class="flex justify-end">
          <div class="max-w-[85%] bg-sky-600/20 border border-sky-700/40 text-zinc-100 rounded-lg px-3 py-2 text-sm whitespace-pre-wrap">{{ m.content }}</div>
        </div>
        <div v-else-if="m.role === 'assistant' && m.content.trim()" class="flex justify-start">
          <div class="max-w-[90%] bg-zinc-900 border border-zinc-800 rounded-lg px-3 py-2 text-sm prose prose-invert prose-sm max-w-none" v-html="md.render(m.content)"></div>
        </div>
        <div v-else-if="m.role === 'assistant' && m.tool_calls > 0" class="text-zinc-600 text-xs italic">🔧 retrieving…</div>
        <div v-else-if="m.role === 'tool'" class="text-zinc-600 text-[11px]">↳ read source</div>
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
