<script setup lang="ts">
import { ref, onMounted, onUnmounted, computed } from 'vue'
import { useRouter, RouterLink } from 'vue-router'
import { api, scheduledApi, intakeApi, type DashboardResp, type ScheduledRunRow, type RigState, type ActivityResp, type IntakeSummaryResp } from '@/api'
import AutonomyBanner from '@/components/AutonomyBanner.vue'

const router = useRouter()

const data = ref<DashboardResp | null>(null)
const error = ref<string>('')
const loading = ref(false)

// PE-C.3 — last 7 scheduled runs
const scheduledRuns = ref<ScheduledRunRow[]>([])
const scheduledRunsError = ref('')

// Intake chip — the file_drops ledger's dashboard face (war-game 2026-07-07:
// "no failure without a face"). Independent of dashboard health; a failed
// read leaves the chip in its loading dash rather than flagging the page.
const intake = ref<IntakeSummaryResp | null>(null)
async function loadIntake() {
  try { intake.value = await intakeApi.summary() } catch { /* tolerated */ }
}

// Local rig (llama-chip) — control + state, so the GPUs can be freed for games.
const rig = ref<RigState | null>(null)
const rigErr = ref('')
const rigBusy = ref('')
const rigModelsLoaded = computed(() => (rig.value?.models ?? []).filter(m => m.state === 'healthy').length)

async function loadRig() {
  try { rig.value = await api.rigState(); rigErr.value = '' }
  catch (e) { rigErr.value = String(e) }
}
async function brainOn() {
  rigBusy.value = 'starting'; rigErr.value = ''
  try { await api.rigBrainOn() } catch (e) { rigErr.value = String(e) }
  finally { rigBusy.value = ''; await loadRig() }
}
async function brainOff() {
  rigBusy.value = 'freeing'; rigErr.value = ''
  try { await api.rigBrainOff() } catch (e) { rigErr.value = String(e) }
  finally { rigBusy.value = ''; await loadRig() }
}
async function toggleAutonomy() {
  const next = !(rig.value?.autonomy_paused)
  rigBusy.value = 'autonomy'; rigErr.value = ''
  try { await api.rigAutonomy(next) } catch (e) { rigErr.value = String(e) }
  finally { rigBusy.value = ''; await loadRig() }
}

// Model Activity — what model is doing what work right now, across ALL
// providers (not just the local rig). Polled on its own ~4s cadence,
// independent of the dashboard health refresh, and tolerant of failure.
const activity = ref<ActivityResp | null>(null)
const activityErr = ref('')
async function loadActivity() {
  try { activity.value = await api.activity(); activityErr.value = '' }
  catch (e) { activityErr.value = String(e) }
}

async function load() {
  loading.value = true
  error.value = ''
  try {
    data.value = await api.dashboard()
  } catch (e) {
    error.value = String(e)
  } finally {
    loading.value = false
  }
  loadRig() // independent of dashboard health; tolerates llama-chip being offline
  loadIntake() // ditto — the intake chip degrades to '—' if the read fails
  // Scheduled-runs is independent of dashboard health and tolerated to
  // fail without flagging the overall dashboard error.
  try {
    const r = await scheduledApi.recentRuns(7)
    scheduledRuns.value = r.items
    scheduledRunsError.value = ''
  } catch (e) {
    scheduledRunsError.value = String(e)
  }
}

let timer: number | undefined
let activityTimer: number | undefined
onMounted(() => {
  load()
  loadActivity()
  // 5s auto-refresh — cheap (single dashboard endpoint)
  timer = window.setInterval(load, 5000)
  // Activity has its own faster ~4s pulse — it's the "what's the brain
  // doing right now" glance, so it wants to feel live.
  activityTimer = window.setInterval(loadActivity, 4000)
})
onUnmounted(() => {
  if (timer) window.clearInterval(timer)
  if (activityTimer) window.clearInterval(activityTimer)
})

