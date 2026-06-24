<script setup lang="ts">
// Stewdio sessions panel — EVERY chat session, grouped hierarchically under the
// project / work item / doc / corpus it's grounded in. Multiple chats on the
// same project (e.g. "books") nest under one collapsible header. Click a chat to
// reopen it in the chat panel (closes the gap: a chat started on something you've
// navigated away from was previously unreachable).
import { ref, computed, onMounted, onUnmounted } from 'vue'
import { api, type ChatAllSessionRow } from '@/api'
import { useStewdioStore } from '../../stores/stewdio'

defineOptions({ inheritAttrs: false })
const store = useStewdioStore()
const sessions = ref<ChatAllSessionRow[]>([])
const loading = ref(false)
const err = ref('')
const filter = ref('')
let timer: number | undefined

async function load() {
  loading.value = true; err.value = ''
  try { sessions.value = (await api.chatSessionsAll()).sessions }
  catch (e) { err.value = String(e) }
  finally { loading.value = false }
}
onMounted(() => { load(); timer = window.setInterval(load, 15000) })
onUnmounted(() => { if (timer) window.clearInterval(timer) })

// kind → a small glyph so the grounding is legible at a glance
const KIND_ICON: Record<string, string> = { work_item: '◆', doc: '📄', project: '🗂', all: '✸', unknown: '•' }

function open(s: ChatAllSessionRow) {
  store.openChat(s.target_ref || '', s.target_kind || 'unknown', s.title || s.target_ref || '', s.session_id)
}

const shownList = computed(() =>
  !filter.value ? sessions.value
    : sessions.value.filter(s =>
        (s.title || '').toLowerCase().includes(filter.value.toLowerCase()) ||
        (s.preview || '').toLowerCase().includes(filter.value.toLowerCase())))

// group sessions by their grounding target — a project/work-item/doc/corpus
// becomes one header with its chats nested under it.
type Group = { key: string; kind: string; title: string; rows: ChatAllSessionRow[] }
const groups = computed<Group[]>(() => {
  const m = new Map<string, Group>()
  for (const s of shownList.value) {
    const key = s.target_ref || ('kind:' + (s.target_kind || 'unknown'))
    let g = m.get(key)
    if (!g) { g = { key, kind: s.target_kind || 'unknown', title: s.title || s.target_ref || '(ungrounded)', rows: [] }; m.set(key, g) }
    g.rows.push(s)
  }
  // groups ordered by their most-recent chat; rows already come newest-first
  return [...m.values()].sort((a, b) => (b.rows[0]?.last_at || '').localeCompare(a.rows[0]?.last_at || ''))
})

// collapse state per group (default expanded)
const collapsed = ref<Set<string>>(new Set())
function toggleGroup(key: string) {
  const s = new Set(collapsed.value)
  s.has(key) ? s.delete(key) : s.add(key)
  collapsed.value = s
}
</script>

<template>
  <div class="h-full flex flex-col bg-zinc-950">
    <div class="border-b border-zinc-800 px-3 py-2 flex items-center gap-2 text-xs">
      <span class="text-zinc-300 font-medium">Sessions</span>
      <span class="text-zinc-600">{{ sessions.length }}</span>
      <input v-model="filter" placeholder="filter…"
             class="ml-auto bg-zinc-900 border border-zinc-800 rounded px-1.5 py-0.5 text-[11px] text-zinc-300 w-28" />
      <button class="text-zinc-500 hover:text-zinc-200" title="refresh" @click="load">⟳</button>
    </div>
    <div class="flex-1 overflow-auto">
      <div v-if="err" class="px-3 py-2 text-rose-400 text-xs">{{ err }}</div>
      <div v-else-if="!sessions.length && !loading" class="px-3 py-3 text-zinc-600 text-xs">
        No chat sessions yet — start one in the chat panel.
      </div>

      <div v-for="g in groups" :key="g.key">
        <!-- project / target header: collapsible -->
        <button class="w-full text-left px-2 py-1.5 flex items-center gap-1.5 bg-zinc-900/40 border-b border-zinc-900 hover:bg-zinc-800/50 sticky top-0"
                @click="toggleGroup(g.key)">
          <span class="text-zinc-600 text-[10px] w-3">{{ collapsed.has(g.key) ? '▸' : '▾' }}</span>
          <span class="text-zinc-500" :title="g.kind">{{ KIND_ICON[g.kind] || '•' }}</span>
          <span class="text-zinc-200 text-xs font-medium truncate flex-1" :title="g.title">{{ g.title }}</span>
          <span class="text-zinc-600 text-[10px]">{{ g.rows.length }}</span>
        </button>
        <!-- the chats nested under it -->
        <template v-if="!collapsed.has(g.key)">
          <button v-for="s in g.rows" :key="s.session_id"
                  class="w-full text-left pl-7 pr-3 py-1.5 border-b border-zinc-900 hover:bg-zinc-800/60"
                  @click="open(s)">
            <div class="flex items-center gap-1.5">
              <span class="text-zinc-300 text-[11px] truncate flex-1" :title="s.preview">{{ s.preview || '(empty conversation)' }}</span>
              <span class="text-zinc-700 text-[10px]">{{ s.msg_count }}</span>
            </div>
            <div class="text-zinc-700 text-[10px] mt-0.5">{{ s.last_at || 'new' }}</div>
          </button>
        </template>
      </div>
    </div>
  </div>
</template>
