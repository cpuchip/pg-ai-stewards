<script setup lang="ts">
// The human-facing search page ("give the human the models' search" — 93).
// One input, three ranked panes over the same stewards.docs corpus: Hybrid
// (RRF + the 93 recall boost — reading a result bumps its usage, same
// signal an agent's doc_search tool call feeds), Keyword (the bare FTS leg,
// for comparison), and Graph (1-hop neighbors of the top hybrid hit). Every
// row carries a "+ wiki" action to collect it into a wiki (lab-and-wiki
// Part 2) — see wiki.go's INTEGRATION NOTE for what's unverified there.
import { ref, computed, onMounted, watch, nextTick } from 'vue'
import { useRoute, useRouter, RouterLink } from 'vue-router'
import { searchApi, wikiApi, type GlobalSearchResp, type GlobalSearchHit, type WikiCollectBrief } from '@/api'
import { searchFocusRequest } from '@/searchShortcut'

const route = useRoute()
const router = useRouter()

const inputEl = ref<HTMLInputElement | null>(null)
const query = ref(String(route.query.q ?? ''))
const result = ref<GlobalSearchResp | null>(null)
const loading = ref(false)
const error = ref('')
const selected = ref(-1) // index into result.hybrid, for arrow-key navigation

function focusInput() {
  nextTick(() => inputEl.value?.focus())
}
onMounted(focusInput)
watch(searchFocusRequest, focusInput)

async function runSearch() {
  const q = query.value.trim()
  router.replace({ path: '/search', query: q ? { q } : {} })
  if (!q) {
    result.value = null
    return
  }
  loading.value = true
  error.value = ''
  selected.value = -1
  try {
    result.value = await searchApi.search(q, 10)
  } catch (e) {
    error.value = String(e)
  } finally {
    loading.value = false
  }
}

onMounted(() => {
  if (query.value.trim()) runSearch()
})

function onInputKeydown(e: KeyboardEvent) {
  const hits = result.value?.hybrid ?? []
  if (e.key === 'ArrowDown') {
    e.preventDefault()
    if (hits.length) selected.value = Math.min(selected.value + 1, hits.length - 1)
  } else if (e.key === 'ArrowUp') {
    e.preventDefault()
    if (hits.length) selected.value = Math.max(selected.value - 1, 0)
  } else if (e.key === 'Enter') {
    const picked = selected.value >= 0 ? hits[selected.value] : undefined
    if (picked) {
      openResult(picked)
    } else {
      runSearch()
    }
  }
}

function openResult(h: GlobalSearchHit) {
  router.push(`/studies/${encodeURIComponent(h.slug)}`)
}

// "+ wiki" popover — one open at a time, keyed by result slug.
const wikiMenuFor = ref<string | null>(null)
const wikiList = ref<WikiCollectBrief[]>([])
const wikiListNote = ref('')
const wikiListLoading = ref(false)
const newWikiTitle = ref('')
const showNewWikiInput = ref(false)
const wikiBusy = ref<string | null>(null) // slug currently being added, for a small "added" flash
const wikiAdded = ref<Record<string, string>>({}) // slug -> wiki title, for a confirmation line

async function toggleWikiMenu(h: GlobalSearchHit) {
  if (wikiMenuFor.value === h.slug) {
    wikiMenuFor.value = null
    return
  }
  wikiMenuFor.value = h.slug
  showNewWikiInput.value = false
  newWikiTitle.value = ''
  wikiListLoading.value = true
  try {
    const r = await wikiApi.list()
    wikiList.value = r.items
    wikiListNote.value = r.note ?? ''
  } catch (e) {
    wikiListNote.value = String(e)
    wikiList.value = []
  } finally {
    wikiListLoading.value = false
  }
}

function slugify(s: string): string {
  return s.toLowerCase().trim().replace(/[^a-z0-9]+/g, '-').replace(/(^-|-$)/g, '') || 'wiki'
}

