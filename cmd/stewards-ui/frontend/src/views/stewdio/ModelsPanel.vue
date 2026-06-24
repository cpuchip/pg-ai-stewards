<script setup lang="ts">
// Stewdio models panel — what's available, how it's registered under role
// aliases (reason / ingest / critic / vision), and LIVE usage: which models are
// running work right now (e.g. "3 sessions on gemini-3-flash"), plus 24h token +
// cost rollups per provider/model. Complements the GPU/pool view (local rig) by
// covering ALL providers. Reads /api/models/aliases + /api/activity.
import { ref, computed, onMounted, onUnmounted } from 'vue'
import { api, type AliasRow, type ActivityResp, type ActivityActive } from '@/api'

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
onMounted(() => { load(); timer = window.setInterval(load, 8000) })
onUnmounted(() => { if (timer) window.clearInterval(timer) })

// aliases grouped: reason → [members…], lowest priority (preferred) first.
const byAlias = computed(() => {
  const m: Record<string, AliasRow[]> = {}
  for (const a of aliases.value) (m[a.alias] ||= []).push(a)
  return m
})

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
</script>

<template>
  <div class="h-full flex flex-col bg-zinc-950 text-zinc-300 overflow-auto">
    <div class="border-b border-zinc-800 px-3 py-2 flex items-center gap-2 text-xs sticky top-0 bg-zinc-950 z-10">
      <span class="text-zinc-300 font-medium">Models</span>
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

    <!-- role aliases → members -->
    <div class="px-3 py-2 border-b border-zinc-900">
      <div class="text-[10px] uppercase tracking-wide text-zinc-600 mb-1">Role aliases</div>
      <div v-for="(members, alias) in byAlias" :key="alias" class="mb-2">
        <div class="text-zinc-300 text-xs font-medium">{{ alias }}</div>
        <div v-for="(mem, i) in members" :key="mem.provider + mem.model"
             class="flex items-center gap-2 text-[11px] pl-2 py-0.5">
          <span :title="mem.usable === false ? 'last probe: unusable' : 'usable'"
                class="w-1.5 h-1.5 rounded-full" :class="mem.usable === false ? 'bg-rose-600' : 'bg-emerald-600'"></span>
          <span class="text-zinc-300 font-mono truncate">{{ mem.model }}</span>
          <span class="text-zinc-600">{{ mem.provider }}</span>
          <span v-if="i === 0" class="text-[9px] text-sky-500 border border-sky-900 rounded px-1">preferred</span>
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
