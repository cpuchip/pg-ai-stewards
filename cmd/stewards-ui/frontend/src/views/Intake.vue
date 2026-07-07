<script setup lang="ts">
// Library → Intake: the stewards.file_drops ledger's face (war-game
// 2026-07-07, SKEPTIC attack #1: a table born with zero UI surface meant a
// failed drop died invisibly; SYNTHESIS: "no failure without a face").
// Reads /api/intake/drops — newest first, status filter, Studies-style
// load-more pagination. status=error rows carry the real error message,
// expandable in place.
import { ref, onMounted } from 'vue'
import { RouterLink } from 'vue-router'
import { intakeApi, type IntakeDropsResp, type FileDropRow } from '@/api'

const PAGE_SIZE = 100

const list = ref<IntakeDropsResp | null>(null)
const error = ref('')
const loading = ref(false)
const loadingMore = ref(false)
const offset = ref(0)
// '' = all. The filter is a 3-state enum, so segmented buttons beat a
// dropdown — one click, current state always visible.
const statusFilter = ref<'' | 'ingested' | 'skipped_unchanged' | 'error'>('')

const FILTERS = [
  { key: '', label: 'All' },
  { key: 'ingested', label: 'Ingested' },
  { key: 'skipped_unchanged', label: 'Skipped' },
  { key: 'error', label: 'Errors' },
] as const

async function load() {
  loading.value = true
  error.value = ''
  offset.value = 0
  try {
    list.value = await intakeApi.drops({
      status: statusFilter.value || undefined,
      limit: PAGE_SIZE,
      offset: 0,
    })
  } catch (e) {
    error.value = String(e)
  } finally {
    loading.value = false
  }
}

async function loadMore() {
  if (!list.value || loadingMore.value) return
  loadingMore.value = true
  try {
    const next = offset.value + PAGE_SIZE
    const r = await intakeApi.drops({
      status: statusFilter.value || undefined,
      limit: PAGE_SIZE,
      offset: next,
    })
    list.value = { ...r, items: [...list.value.items, ...r.items] }
    offset.value = next
  } catch (e) {
    error.value = String(e)
  } finally {
    loadingMore.value = false
  }
}

function setFilter(key: typeof statusFilter.value) {
  statusFilter.value = key
  load()
}

onMounted(load)

// The status face — one glyph + word + tone per ledger state. The error
// face is deliberately the loudest thing on the page.
function statusFace(s: FileDropRow['status']): { glyph: string; label: string; cls: string } {
  switch (s) {
    case 'ingested':
      return { glyph: '✓', label: 'ingested', cls: 'bg-emerald-900/40 text-emerald-300 border-emerald-700/50' }
    case 'skipped_unchanged':
      return { glyph: '∅', label: 'skipped', cls: 'bg-zinc-800 text-zinc-400 border-zinc-700' }
    case 'error':
      return { glyph: '✗', label: 'error', cls: 'bg-red-900/40 text-red-300 border-red-700/60' }
  }
}

// routed_to is 'doc:<id> slug:<slug>' or 'corpus:<name> attachment:<id>' —
// the slug: token is the linkable doc; anything else renders as plain text.
function routedSlug(routed?: string): string {
  const m = /(?:^|\s)slug:(\S+)/.exec(routed ?? '')
  return m?.[1] ?? ''
}

function fmtBytes(n: number): string {
  if (!n) return '—'
  if (n < 1024) return `${n} B`
  if (n < 1024 * 1024) return `${(n / 1024).toFixed(1)} KB`
  return `${(n / (1024 * 1024)).toFixed(1)} MB`
}

function fmtDate(s?: string) {
  if (!s) return ''
  return new Date(s).toLocaleString()
}
</script>

