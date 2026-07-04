<script setup lang="ts">
// "Show the wiki the agent pulled... then diff that against the full source
// and see blind spots" (Michael). A "Sources pulled" tab body for any doc
// viewer: doc_pull_sources rendered as a mini-wiki (grouped by source doc,
// with counts) + a doc_blind_spots coverage banner (coverage_pct + the top
// never-touched items, click-through). Shared by ArtifactPanel (Stewdio) and
// StudyDetail (/studies/:slug) — each host wires `@open` to its own
// navigation (store.select in the cockpit, router.push on the standalone
// page) since this component doesn't know which context it's in.
//
// Rows from both functions are decoded GENERICALLY server-side (WIKI-CORE/92
// hadn't landed at the time this was written — see api/doc_sources.go's
// contract note), so every field access here is a best-effort `pick()` over a
// few plausible column names rather than a fixed shape. Degrades to a plain
// "not available" state when 92's functions aren't present, or an empty
// state for an older doc with no ledgered pull session.
import { ref, watch, computed } from 'vue'
import { api } from '@/api'

const props = defineProps<{ docRef: string }>()
const emit = defineEmits<{ open: [ref: string] }>()

const loading = ref(false)
const available = ref(true)
const err = ref('')
const sources = ref<Record<string, unknown>[]>([])
const blindRows = ref<Record<string, unknown>[]>([])
const coveragePct = ref<number | null>(null)

function pick(row: Record<string, unknown>, keys: string[]): string {
  for (const k of keys) {
    const v = row[k]
    if (v !== undefined && v !== null && String(v).trim() !== '') return String(v)
  }
  return ''
}
const refOf = (row: Record<string, unknown>) => pick(row, ['doc_slug', 'doc', 'source_doc', 'source', 'ref'])
const labelOf = (row: Record<string, unknown>) => pick(row, ['title', 'doc_slug', 'doc', 'source_doc', 'source', 'label', 'name']) || '(unlabeled source)'
const quoteOf = (row: Record<string, unknown>) => pick(row, ['quote', 'excerpt', 'snippet', 'anchor_text'])
const touched = (row: Record<string, unknown>) =>
  row['covered'] === true || row['touched'] === true || row['hit'] === true || row['pulled'] === true

const grouped = computed(() => {
  const m = new Map<string, { ref: string; rows: Record<string, unknown>[] }>()
  for (const s of sources.value) {
    const key = labelOf(s)
    if (!m.has(key)) m.set(key, { ref: refOf(s), rows: [] })
    m.get(key)!.rows.push(s)
  }
  return [...m.entries()].sort((a, b) => b[1].rows.length - a[1].rows.length)
})
const blindSpots = computed(() => blindRows.value.filter((r) => !touched(r)))
const coverageTone = computed(() => {
  const p = coveragePct.value
  if (p === null) return 'border-zinc-800 bg-zinc-900/40 text-zinc-300'
  if (p >= 80) return 'border-emerald-800/50 bg-emerald-900/20 text-emerald-300'
  if (p >= 40) return 'border-amber-800/50 bg-amber-900/20 text-amber-300'
  return 'border-rose-800/50 bg-rose-900/20 text-rose-300'
})

async function load() {
  if (!props.docRef) return
  loading.value = true
  err.value = ''
  try {
    const [ps, bs] = await Promise.all([api.docPullSources(props.docRef), api.docBlindSpots(props.docRef)])
    available.value = ps.available || bs.available
    sources.value = ps.sources ?? []
    blindRows.value = bs.rows ?? []
    coveragePct.value = typeof bs.coverage_pct === 'number' ? bs.coverage_pct : null
  } catch (e) {
    err.value = String(e)
  } finally {
    loading.value = false
  }
}
watch(() => props.docRef, load, { immediate: true })

function openRef(row: Record<string, unknown>) {
  const r = refOf(row)
  if (r) emit('open', r)
}
</script>

<template>
  <div class="space-y-4 text-sm">
    <div v-if="loading" class="text-zinc-500 text-xs">loading…</div>
    <div v-else-if="err" class="text-rose-400 text-xs">{{ err }}</div>
    <template v-else-if="!available">
      <div class="rounded border border-zinc-800 bg-zinc-900/50 text-zinc-500 text-xs px-3 py-2 leading-relaxed">
        Sources-pulled ledger isn't available yet — WIKI-CORE's <code class="text-zinc-400">doc_pull_sources</code> /
        <code class="text-zinc-400">doc_blind_spots</code> haven't landed in this database. This tab lights up
        automatically once they do.
      </div>
    </template>
    <template v-else>
      <div v-if="coveragePct !== null" class="rounded border px-3 py-2 flex items-baseline gap-2" :class="coverageTone">
        <span class="font-medium text-base">{{ coveragePct.toFixed(0) }}%</span>
        <span class="text-xs opacity-80">of the scoped source set was actually pulled into this doc</span>
      </div>

      <div v-if="!sources.length && !blindRows.length" class="text-zinc-600 text-xs">
        No ledgered pulls for this doc — it predates session ledgering, or nothing was retrieved.
      </div>

      <div v-if="sources.length">
        <div class="text-zinc-500 text-[11px] uppercase tracking-wide mb-1.5">Sources pulled ({{ sources.length }})</div>
        <div class="space-y-2">
          <div v-for="[key, g] in grouped" :key="key" class="rounded border border-zinc-800 bg-zinc-900/40 p-2">
            <button class="flex items-center justify-between w-full text-left text-[13px]"
                    :class="g.ref ? 'text-sky-400 hover:text-sky-300' : 'text-zinc-200 cursor-default'"
                    :disabled="!g.ref" @click="g.ref && emit('open', g.ref)">
              <span class="truncate">{{ key }}</span>
              <span class="text-zinc-600 text-[11px] shrink-0 ml-2">{{ g.rows.length }}×</span>
            </button>
            <ul class="mt-1 space-y-1">
              <li v-for="(row, i) in g.rows.slice(0, 6)" :key="i" class="text-zinc-500 text-[11px] pl-2 border-l border-zinc-800">
                <span v-if="quoteOf(row)" class="italic text-zinc-400">"{{ quoteOf(row) }}"</span>
                <span v-else class="font-mono">{{ JSON.stringify(row) }}</span>
              </li>
            </ul>
            <div v-if="g.rows.length > 6" class="text-zinc-700 text-[10px] mt-1">+ {{ g.rows.length - 6 }} more</div>
          </div>
        </div>
      </div>

      <div v-if="blindSpots.length">
        <div class="text-zinc-500 text-[11px] uppercase tracking-wide mb-1.5 mt-4">
          Blind spots — never touched ({{ blindSpots.length }})
        </div>
        <ul class="space-y-1">
          <li v-for="(row, i) in blindSpots.slice(0, 25)" :key="i" class="text-[12px] flex items-baseline gap-2">
            <span class="text-rose-400 shrink-0">○</span>
            <button v-if="refOf(row)" class="text-sky-400 hover:text-sky-300 truncate text-left" @click="openRef(row)">
              {{ labelOf(row) }}
            </button>
            <span v-else class="text-zinc-500 truncate">{{ labelOf(row) }}</span>
          </li>
        </ul>
        <div v-if="blindSpots.length > 25" class="text-zinc-700 text-[11px] mt-1">+ {{ blindSpots.length - 25 }} more</div>
      </div>
    </template>
  </div>
</template>
