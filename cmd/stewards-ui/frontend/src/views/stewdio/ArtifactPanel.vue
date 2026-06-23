<script setup lang="ts">
// Stewdio center panel — the artifact viewer (the "editor surface"). Renders the
// selected doc's markdown, or a work item's summary + stage progress. (Stewdio
// P1 = doc + work-item summary; P2 makes the running-work-item plan=progress live.)
import { ref, watch } from 'vue'
import MarkdownIt from 'markdown-it'
import { api, type StudyDetail, type WorkItemDetail } from '@/api'
import { useStewdioStore } from '../../stores/stewdio'

defineOptions({ inheritAttrs: false })
const store = useStewdioStore()
const md = new MarkdownIt({ html: false, linkify: true, breaks: false })

const loading = ref(false)
const err = ref('')
const doc = ref<StudyDetail | null>(null)
const wi = ref<WorkItemDetail | null>(null)

async function load() {
  doc.value = null; wi.value = null; err.value = ''
  if (!store.selectedRef || !store.selectedKind) return
  loading.value = true
  try {
    if (store.selectedKind === 'doc') doc.value = await api.studyGet(store.selectedRef)
    else wi.value = await api.workItemGet(store.selectedRef)
  } catch (e) { err.value = String(e) } finally { loading.value = false }
}
watch(() => [store.selectedRef, store.selectedKind], load, { immediate: true })
</script>

<template>
  <div class="h-full overflow-auto bg-zinc-950 px-5 py-4 text-sm">
    <div v-if="loading" class="text-zinc-500">loading…</div>
    <div v-else-if="err" class="text-rose-400">{{ err }}</div>

    <div v-else-if="doc">
      <div class="text-zinc-100 text-base font-medium mb-1">{{ doc.title || doc.slug }}</div>
      <div class="text-zinc-600 text-xs mb-4">{{ doc.kind }} · {{ doc.slug }}</div>
      <div class="prose prose-invert prose-sm max-w-none" v-html="md.render(doc.body || '')"></div>
    </div>

    <div v-else-if="wi">
      <div class="text-zinc-100 text-base font-medium mb-1">{{ wi.slug || wi.id }}</div>
      <div class="text-zinc-500 text-xs mb-3">
        {{ wi.pipeline }} · <span class="text-zinc-300">{{ wi.status }}</span>
        <span v-if="wi.maturity"> · {{ wi.maturity }}</span>
      </div>
      <div class="text-zinc-500 text-[11px] uppercase tracking-wide mb-1">Stages</div>
      <ol class="space-y-1 mb-4">
        <li v-for="(_, name) in (wi.stage_results || {})" :key="name" class="text-emerald-400 text-xs">
          ✓ {{ name }}
        </li>
        <li v-if="wi.current_stage && wi.status !== 'completed'" class="text-amber-400 text-xs">
          ▸ {{ wi.current_stage }} <span class="text-zinc-500">(current)</span>
        </li>
      </ol>
      <details v-if="wi.input" class="text-xs">
        <summary class="text-zinc-500 cursor-pointer">input</summary>
        <pre class="text-zinc-400 whitespace-pre-wrap mt-1">{{ JSON.stringify(wi.input, null, 2) }}</pre>
      </details>
    </div>

    <div v-else class="text-zinc-600">
      Select a work item or doc on the left to view it here.
    </div>
  </div>
</template>
