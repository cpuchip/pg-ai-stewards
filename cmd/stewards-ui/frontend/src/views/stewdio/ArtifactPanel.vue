<script setup lang="ts">
// Stewdio center panel — the artifact / plan-progress viewer. A doc renders its
// markdown; a work item shows its plan as a live checklist (Devin's "plan =
// progress": stages light up as they complete), polled while it runs. (P1 doc +
// P2 live plan=progress)
import { ref, watch, onUnmounted } from 'vue'
import MarkdownIt from 'markdown-it'
import { api, type StudyDetail, type WorkItemDetail } from '@/api'
import { useStewdioStore } from '../../stores/stewdio'
import { makeLinkClick } from './useDocLinks'

defineOptions({ inheritAttrs: false })
const store = useStewdioStore()
const md = new MarkdownIt({ html: false, linkify: true, breaks: false })
// Arc A: clicking a link in the doc body navigates (internal) or opens (external).
const onLink = makeLinkClick(store)

const loading = ref(false)
const err = ref('')
const doc = ref<StudyDetail | null>(null)
const wi = ref<WorkItemDetail | null>(null)
const stages = ref<{ name: string; agent_family?: string; model?: string }[]>([])
let poll: number | null = null

function stopPoll() { if (poll !== null) { clearInterval(poll); poll = null } }
const terminal = (s?: string) => s === 'completed' || s === 'failed' || s === 'cancelled'

function stageState(name: string): 'done' | 'active' | 'pending' {
  const results = (wi.value?.stage_results as Record<string, unknown>) || {}
  if (name in results) return 'done'
  if (wi.value?.current_stage === name && !terminal(wi.value?.status)) return 'active'
  return 'pending'
}

async function refreshWorkItem(id: string) {
  try {
    wi.value = await api.workItemGet(id)
    if (terminal(wi.value.status) || wi.value.status === 'awaiting_review') stopPoll()
  } catch (e) { err.value = String(e); stopPoll() }
}

async function load() {
  stopPoll(); doc.value = null; wi.value = null; stages.value = []; err.value = ''
  if (!store.selectedRef || !store.selectedKind) return
  loading.value = true
  try {
    if (store.selectedKind === 'doc') {
      doc.value = await api.studyGet(store.selectedRef)
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
    <div v-if="loading && !wi && !doc" class="text-zinc-500">loading…</div>
    <div v-else-if="err" class="text-rose-400">{{ err }}</div>

    <div v-else-if="doc">
      <div class="flex items-start justify-between gap-2 mb-1">
        <div class="text-zinc-100 text-base font-medium">{{ doc.title || doc.slug }}</div>
        <a :href="`/api/studies/export?slug=${encodeURIComponent(doc.slug)}&format=md`"
           class="shrink-0 text-[11px] text-sky-400 hover:text-sky-300 border border-zinc-800 rounded px-1.5 py-0.5"
           title="download this document as markdown" download>⬇ .md</a>
      </div>
      <div class="text-zinc-600 text-xs mb-4">{{ doc.kind }} · {{ doc.slug }}</div>
      <div class="prose prose-invert prose-sm max-w-none" v-html="md.render(doc.body || '')" @click="onLink"></div>
    </div>

    <div v-else-if="wi">
      <div class="text-zinc-100 text-base font-medium mb-1">{{ wi.slug || wi.id }}</div>
      <div class="text-zinc-500 text-xs mb-4">
        {{ wi.pipeline }} ·
        <span :class="wi.status === 'completed' ? 'text-emerald-400' : wi.status === 'failed' || wi.status === 'cancelled' ? 'text-rose-400' : 'text-amber-400'">{{ wi.status }}</span>
        <span v-if="wi.maturity"> · {{ wi.maturity }}</span>
        <span v-if="poll !== null" class="text-amber-400 animate-pulse"> · live</span>
      </div>

      <div class="text-zinc-500 text-[11px] uppercase tracking-wide mb-2">Plan</div>
      <ol class="space-y-1.5 mb-4">
        <li v-for="s in stages" :key="s.name" class="flex items-center gap-2 text-sm">
          <span v-if="stageState(s.name) === 'done'" class="text-emerald-400">✓</span>
          <span v-else-if="stageState(s.name) === 'active'" class="text-amber-400 animate-pulse">▸</span>
          <span v-else class="text-zinc-600">○</span>
          <span :class="stageState(s.name) === 'done' ? 'text-zinc-300' : stageState(s.name) === 'active' ? 'text-amber-300' : 'text-zinc-500'">{{ s.name }}</span>
          <span class="text-zinc-700 text-[11px]">{{ s.model }}</span>
        </li>
        <li v-if="!stages.length" class="text-zinc-600 text-xs">no stage plan for {{ wi.pipeline }}</li>
      </ol>

      <details v-if="wi.input" class="text-xs">
        <summary class="text-zinc-500 cursor-pointer">input</summary>
        <pre class="text-zinc-400 whitespace-pre-wrap mt-1">{{ JSON.stringify(wi.input, null, 2) }}</pre>
      </details>
    </div>

    <div v-else class="text-zinc-600">
      Select a work item or doc on the left to view it here, or ＋ New to kick one off.
    </div>
  </div>
</template>