<template>
  <div class="space-y-4">
    <div class="flex items-center justify-between flex-wrap gap-2">
      <div class="flex items-center gap-2 text-sm">
        <button
          v-for="f in FILTERS" :key="f.key"
          @click="setFilter(f.key)"
          class="px-3 py-1 rounded border"
          :class="statusFilter === f.key
            ? 'border-sky-600 text-sky-300 bg-sky-900/30'
            : 'border-zinc-700 text-zinc-400 hover:bg-zinc-800'"
        >
          {{ f.label }}<span
            v-if="f.key === 'error' && (list?.error_count ?? 0) > 0"
            class="ml-1.5 text-red-300 tabular-nums"
          >{{ list?.error_count }}</span>
        </button>
      </div>
      <span v-if="list" class="text-xs text-zinc-500">
        {{ list.total.toLocaleString() }} drop(s)
      </span>
    </div>

    <p v-if="loading" class="text-sm text-zinc-400">loading…</p>
    <p v-else-if="error" class="text-sm text-red-400">{{ error }}</p>

    <!-- Empty states — designed, not defaulted -->
    <div
      v-else-if="list && list.items.length === 0 && !statusFilter"
      class="rounded-md border border-zinc-800 bg-zinc-900/50 p-8 text-center text-sm text-zinc-500"
    >
      <p class="text-zinc-300 mb-1">No files have been dropped yet.</p>
      <p>
        Put a file under <code class="font-mono text-zinc-400">./drop/&lt;project&gt;/</code> and the
        bridge ingests it within ~30s — every drop lands here, including the failures.
      </p>
    </div>
    <div
      v-else-if="list && list.items.length === 0 && statusFilter === 'error'"
      class="rounded-md border border-zinc-800 bg-zinc-900/50 p-8 text-center text-sm text-zinc-500"
    >
      No errors — every drop either ingested or was skipped as unchanged.
    </div>
    <div
      v-else-if="list && list.items.length === 0"
      class="rounded-md border border-zinc-800 bg-zinc-900/50 p-8 text-center text-sm text-zinc-500"
    >
      No drops with this status.
    </div>

    <div
      v-else-if="list"
      class="rounded-md border border-zinc-800 bg-zinc-900/50 overflow-hidden"
    >
      <table class="w-full text-sm">
        <thead class="text-zinc-500 text-xs uppercase tracking-wide">
          <tr>
            <th class="text-left px-4 py-2 font-medium">Status</th>
            <th class="text-left px-4 py-2 font-medium">Path</th>
            <th class="text-left px-4 py-2 font-medium">Routed to</th>
            <th class="text-right px-4 py-2 font-medium">Size</th>
            <th class="text-right px-4 py-2 font-medium">First seen</th>
          </tr>
        </thead>
        <tbody>
          <tr
            v-for="fd in list.items"
            :key="fd.id"
            class="border-t border-zinc-800/50 align-top"
            :class="fd.status === 'error' ? 'bg-red-950/10' : 'hover:bg-zinc-900'"
          >
            <td class="px-4 py-2 whitespace-nowrap">
              <span
                class="inline-flex items-center gap-1 px-2 py-0.5 rounded border text-xs font-mono"
                :class="statusFace(fd.status).cls"
              >{{ statusFace(fd.status).glyph }} {{ statusFace(fd.status).label }}</span>
            </td>
            <td class="px-4 py-2">
              <div class="font-mono text-xs text-zinc-200 break-all">{{ fd.path }}</div>
              <div v-if="fd.project_hint" class="text-xs text-zinc-500 mt-0.5">
                project: {{ fd.project_hint }}
              </div>
              <details v-if="fd.error" class="mt-1">
                <summary class="cursor-pointer text-xs text-red-400 hover:text-red-300">
                  why it failed
                </summary>
                <pre class="mt-1 text-xs font-mono text-red-300 whitespace-pre-wrap">{{ fd.error }}</pre>
              </details>
            </td>
            <td class="px-4 py-2">
              <!-- inline-block py-1.5 -my-1 widens the tap target to ≥24px
                   (ui-lint hard rule) without moving the row's text baseline -->
              <RouterLink
                v-if="routedSlug(fd.routed_to)"
                :to="`/studies/${encodeURIComponent(routedSlug(fd.routed_to))}`"
                class="text-sky-400 hover:text-sky-300 text-xs font-mono inline-block py-1.5 -my-1"
              >{{ routedSlug(fd.routed_to) }} →</RouterLink>
              <span v-else-if="fd.routed_to" class="text-xs font-mono text-zinc-400">{{ fd.routed_to }}</span>
              <span v-else class="text-xs text-zinc-600">—</span>
            </td>
            <td class="px-4 py-2 text-right tabular-nums text-zinc-500 text-xs whitespace-nowrap">
              {{ fmtBytes(fd.size_bytes) }}
            </td>
            <td class="px-4 py-2 text-right text-zinc-500 text-xs whitespace-nowrap">
              {{ fmtDate(fd.first_seen_at) }}
            </td>
          </tr>
        </tbody>
      </table>
    </div>

    <!-- Studies' load-more pattern: no silent row cap -->
    <div
      v-if="list && list.items.length < list.total"
      class="flex items-center justify-between text-xs text-zinc-500 px-1"
    >
      <span>showing {{ list.items.length.toLocaleString() }} of {{ list.total.toLocaleString() }}</span>
      <button
        class="px-3 py-1.5 rounded border border-zinc-700 hover:bg-zinc-800 text-zinc-200 disabled:opacity-50"
        :disabled="loadingMore"
        @click="loadMore"
      >
        {{ loadingMore ? 'loading…' : 'load more' }}
      </button>
    </div>
  </div>
</template>
