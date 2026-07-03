<script setup lang="ts">
// Stewdio Experiments panel — the Lab (87). Two lists: declared experiments
// (name/hypothesis/status/run count) and recent regression runs (pass/fail
// badge, expandable failure detail), plus a "Run regression now" button.
// Phase 1: no charts, no experiment create/edit form — those ride the
// dispatch machinery the proposal defers (.spec/proposals/lab-and-wiki.md).
import { ref, onMounted, onUnmounted } from 'vue'
import { labApi, type LabExperiment, type LabRegressionRun, type LabRegressionCaseResult } from '@/api'

defineOptions({ inheritAttrs: false })

const experiments = ref<LabExperiment[]>([])
const runs = ref<LabRegressionRun[]>([])
const err = ref('')
const running = ref(false)
let timer: number | undefined

// per-run expanded detail (case-level pass/fail), fetched lazily on click.
const expanded = ref<string | null>(null)
const detail = ref<Record<string, LabRegressionCaseResult[]>>({})
const detailLoading = ref<string | null>(null)

async function load() {
  try {
    const [e, r] = await Promise.all([labApi.experiments(), labApi.regressionRuns(20)])
    experiments.value = e
    runs.value = r
  } catch (ex) { err.value = String(ex) }
}
onMounted(() => { load(); timer = window.setInterval(load, 15000) })
onUnmounted(() => { if (timer) window.clearInterval(timer) })

async function toggleDetail(runId: string) {
  if (expanded.value === runId) { expanded.value = null; return }
  expanded.value = runId
  if (!detail.value[runId]) {
    detailLoading.value = runId
    try { detail.value = { ...detail.value, [runId]: await labApi.regressionRunDetail(runId) } }
    catch (ex) { err.value = String(ex) }
    finally { detailLoading.value = null }
  }
}

async function runNow() {
  running.value = true; err.value = ''
  try { await labApi.runRegressionNow(); await load() }
  catch (ex) { err.value = String(ex) }
  finally { running.value = false }
}

function statusCls(s: string): string {
  if (s === 'active') return 'text-emerald-400 border-emerald-700/60 bg-emerald-900/20'
  if (s === 'paused') return 'text-amber-300 border-amber-700/60 bg-amber-900/20'
  return 'text-zinc-500 border-zinc-700 bg-zinc-900/40' // concluded
}
function ago(ts?: string): string {
  if (!ts) return ''
  const t = Date.parse(ts)
  if (isNaN(t)) return ''
  const s = Math.max(0, Math.round((Date.now() - t) / 1000))
  if (s < 60) return `${s}s ago`
  if (s < 3600) return `${Math.round(s / 60)}m ago`
  if (s < 86400) return `${Math.round(s / 3600)}h ago`
  return `${Math.round(s / 86400)}d ago`
}
</script>

<template>
  <div class="h-full flex flex-col bg-zinc-950 text-zinc-300 overflow-auto">
    <div class="border-b border-zinc-800 px-3 py-2 flex items-center gap-2 text-xs sticky top-0 bg-zinc-950 z-10">
      <span class="text-zinc-300 font-medium">Experiments</span>
      <span class="text-zinc-600">the Lab</span>
      <button
        class="ml-auto text-[11px] rounded px-2 py-0.5 border border-sky-700/60 bg-sky-900/30 text-sky-200 hover:bg-sky-900/60 disabled:opacity-40"
        :disabled="running" @click="runNow">{{ running ? 'running…' : '▶ Run regression now' }}</button>
      <button class="text-zinc-500 hover:text-zinc-200" title="refresh" @click="load">⟳</button>
    </div>
    <div v-if="err" class="px-3 py-2 text-rose-400 text-xs border-b border-zinc-900">{{ err }}</div>

    <!-- declared experiments -->
    <div class="px-3 py-2 border-b border-zinc-900">
      <div class="text-[10px] uppercase tracking-wide text-zinc-600 mb-1.5">Declared experiments</div>
      <div v-if="!experiments.length" class="text-zinc-600 text-xs">none registered</div>
      <div v-for="e in experiments" :key="e.id" class="py-2 border-b border-zinc-900/70 last:border-0">
        <div class="flex items-center gap-2">
          <span class="text-zinc-200 text-[13px] font-medium truncate">{{ e.name }}</span>
          <span class="text-[9px] rounded px-1 border" :class="statusCls(e.status)">{{ e.status }}</span>
          <span class="ml-auto text-zinc-600 text-[10px]" :title="e.run_count + ' run(s)'">{{ e.run_count }} run{{ e.run_count === 1 ? '' : 's' }}</span>
        </div>
        <div class="text-zinc-500 text-[11px] mt-1 leading-snug">{{ e.hypothesis }}</div>
        <div class="flex flex-wrap gap-1 mt-1.5">
          <span v-for="m in e.metrics" :key="m" class="text-[9px] text-zinc-500 border border-zinc-800 rounded px-1 font-mono">{{ m }}</span>
        </div>
      </div>
    </div>

    <!-- recent regression runs -->
    <div class="px-3 py-2">
      <div class="text-[10px] uppercase tracking-wide text-zinc-600 mb-1.5">Recent regression runs</div>
      <div v-if="!runs.length" class="text-zinc-600 text-xs">no runs yet — click "Run regression now"</div>
      <div v-for="r in runs" :key="r.run_id" class="border-b border-zinc-900/70 last:border-0">
        <button class="w-full text-left py-1.5 flex items-center gap-2 hover:bg-zinc-900/40" @click="toggleDetail(r.run_id)">
          <span class="text-[10px] rounded px-1.5 py-0.5 border font-medium"
                :class="r.failed === 0 ? 'text-emerald-300 border-emerald-700/60 bg-emerald-900/20' : 'text-rose-300 border-rose-700/60 bg-rose-900/20'">
            {{ r.failed === 0 ? '✓ pass' : `⚠ ${r.failed} failed` }}
          </span>
          <span class="text-zinc-400 text-[11px] font-mono truncate">{{ r.run_id }}</span>
          <span class="ml-auto text-zinc-600 text-[10px] tabular-nums">{{ r.passed }}/{{ r.total }}</span>
          <span class="text-zinc-700 text-[10px] w-16 text-right">{{ ago(r.finished_at) }}</span>
          <span class="text-zinc-700 text-[10px] w-3">{{ expanded === r.run_id ? '▾' : '▸' }}</span>
        </button>
        <div v-if="expanded === r.run_id" class="pl-2 pb-2">
          <div v-if="detailLoading === r.run_id" class="text-zinc-600 text-[11px] py-1">loading…</div>
          <div v-for="c in (detail[r.run_id] || [])" :key="c.case_id"
               class="flex items-start gap-2 text-[11px] py-1 border-t border-zinc-900/60">
            <span :class="c.pass ? 'text-emerald-500' : 'text-rose-400'">{{ c.pass ? '✓' : '✗' }}</span>
            <div class="min-w-0 flex-1">
              <div class="text-zinc-300 truncate">{{ c.case_name }} <span class="text-zinc-700">({{ c.kind }})</span></div>
              <div v-if="!c.pass && c.detail" class="text-rose-400/80 text-[10px] mt-0.5 break-words">{{ c.detail }}</div>
            </div>
          </div>
        </div>
      </div>
    </div>
  </div>
</template>
