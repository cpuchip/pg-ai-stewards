<script setup lang="ts">
// Stewdio models panel — what's available, how it's registered under role
// aliases (reason / ingest / critic / vision), and LIVE usage: which models are
// running work right now (e.g. "3 sessions on gemini-3-flash"), plus 24h token +
// cost rollups per provider/model. Complements the GPU/pool view (local rig) by
// covering ALL providers. Reads /api/models/aliases + /api/activity.
import { ref, computed, onMounted, onUnmounted } from 'vue'
import { api, type AliasRow, type ActivityResp, type ActivityActive, type ActivityTool } from '@/api'

defineOptions({ inheritAttrs: false })
const aliases = ref<AliasRow[]>([])
const activity = ref<ActivityResp | null>(null)
const err = ref('')
let timer: number | undefined

async function load() {
  try {
    const [a, act] = await Promise.all([api.modelAliases(), api.activity()])
    aliases.value = a.aliases
    activity.value = act
  } catch (e) { err.value = String(e) }
}
// poll fast while anything is dispatched (so the live stream actually streams),
// slow when idle. setTimeout-recursion so the cadence can change each tick.
function reschedule() {
  if (timer) window.clearTimeout(timer)
  const live = (activity.value?.active || []).length > 0
  timer = window.setTimeout(async () => { await load(); reschedule() }, live ? 2500 : 8000)
}
onMounted(() => { load().then(reschedule) })
onUnmounted(() => { if (timer) window.clearTimeout(timer) })

// aliases grouped: reason → [members…], lowest priority (preferred) first.
const byAlias = computed(() => {
  const m: Record<string, AliasRow[]> = {}
  for (const a of aliases.value) (m[a.alias] ||= []).push(a)
  return m
})

// 95: the "preferred" badge means "what pick_alias_member actually resolves
// to" — the first ENABLED member, not simply index 0. A disabled priority-0
// member (e.g. rested via the Roles panel) must lose the badge to whichever
// enabled member is next in the chain.
function isPreferred(members: AliasRow[], i: number): boolean {
  const firstEnabled = members.findIndex(m => m.enabled !== false)
  return i === (firstEnabled === -1 ? 0 : firstEnabled)
}

// LIVE: in-progress work grouped by model → count + tokens + cost (the
// "N sessions on <model>" view). active rows are per work_item.
type LiveModel = { model: string; provider: string; count: number; tokens: number; micro: number; gpu?: string; local: boolean }
const liveByModel = computed<LiveModel[]>(() => {
  const acc: Record<string, LiveModel> = {}
  for (const w of (activity.value?.active || []) as ActivityActive[]) {
    const k = w.model || '?'
    if (!acc[k]) acc[k] = { model: k, provider: w.provider, count: 0, tokens: 0, micro: 0, gpu: w.gpu, local: w.local }
    acc[k].count++; acc[k].tokens += w.tokens || 0; acc[k].micro += w.micro_usd || 0
  }
  return Object.values(acc).sort((a, b) => b.count - a.count)
})

const usd = (micro: number) => micro > 0 ? `$${(micro / 1e6).toFixed(4)}` : '—'
const k = (n: number) => n >= 1000 ? `${(n / 1000).toFixed(1)}k` : String(n)
// non-LLM tool/sandbox pulse: in-flight first, then most-recent.
const toolRows = computed<ActivityTool[]>(() => {
  const live = (activity.value?.tools || []) as ActivityTool[]
  const rank = (s: string) => (s === 'in_progress' || s === 'pending' ? 0 : 1)
  return [...live].sort((a, b) => rank(a.status) - rank(b.status)).slice(0, 12)
})
const toolRunning = (t: ActivityTool) => t.status === 'in_progress' || t.status === 'pending'
function toolGlyph(t: ActivityTool): string {
  if (toolRunning(t)) return '◐'
  return t.status === 'error' ? '⚠' : '✓'
}
function toolCls(t: ActivityTool): string {
  if (toolRunning(t)) return 'text-amber-400'
  return t.status === 'error' ? 'text-rose-400' : 'text-emerald-500'
}
function dur(ms?: number): string {
  if (!ms || ms <= 0) return ''
  const s = Math.round(ms / 1000)
  return s < 60 ? `${s}s` : `${Math.round(s / 60)}m`
}

