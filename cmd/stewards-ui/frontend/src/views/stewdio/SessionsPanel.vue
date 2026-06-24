<script setup lang="ts">
// Stewdio sessions panel — EVERY chat session in one place, each linked to the
// work item / doc / project corpus it's grounded in. Click one to reopen it in
// the chat panel (closes the gap: a chat started on a work item you've since
// navigated away from was previously unreachable). Refreshes on focus + a manual
// button; cheap enough to also poll lightly.
import { ref, onMounted, onUnmounted } from 'vue'
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

const shown = () =>
  !filter.value ? sessions.value
    : sessions.value.filter(s =>
        (s.title || '').toLowerCase().includes(filter.value.toLowerCase()) ||
        (s.preview || '').toLowerCase().includes(filter.value.toLowerCase()))
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
      <button v-for="s in shown()" :key="s.session_id"
              class="w-full text-left px-3 py-2 border-b border-zinc-900 hover:bg-zinc-800/60 group"
              @click="open(s)">
        <div class="flex items-center gap-1.5">
          <span class="text-zinc-500" :title="s.target_kind">{{ KIND_ICON[s.target_kind || 'unknown'] || '•' }}</span>
          <span class="text-zinc-300 text-xs truncate flex-1" :title="s.title">{{ s.title || '(ungrounded)' }}</span>
          <span class="text-zinc-700 text-[10px]">{{ s.msg_count }}</span>
        </div>
        <div class="text-zinc-500 text-[11px] truncate mt-0.5">{{ s.preview || '(empty conversation)' }}</div>
        <div class="text-zinc-700 text-[10px] mt-0.5">{{ s.last_at || 'new' }}</div>
      </button>
    </div>
  </div>
</template>