function fmtRelative(s?: string) {
  if (!s) return ''
  const d = new Date(s)
  if (isNaN(d.getTime())) return s
  const diffMs = Date.now() - d.getTime()
  const sec = Math.floor(diffMs / 1000)
  if (sec < 60) return `${sec}s ago`
  const min = Math.floor(sec / 60)
  if (min < 60) return `${min}m ago`
  const hr = Math.floor(min / 60)
  if (hr < 24) return `${hr}h ago`
  const days = Math.floor(hr / 24)
  return `${days}d ago`
}

// Token count -> compact form (27_100 -> "27.1k", 5_252_464 -> "5.3M").
function fmtTokens(n: number) {
  if (n == null) return '0'
  if (n < 1000) return String(n)
  if (n < 1_000_000) return (n / 1000).toFixed(1).replace(/\.0$/, '') + 'k'
  return (n / 1_000_000).toFixed(1).replace(/\.0$/, '') + 'M'
}
// micro-dollars -> "$0.0000". Sub-cent spend is the norm here.
function fmtUSD(micro: number) {
  return '$' + ((micro || 0) / 1e6).toFixed(4)
}

// First-load placeholders: before any response arrives, a tile must read as a
// neutral "loading" state — never "down"/"paused"/"offline" synthesized from
// still-empty data. dashReady gates the /api/dashboard tiles (pg, soak);
// rigReady gates the local-rig header. Once a response (or a real error) has
// landed, the tiles fall back to their live values.
const dashReady = computed(() => data.value !== null)
const rigReady = computed(() => rig.value !== null || !!rigErr.value)

const inFlightCount = computed(() => data.value?.in_flight?.length ?? 0)
const errorCount = computed(() => data.value?.recent_errors?.length ?? 0)
const activeWork = computed(() => activity.value?.active ?? [])
const recentDispatches = computed(() => activity.value?.recent ?? [])
const byProvider = computed(() => activity.value?.by_provider ?? [])
</script>