// relative "12s / 3m / 1h" for the live dispatch stream timestamps.
function ago(ts?: string): string {
  if (!ts) return ''
  const t = Date.parse(ts)
  if (isNaN(t)) return ''
  const s = Math.max(0, Math.round((Date.now() - t) / 1000))
  if (s < 60) return `${s}s`
  if (s < 3600) return `${Math.round(s / 60)}m`
  return `${Math.round(s / 3600)}h`
}
</script>

<template>
  <div class="h-full flex flex-col bg-zinc-950 text-zinc-300 overflow-auto">
    <div class="border-b border-zinc-800 px-3 py-2 flex items-center gap-2 text-xs sticky top-0 bg-zinc-950 z-10">
      <span class="text-zinc-300 font-medium">Activity</span>
      <button class="ml-auto text-zinc-500 hover:text-zinc-200" title="refresh" @click="load">⟳</button>
    </div>
    <div v-if="err" class="px-3 py-2 text-rose-400 text-xs">{{ err }}</div>

    <!-- LIVE now: who's running work this moment -->
    <div class="px-3 py-2 border-b border-zinc-900">
      <div class="text-[10px] uppercase tracking-wide text-zinc-600 mb-1">Running now</div>
      <div v-if="!liveByModel.length" class="text-zinc-600 text-xs">nothing dispatched right now</div>
      <div v-for="m in liveByModel" :key="m.model" class="flex items-center gap-2 text-xs py-0.5">
        <span class="w-1.5 h-1.5 rounded-full bg-emerald-500 animate-pulse"></span>
        <span class="text-zinc-200 font-mono truncate">{{ m.model }}</span>
        <span class="text-zinc-600">{{ m.provider }}<span v-if="m.local && m.gpu" class="text-emerald-600"> · {{ m.gpu }}</span></span>
        <span class="ml-auto text-zinc-400">{{ m.count }} session{{ m.count === 1 ? '' : 's' }}</span>
        <span class="text-zinc-600">{{ k(m.tokens) }} tok</span>
      </div>
    </div>

    <!-- LIVE stream: the last dispatches, newest first — model · work · ↑in/↓out
         tokens · how long ago. The "stream of tokens" the details view promises;
         it ticks every ~2.5s while anything is running. -->
    <div class="px-3 py-2 border-b border-zinc-900">
      <div class="text-[10px] uppercase tracking-wide text-zinc-600 mb-1">Live dispatches</div>
      <div v-if="!(activity?.recent || []).length" class="text-zinc-600 text-xs">no recent model calls</div>
      <div v-for="(d, i) in (activity?.recent || [])" :key="i" class="flex items-center gap-2 text-[11px] py-0.5">
        <span class="text-zinc-300 font-mono truncate max-w-[38%]" :title="d.model">{{ d.model }}</span>
        <span class="text-zinc-500 truncate" :title="d.label + (d.session ? '  ·  ' + d.session : '')">{{ d.label || '—' }}</span>
        <span class="ml-auto text-emerald-600/90 tabular-nums" title="input tokens">↑{{ k(d.in_tokens) }}</span>
        <span class="text-sky-500/90 tabular-nums" title="output tokens">↓{{ k(d.out_tokens) }}</span>
        <span class="text-zinc-700 tabular-nums w-8 text-right">{{ ago(d.at) }}</span>
      </div>
    </div>

    <!-- NON-LLM activity: doc-extract (ClamAV scan + unpack), coder sandboxes,
         etc. — each is a container the box spawns. in-flight rows are live; an
         errored row (e.g. a doc-extract timeout) shows what a silent stall was. -->
    <div class="px-3 py-2 border-b border-zinc-900">
      <div class="text-[10px] uppercase tracking-wide text-zinc-600 mb-1">Tools &amp; sandboxes <span class="text-zinc-700 normal-case">· scans / extract / coder</span></div>
      <div v-if="!toolRows.length" class="text-zinc-600 text-xs">no recent tool runs</div>
      <div v-for="(t, i) in toolRows" :key="i" class="flex items-center gap-2 text-[11px] py-0.5" :title="t.error || t.status">
        <span :class="[toolCls(t), toolRunning(t) ? 'animate-pulse' : '']">{{ toolGlyph(t) }}</span>
        <span class="text-zinc-300 font-mono truncate">{{ t.tool }}</span>
        <span class="text-zinc-600 truncate">{{ t.server }}</span>
        <span v-if="t.status === 'error'" class="text-rose-400/80 truncate max-w-[35%]">{{ t.error }}</span>
        <span class="ml-auto text-zinc-700 tabular-nums">{{ toolRunning(t) ? dur(t.run_ms) || 'running' : (dur(t.run_ms) || ago(t.at)) }}</span>
      </div>
    </div>

    <!-- role aliases → members -->
    <div class="px-3 py-2 border-b border-zinc-900">
      <div class="text-[10px] uppercase tracking-wide text-zinc-600 mb-1">Role aliases</div>
      <div v-for="(members, alias) in byAlias" :key="alias" class="mb-2">
        <div class="text-zinc-300 text-xs font-medium">{{ alias }}</div>
        <div v-for="(mem, i) in members" :key="mem.provider + mem.model"
             class="flex items-center gap-2 text-[11px] pl-2 py-0.5" :class="{ 'opacity-40': !mem.enabled }">
          <span :title="mem.usable === false ? 'last probe: unusable' : 'usable'"
                class="w-1.5 h-1.5 rounded-full" :class="mem.usable === false ? 'bg-rose-600' : 'bg-emerald-600'"></span>
          <span class="text-zinc-300 font-mono truncate">{{ mem.model }}</span>
          <span class="text-zinc-600">{{ mem.provider }}</span>
          <span v-if="mem.is_local" class="text-[9px] text-emerald-500 border border-emerald-900 rounded px-1">local</span>
          <span v-if="!mem.enabled" class="text-[9px] text-zinc-500 border border-zinc-800 rounded px-1">disabled</span>
          <span v-else-if="isPreferred(members, i)" class="text-[9px] text-sky-500 border border-sky-900 rounded px-1">preferred</span>
          <span class="ml-auto text-zinc-700">p{{ mem.priority }}</span>
        </div>
      </div>
    </div>

    <!-- 24h rollup per provider/model -->
    <div class="px-3 py-2">
      <div class="text-[10px] uppercase tracking-wide text-zinc-600 mb-1">Last 24h — tokens & cost</div>
      <table class="w-full text-[11px]">
        <thead class="text-zinc-600">
          <tr><th class="text-left font-normal py-0.5">model</th><th class="text-right font-normal">calls</th><th class="text-right font-normal">in/out</th><th class="text-right font-normal">cost</th></tr>
        </thead>
        <tbody>
          <tr v-for="row in (activity?.by_provider || [])" :key="row.provider + row.model" class="border-t border-zinc-900">
            <td class="py-0.5"><span class="text-zinc-300 font-mono">{{ row.model }}</span> <span class="text-zinc-600">{{ row.provider }}</span></td>
            <td class="text-right text-zinc-400 tabular-nums">{{ row.calls }}</td>
            <td class="text-right text-zinc-500 tabular-nums">{{ k(row.in_tokens) }}/{{ k(row.out_tokens) }}</td>
            <td class="text-right text-zinc-300 tabular-nums">{{ usd(row.micro_usd) }}</td>
          </tr>
          <tr v-if="!(activity?.by_provider || []).length"><td colspan="4" class="text-zinc-600 py-1">no model calls in the last 24h</td></tr>
        </tbody>
      </table>
    </div>
  </div>
</template>