async function addToExisting(h: GlobalSearchHit, wiki: WikiCollectBrief) {
  wikiBusy.value = h.slug
  try {
    await wikiApi.add({
      wiki_slug: wiki.slug,
      result_slug: h.slug,
      result_title: h.title || h.slug,
      result_kind: h.kind,
    })
    wikiAdded.value[h.slug] = wiki.title || wiki.slug
    wikiMenuFor.value = null
  } catch (e) {
    error.value = String(e)
  } finally {
    wikiBusy.value = null
  }
}

async function addToNew(h: GlobalSearchHit) {
  const title = newWikiTitle.value.trim()
  if (!title) return
  wikiBusy.value = h.slug
  try {
    await wikiApi.add({
      new_wiki: { slug: slugify(title), title, kind: 'personal' },
      result_slug: h.slug,
      result_title: h.title || h.slug,
      result_kind: h.kind,
    })
    wikiAdded.value[h.slug] = title
    wikiMenuFor.value = null
  } catch (e) {
    error.value = String(e)
  } finally {
    wikiBusy.value = null
  }
}

const hasResult = computed(() => result.value !== null)
</script>

<template>
  <div class="space-y-4">
    <h2 class="text-2xl font-semibold tracking-tight">Search</h2>

    <form class="flex gap-2" @submit.prevent="runSearch">
      <input
        ref="inputEl"
        v-model="query"
        type="text"
        placeholder="search docs, memory, and the graph… ( / to focus )"
        class="flex-1 px-3 py-2 min-h-[44px] rounded border border-zinc-700 bg-zinc-900 text-sm focus:border-zinc-500 focus:outline-none"
        @keydown="onInputKeydown"
      />
      <button
        type="submit"
        class="px-4 py-2 min-h-[44px] rounded border border-zinc-700 hover:bg-zinc-800 text-sm shrink-0"
      >
        search
      </button>
    </form>

    <p v-if="loading" class="text-sm text-zinc-400">searching…</p>
    <p v-else-if="error" class="text-sm text-red-400">{{ error }}</p>

    <div v-if="hasResult" class="grid grid-cols-1 md:grid-cols-3 gap-4">
      <!-- Hybrid -->
      <section class="rounded-md border border-zinc-800 bg-zinc-900/50 overflow-hidden">
        <div class="px-3 py-2 border-b border-zinc-800 text-xs uppercase tracking-wide text-zinc-500 flex items-baseline justify-between">
          <span>Hybrid</span>
          <span class="text-zinc-600 normal-case">RRF + recall</span>
        </div>
        <ul class="divide-y divide-zinc-800">
          <li
            v-for="(h, i) in result!.hybrid"
            :key="h.slug"
            class="p-3 hover:bg-zinc-900"
            :class="{ 'bg-zinc-800/60': i === selected }"
          >
            <div class="flex items-start justify-between gap-2">
              <RouterLink :to="`/studies/${encodeURIComponent(h.slug)}`" class="block min-w-0 flex-1">
                <div class="flex items-baseline gap-2 flex-wrap">
                  <span class="font-medium text-zinc-100 truncate">{{ h.title || h.slug }}</span>
                  <span v-if="h.kind" class="text-[10px] px-1.5 py-0.5 rounded border border-zinc-700 text-zinc-400 shrink-0">{{ h.kind }}</span>
                </div>
                <div v-if="h.snippet" class="text-xs text-zinc-400 mt-1" v-html="h.snippet"></div>
              </RouterLink>
              <button
                class="shrink-0 text-xs px-2 py-1 min-h-[32px] rounded border border-zinc-700 hover:bg-zinc-800 text-zinc-300"
                @click.stop="toggleWikiMenu(h)"
              >+ wiki</button>
            </div>
            <div v-if="wikiAdded[h.slug]" class="text-[11px] text-emerald-400 mt-1">added to “{{ wikiAdded[h.slug] }}”</div>

            <!-- the +wiki picker -->
            <div v-if="wikiMenuFor === h.slug" class="mt-2 rounded border border-zinc-700 bg-zinc-950 p-2 text-xs space-y-1">
              <p v-if="wikiListLoading" class="text-zinc-500">loading wikis…</p>
              <template v-else>
                <p v-if="wikiListNote" class="text-zinc-500 italic">{{ wikiListNote }}</p>
                <button
                  v-for="w in wikiList" :key="w.slug"
                  class="block w-full text-left px-2 py-1.5 min-h-[32px] rounded hover:bg-zinc-800 text-zinc-300"
                  :disabled="wikiBusy === h.slug"
                  @click="addToExisting(h, w)"
                >{{ w.title || w.slug }}</button>
                <button
                  v-if="!showNewWikiInput"
                  class="block w-full text-left px-2 py-1.5 min-h-[32px] rounded hover:bg-zinc-800 text-sky-400"
                  @click="showNewWikiInput = true"
                >+ new collection…</button>
                <div v-else class="flex gap-1 pt-1">
                  <input
                    v-model="newWikiTitle"
                    type="text"
                    placeholder="new collection title"
                    class="flex-1 min-w-0 px-2 py-1.5 min-h-[32px] rounded border border-zinc-700 bg-zinc-900"
                    @keydown.enter.prevent="addToNew(h)"
                  />
                  <button
                    class="px-2 py-1.5 min-h-[32px] rounded border border-zinc-700 hover:bg-zinc-800 shrink-0"
                    :disabled="wikiBusy === h.slug || !newWikiTitle.trim()"
                    @click="addToNew(h)"
                  >create</button>
                </div>
              </template>
            </div>
          </li>
          <li v-if="result!.hybrid.length === 0" class="p-6 text-sm text-zinc-500 text-center">no hits</li>
        </ul>
      </section>

      <!-- Keyword -->
      <section class="rounded-md border border-zinc-800 bg-zinc-900/50 overflow-hidden">
        <div class="px-3 py-2 border-b border-zinc-800 text-xs uppercase tracking-wide text-zinc-500">
          Keyword <span class="text-zinc-600 normal-case">(raw FTS)</span>
        </div>
        <ul class="divide-y divide-zinc-800">
          <li v-for="h in result!.keyword" :key="h.slug" class="p-3 hover:bg-zinc-900">
            <RouterLink :to="`/studies/${encodeURIComponent(h.slug)}`" class="block">
              <div class="flex items-baseline gap-2 flex-wrap">
                <span class="font-medium text-zinc-100 truncate">{{ h.title || h.slug }}</span>
                <span v-if="h.kind" class="text-[10px] px-1.5 py-0.5 rounded border border-zinc-700 text-zinc-400 shrink-0">{{ h.kind }}</span>
              </div>
              <div v-if="h.snippet" class="text-xs text-zinc-400 mt-1" v-html="h.snippet"></div>
            </RouterLink>
          </li>
          <li v-if="result!.keyword.length === 0" class="p-6 text-sm text-zinc-500 text-center">no hits</li>
        </ul>
      </section>

      <!-- Graph -->
      <section class="rounded-md border border-zinc-800 bg-zinc-900/50 overflow-hidden">
        <div class="px-3 py-2 border-b border-zinc-800 text-xs uppercase tracking-wide text-zinc-500">
          Graph <span class="text-zinc-600 normal-case">{{ result!.graph_of ? `neighbors of ${result!.graph_of}` : '' }}</span>
        </div>
        <ul class="divide-y divide-zinc-800">
          <li v-for="g in result!.graph" :key="g.slug" class="p-3 hover:bg-zinc-900">
            <RouterLink :to="`/studies/${encodeURIComponent(g.slug)}`" class="block">
              <div class="flex items-baseline gap-2 justify-between">
                <span class="font-medium text-zinc-100 truncate">{{ g.title || g.slug }}</span>
                <span v-if="g.score" class="text-xs text-zinc-500 tabular-nums shrink-0">{{ g.score.toFixed(3) }}</span>
              </div>
            </RouterLink>
          </li>
          <li v-if="result!.graph.length === 0" class="p-6 text-sm text-zinc-500 text-center">
            no similarity edges yet
            <div class="text-[11px] mt-1">(run stewards.refresh_doc_similarity for the top hit)</div>
          </li>
        </ul>
      </section>
    </div>
  </div>
</template>