<template>
  <div class="space-y-6">
    <div class="flex items-baseline justify-between">
      <h2 class="text-2xl font-semibold tracking-tight">Dashboard</h2>
      <div class="text-xs text-zinc-500 flex items-center gap-3">
        <span v-if="loading" class="text-zinc-400">refreshing…</span>
        <span v-else-if="error" class="text-red-400">{{ error }}</span>
        <span v-else-if="data">updated {{ fmtRelative(new Date(data.fetched_at_ms).toISOString()) }}</span>
        <button
          class="text-xs px-2 py-1 rounded border border-zinc-700 hover:bg-zinc-800"
          @click="load"
        >
          refresh
        </button>
      </div>
    </div>

    <AutonomyBanner />

    <!-- Top row: 5 status cards (md wraps 3+2, lg is one row) -->
    <div class="grid grid-cols-1 md:grid-cols-3 lg:grid-cols-5 gap-4">
      <!-- pg health -->
      <div class="rounded-md border border-zinc-800 bg-zinc-900/50 p-4">
        <div class="text-xs uppercase tracking-wide text-zinc-500 mb-2">Postgres</div>
        <div class="flex items-center gap-2">
          <span
            class="inline-block w-2 h-2 rounded-full"
            :class="!dashReady ? 'bg-zinc-600 animate-pulse' : (data?.pg.ok ? 'bg-emerald-500' : 'bg-red-500')"
          ></span>
          <span class="text-lg font-semibold">
            {{ !dashReady ? 'loading…' : (data?.pg.ok ? 'healthy' : 'down') }}
          </span>
        </div>
        <div v-if="data?.pg.error" class="text-xs text-red-400 mt-1">
          {{ data.pg.error }}
        </div>
      </div>

      <!-- soak status -->
      <div class="rounded-md border border-zinc-800 bg-zinc-900/50 p-4">
        <div class="text-xs uppercase tracking-wide text-zinc-500 mb-2">Soak</div>
        <div class="flex items-center gap-2">
          <span
            class="inline-block w-2 h-2 rounded-full"
            :class="!dashReady ? 'bg-zinc-600 animate-pulse' : (data?.soak.schedule_enabled ? 'bg-emerald-500' : 'bg-zinc-600')"
          ></span>
          <span class="text-lg font-semibold">
            {{ !dashReady ? 'loading…' : (data?.soak.schedule_enabled ? 'on' : 'paused') }}
          </span>
        </div>
        <div class="text-xs text-zinc-400 mt-1">
          last: {{ fmtRelative(data?.soak.last_pass_started_at) || '—' }}
        </div>
      </div>

      <!-- dirty queue depth -->
      <div class="rounded-md border border-zinc-800 bg-zinc-900/50 p-4">
        <div class="text-xs uppercase tracking-wide text-zinc-500 mb-2">Dirty queue</div>
        <div class="text-2xl font-semibold tabular-nums">
          {{ data?.soak.dirty_queue_depth ?? '—' }}
        </div>
        <div class="text-xs text-zinc-400 mt-1">docs awaiting watchman</div>
      </div>

      <!-- in-flight -->
      <div class="rounded-md border border-zinc-800 bg-zinc-900/50 p-4">
        <div class="text-xs uppercase tracking-wide text-zinc-500 mb-2">In flight</div>
        <div class="text-2xl font-semibold tabular-nums">
          {{ inFlightCount }}
        </div>
        <div class="text-xs text-zinc-400 mt-1">active work_items</div>
      </div>

      <!-- intake — the file_drops ledger chip. Errors are the loud part:
           red count when any drop failed, calm zinc otherwise. Whole card
           links to Library → Intake. -->
      <RouterLink
        to="/library/intake"
        class="rounded-md border bg-zinc-900/50 p-4 block hover:bg-zinc-900"
        :class="(intake?.error_count ?? 0) > 0 ? 'border-red-800/60' : 'border-zinc-800'"
      >
        <div class="text-xs uppercase tracking-wide text-zinc-500 mb-2">Intake</div>
        <div class="text-2xl font-semibold tabular-nums">
          {{ intake ? intake.drops_today : '—' }}
        </div>
        <div class="text-xs mt-1">
          <span class="text-zinc-400">drops today · </span>
          <span
            v-if="(intake?.error_count ?? 0) > 0"
            class="text-red-400 font-semibold"
          >{{ intake!.error_count }} error(s)</span>
          <span v-else class="text-zinc-400">no errors</span>
        </div>
      </RouterLink>
    </div>

    <!-- Local rig control (llama-chip) — free the GPUs for games, bring the brain back -->
    <section class="rounded-md border border-zinc-800 bg-zinc-900/50 overflow-hidden">
      <div class="px-4 py-3 border-b border-zinc-800 flex items-center gap-2">
        <span
          class="inline-block w-2 h-2 rounded-full"
          :class="!rigReady ? 'bg-zinc-600 animate-pulse' : (rig?.llamachip_up ? 'bg-emerald-500' : 'bg-red-500')"
        ></span>
        <h3 class="text-sm font-semibold">Local rig — llama-chip</h3>
        <span class="text-xs text-zinc-500">
          {{ !rigReady ? 'connecting…' : (rig?.llamachip_up ? `${rigModelsLoaded} model(s) loaded` : 'offline') }}
        </span>
        <span
          v-if="rigReady"
          class="ml-auto text-xs px-2 py-0.5 rounded"
          :class="rig?.autonomy_paused ? 'bg-amber-900/40 text-amber-300' : 'bg-emerald-900/40 text-emerald-300'"
        >autonomy {{ rig?.autonomy_paused ? 'paused' : 'running' }}</span>
      </div>
      <div class="p-4 space-y-3">
        <div class="flex flex-wrap items-center gap-2">
          <button
            @click="brainOn"
            :disabled="!!rigBusy"
            class="text-sm px-3 py-1.5 rounded bg-emerald-700/80 hover:bg-emerald-700 disabled:opacity-50"
          >{{ rigBusy === 'starting' ? 'starting…' : '▶ Start brain' }}</button>
          <button
            @click="brainOff"
            :disabled="!!rigBusy"
            class="text-sm px-3 py-1.5 rounded border border-red-900 text-red-300 hover:bg-red-950/40 disabled:opacity-50"
          >{{ rigBusy === 'freeing' ? 'freeing…' : '■ Free GPUs (for games)' }}</button>
          <button
            @click="toggleAutonomy"
            :disabled="!!rigBusy"
            class="text-sm px-3 py-1.5 rounded border border-zinc-700 hover:bg-zinc-800 disabled:opacity-50"
          >{{ rig?.autonomy_paused ? 'Resume autonomy only' : 'Pause autonomy only' }}</button>
          <span class="text-xs text-zinc-500">
            Start = load the dance + resume · Free = pause + unload (frees both GPUs)
          </span>
        </div>
        <div v-if="rigErr" class="text-xs text-red-400">{{ rigErr }}</div>
        <div v-if="rig?.note" class="text-xs text-amber-400">{{ rig.note }}</div>

        <!-- GPU memory bars -->
        <div v-if="rig?.gpus?.length" class="grid grid-cols-1 sm:grid-cols-2 gap-3">
          <div v-for="g in rig.gpus" :key="g.index" class="text-xs">
            <div class="flex justify-between text-zinc-400 mb-1">
              <span>GPU {{ g.index }} <span class="text-zinc-600">{{ g.name }}</span></span>
              <span class="tabular-nums">{{ g.mem_used_mib }} / {{ g.mem_total_mib }} MiB · {{ g.util_pct }}%</span>
            </div>
            <div class="h-1.5 rounded bg-zinc-800 overflow-hidden">
              <div
                class="h-full rounded"
                :class="(g.mem_used_mib / g.mem_total_mib) > 0.85 ? 'bg-red-500' : 'bg-sky-500'"
                :style="{ width: Math.round(100 * g.mem_used_mib / Math.max(1, g.mem_total_mib)) + '%' }"
              ></div>
            </div>
          </div>
        </div>

        <!-- loaded models -->
        <div v-if="(rig?.models?.length ?? 0) > 0" class="flex flex-wrap gap-2">
          <span
            v-for="m in rig?.models"
            :key="m.name"
            class="text-xs px-2 py-0.5 rounded bg-zinc-800 text-zinc-300"
          >{{ m.name }} <span class="text-zinc-500">{{ m.state }}</span></span>
        </div>
        <div v-else-if="rig?.llamachip_up" class="text-xs text-zinc-500">
          No models loaded — GPUs are free. Click <b>Start brain</b> to load the dance.
        </div>
      </div>
    </section>

    <!-- Model Activity — what model is doing what work right now, across ALL
         providers (opencode_go, google_gemini, opencode_zen, nvidia,
         flexllama, lm_studio). Read-only introspection. -->
    <section class="rounded-md border border-zinc-800 bg-zinc-900/50 overflow-hidden">
      <div class="px-4 py-3 border-b border-zinc-800 flex items-center gap-2">
        <span
          class="inline-block w-2 h-2 rounded-full"
          :class="activeWork.length > 0 ? 'bg-emerald-500 animate-pulse' : 'bg-zinc-600'"
        ></span>
        <h3 class="text-sm font-semibold">Model activity</h3>
        <span class="text-xs text-zinc-500">
          {{ activeWork.length > 0 ? `${activeWork.length} dispatching now` : 'idle' }}
        </span>
        <span v-if="activityErr" class="ml-auto text-xs text-red-400">{{ activityErr }}</span>
      </div>

      <!-- Now working -->
      <div class="p-4 space-y-4">
        <div>
          <div class="text-xs uppercase tracking-wide text-zinc-500 mb-2">Now working</div>
          <div v-if="activeWork.length === 0" class="text-xs text-zinc-500">
            Nothing dispatching this instant — no model is mid-call.
          </div>
          <ul v-else class="space-y-1.5">
            <li
              v-for="a in activeWork"
              :key="a.slug"
              class="flex flex-wrap items-center gap-x-3 gap-y-1 text-sm rounded px-2 py-1.5 bg-zinc-900/60 hover:bg-zinc-900 cursor-pointer"
              @click="router.push(`/work-items/${a.slug}`)"
            >
              <span class="font-mono text-zinc-100">{{ a.model || '—' }}</span>
              <span
                class="text-xs px-1.5 py-0.5 rounded"
                :class="a.local ? 'bg-sky-900/50 text-sky-300' : 'bg-zinc-800 text-zinc-300'"
              >{{ a.provider || 'unknown' }}</span>
              <span
                v-if="a.gpu"
                class="text-xs px-1.5 py-0.5 rounded bg-emerald-900/40 text-emerald-300 font-mono"
              >{{ a.gpu }}</span>
              <span class="text-xs text-zinc-400">
                {{ a.pipeline }} · <span class="text-zinc-500">{{ a.stage }}</span>
              </span>
              <span class="text-xs font-mono text-zinc-500 truncate max-w-[16rem]">{{ a.slug }}</span>
              <span class="ml-auto text-xs tabular-nums text-zinc-400">{{ fmtTokens(a.tokens) }} tok</span>
              <span class="text-xs tabular-nums text-zinc-500">{{ fmtUSD(a.micro_usd) }}</span>
            </li>
          </ul>
        </div>

        <!-- Recent dispatches — the pulse across providers -->
        <div>
          <div class="text-xs uppercase tracking-wide text-zinc-500 mb-2">Recent dispatches</div>
          <div v-if="recentDispatches.length === 0" class="text-xs text-zinc-500">
            No dispatches recorded yet.
          </div>
          <ul v-else class="space-y-0.5">
            <li
              v-for="(r, i) in recentDispatches"
              :key="i"
              class="flex flex-wrap items-center gap-x-3 text-xs py-0.5"
            >
              <span class="font-mono text-zinc-200 min-w-[10rem]">{{ r.model }}</span>
              <span
                class="px-1.5 py-0.5 rounded"
                :class="(r.provider === 'flexllama' || r.provider === 'lm_studio') ? 'bg-sky-900/40 text-sky-300' : 'bg-zinc-800 text-zinc-400'"
              >{{ r.provider }}</span>
              <span class="text-zinc-500">{{ r.pipeline || '—' }}</span>
              <span class="tabular-nums text-zinc-400">
                {{ fmtTokens(r.in_tokens) }}<span class="text-zinc-600">→</span>{{ fmtTokens(r.out_tokens) }}
              </span>
              <span class="ml-auto text-zinc-500">{{ fmtRelative(r.at) }}</span>
            </li>
          </ul>
        </div>

        <!-- by provider (24h) -->
        <div v-if="byProvider.length > 0">
          <div class="text-xs uppercase tracking-wide text-zinc-500 mb-2">By provider · model (24h)</div>
          <table class="w-full text-xs">
            <thead class="text-zinc-600">
              <tr>
                <th class="text-left font-medium py-1">Provider</th>
                <th class="text-left font-medium py-1">Model</th>
                <th class="text-right font-medium py-1">Calls</th>
                <th class="text-right font-medium py-1">In</th>
                <th class="text-right font-medium py-1">Out</th>
                <th class="text-right font-medium py-1">$</th>
              </tr>
            </thead>
            <tbody>
              <tr v-for="(p, i) in byProvider" :key="i" class="border-t border-zinc-800/50">
                <td class="py-1">
                  <span
                    class="px-1.5 py-0.5 rounded"
                    :class="(p.provider === 'flexllama' || p.provider === 'lm_studio') ? 'bg-sky-900/40 text-sky-300' : 'bg-zinc-800 text-zinc-400'"
                  >{{ p.provider }}</span>
                </td>
                <td class="py-1 font-mono text-zinc-300">{{ p.model }}</td>
                <td class="py-1 text-right tabular-nums text-zinc-400">{{ p.calls.toLocaleString() }}</td>
                <td class="py-1 text-right tabular-nums text-zinc-400">{{ fmtTokens(p.in_tokens) }}</td>
                <td class="py-1 text-right tabular-nums text-zinc-400">{{ fmtTokens(p.out_tokens) }}</td>
                <td class="py-1 text-right tabular-nums text-zinc-500">{{ fmtUSD(p.micro_usd) }}</td>
              </tr>
            </tbody>
          </table>
        </div>
      </div>
    </section>

    <!-- In-flight detail table -->
    <section
      v-if="inFlightCount > 0"
      class="rounded-md border border-zinc-800 bg-zinc-900/50 overflow-hidden"
    >
      <div class="px-4 py-3 border-b border-zinc-800">
        <h3 class="text-sm font-semibold">In-flight work items</h3>
      </div>
      <table class="w-full text-sm">
        <thead class="text-zinc-500 text-xs uppercase tracking-wide">
          <tr>
            <th class="text-left px-4 py-2 font-medium">Slug</th>
            <th class="text-left px-4 py-2 font-medium">Pipeline</th>
            <th class="text-left px-4 py-2 font-medium">Stage</th>
            <th class="text-left px-4 py-2 font-medium">Status</th>
            <th class="text-right px-4 py-2 font-medium">Tokens</th>
            <th class="text-right px-4 py-2 font-medium">Updated</th>
          </tr>
        </thead>
        <tbody>
          <tr
            v-for="w in data?.in_flight ?? []"
            :key="w.id"
            class="border-t border-zinc-800/50 hover:bg-zinc-900 cursor-pointer"
            @click="router.push(`/work-items/${w.id}`)"
          >
            <td class="px-4 py-2 font-mono text-xs text-zinc-100">
              <span class="hover:underline">{{ w.slug }}</span>
            </td>
            <td class="px-4 py-2 text-zinc-300">{{ w.pipeline }}</td>
            <td class="px-4 py-2 text-zinc-300">{{ w.current_stage }}</td>
            <td class="px-4 py-2">
              <span
                class="inline-block px-2 py-0.5 rounded text-xs"
                :class="{
                  'bg-emerald-900/40 text-emerald-300': w.status === 'in_progress',
                  'bg-zinc-800 text-zinc-300': w.status === 'pending',
                  'bg-amber-900/40 text-amber-300': w.status === 'dispatched',
                }"
              >
                {{ w.status }}
              </span>
            </td>
            <td class="px-4 py-2 text-right tabular-nums text-zinc-400">
              {{ w.tokens_in.toLocaleString() }} / {{ w.tokens_out.toLocaleString() }}
            </td>
            <td class="px-4 py-2 text-right text-zinc-500 text-xs">
              {{ fmtRelative(w.updated_at) }}
            </td>
          </tr>
        </tbody>
      </table>
    </section>

    <!-- Recent errors -->
    <section
      v-if="errorCount > 0"
      class="rounded-md border border-red-900/40 bg-red-950/20 overflow-hidden"
    >
      <div class="px-4 py-3 border-b border-red-900/40 flex items-center gap-2">
        <span class="inline-block w-2 h-2 rounded-full bg-red-500"></span>
        <h3 class="text-sm font-semibold">Recent errors (24h)</h3>
        <span class="text-xs text-zinc-400">{{ errorCount }} item(s)</span>
      </div>
      <ul class="divide-y divide-red-900/30">
        <li
          v-for="e in data?.recent_errors ?? []"
          :key="e.id"
          class="px-4 py-3 text-sm"
        >
          <div class="flex items-baseline gap-3">
            <span class="font-mono text-xs text-zinc-500">#{{ e.id }}</span>
            <span class="text-zinc-300">{{ e.kind }}</span>
            <span class="text-zinc-500 text-xs">via {{ e.provider }}</span>
            <span class="ml-auto text-xs text-zinc-500">{{ fmtRelative(e.done_at) }}</span>
          </div>
          <div class="text-xs text-red-300 mt-1 font-mono whitespace-pre-wrap">
            {{ e.error }}
          </div>
        </li>
      </ul>
    </section>

    <!-- PE-C.3: Last 7 scheduled runs -->
    <section
      class="rounded-md border border-zinc-800 bg-zinc-900/50 overflow-hidden"
    >
      <div class="px-4 py-3 border-b border-zinc-800 flex items-center gap-2">
        <h3 class="text-sm font-semibold">Last 7 scheduled runs</h3>
        <RouterLink
          to="/scheduled"
          class="ml-auto py-2 text-xs text-zinc-400 hover:text-zinc-200"
        >manage schedules →</RouterLink>
      </div>
      <div v-if="scheduledRunsError" class="px-4 py-3 text-xs text-red-400">{{ scheduledRunsError }}</div>
      <div
        v-else-if="scheduledRuns.length === 0"
        class="px-4 py-3 text-xs text-zinc-500"
      >No scheduled runs yet. <RouterLink to="/scheduled" class="text-zinc-300 hover:text-zinc-100 underline">Add a schedule</RouterLink> or wait for <code class="font-mono">ai-news-7am</code> to fire.</div>
      <table v-else class="w-full text-sm">
        <thead class="text-zinc-500 text-xs uppercase tracking-wide">
          <tr>
            <th class="text-left px-4 py-2 font-medium">Schedule</th>
            <th class="text-left px-4 py-2 font-medium">Pipeline</th>
            <th class="text-left px-4 py-2 font-medium">Stage</th>
            <th class="text-left px-4 py-2 font-medium">Status</th>
            <th class="text-right px-4 py-2 font-medium">When</th>
          </tr>
        </thead>
        <tbody>
          <tr
            v-for="r in scheduledRuns"
            :key="r.work_item_id"
            class="border-t border-zinc-800/50 hover:bg-zinc-900 cursor-pointer"
            @click="router.push(`/work-items/${r.work_item_id}`)"
          >
            <td class="px-4 py-2 font-mono text-xs text-zinc-100">{{ r.schedule_slug || r.slug }}</td>
            <td class="px-4 py-2 text-zinc-300">{{ r.pipeline_family }}</td>
            <td class="px-4 py-2 text-zinc-300">{{ r.current_stage || '—' }}</td>
            <td class="px-4 py-2">
              <span
                class="inline-block px-2 py-0.5 rounded text-xs"
                :class="{
                  'bg-emerald-900/40 text-emerald-300': r.status === 'completed',
                  'bg-blue-900/40 text-blue-300': r.status === 'in_progress',
                  'bg-zinc-800 text-zinc-300': r.status === 'pending',
                  'bg-amber-900/40 text-amber-300': r.status === 'awaiting_review',
                  'bg-red-900/40 text-red-300': r.status === 'failed' || r.status === 'quarantined',
                }"
              >{{ r.status }}</span>
            </td>
            <td class="px-4 py-2 text-right text-zinc-500 text-xs">
              {{ fmtRelative(r.completed_at || r.created_at) }}
            </td>
          </tr>
        </tbody>
      </table>
    </section>

    <div
      v-if="!loading && inFlightCount === 0 && errorCount === 0 && data"
      class="text-sm text-zinc-500"
    >
      Quiet substrate — no in-flight work, no recent errors.
    </div>
  </div>
</template>
