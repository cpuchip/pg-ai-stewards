<script setup lang="ts">
// /graph — the GRAPHS HUB. Detangled 2026-07-06 (Michael: "/graph … seems like
// a separate thing from stewdio's worlds/cosmos and wiki's graphs").
//
// History, so nobody re-tangles it: this page was originally a flat cytoscape
// view over stewards.study_citations() — a function that NO LONGER EXISTS in
// the chain (the page rendered an honest-looking empty graph). Meanwhile two
// real graph systems shipped elsewhere: the Loreworks 3D worlds/cosmos
// (Stewdio's World panel — entities/edges per world, cross-world galaxies)
// and the wiki page-link graph (WikiReader's graph mode). This page now
// EMBEDS those two — same components, same stores, zero duplicated graph
// code — instead of being a third, dead thing.
import { ref } from 'vue'
import { useRouter } from 'vue-router'
import { onMounted } from 'vue'
import { api, type WikiBrief } from '@/api'
import WorldGraphPanel from './stewdio/WorldGraphPanel.vue'
import WikiGraphPanel from './wiki/WikiGraphPanel.vue'

const router = useRouter()
const tab = ref<'worlds' | 'wiki'>('worlds')

// wiki tab: same selector contract WikiReader uses
const wikis = ref<WikiBrief[]>([])
const wikiSel = ref('')
onMounted(async () => {
  try {
    const r = await api.wikiWikis()
    wikis.value = r.items || []
    if (!wikiSel.value && wikis.value[0]) wikiSel.value = wikis.value[0].slug
  } catch { /* wiki fleet optional */ }
})
function openPage(slug: string) {
  router.push(`/wiki/page/${encodeURIComponent(slug)}`)
}
</script>

<template>
  <div class="space-y-3 h-[calc(100dvh-9rem)] flex flex-col">
    <div class="flex items-center justify-between">
      <h2 class="text-2xl font-semibold tracking-tight">Graphs</h2>
      <div class="flex items-center gap-2 text-sm">
        <button @click="tab = 'worlds'"
                :class="tab === 'worlds' ? 'border-sky-600 text-sky-300 bg-sky-900/30' : 'border-zinc-700 text-zinc-400 hover:bg-zinc-800'"
                class="px-3 py-1 rounded border">🌌 Worlds &amp; Cosmos</button>
        <button @click="tab = 'wiki'"
                :class="tab === 'wiki' ? 'border-sky-600 text-sky-300 bg-sky-900/30' : 'border-zinc-700 text-zinc-400 hover:bg-zinc-800'"
                class="px-3 py-1 rounded border">📖 Wiki</button>
        <select v-if="tab === 'wiki' && wikis.length" v-model="wikiSel"
                class="bg-zinc-900 border border-zinc-700 rounded px-2 py-1 text-zinc-200 text-xs">
          <option v-for="w in wikis" :key="w.slug" :value="w.slug">{{ w.name || w.slug }}</option>
        </select>
      </div>
    </div>

    <!-- Worlds & Cosmos: the SAME panel Stewdio hosts (world picker, cosmos
         toggle, build, 💬 Loremaster chat, search/fly-to all live inside it). -->
    <WorldGraphPanel v-if="tab === 'worlds'" class="flex-1 min-h-0" />

    <!-- Wiki: page-link graph, 2D by design (read, not toured — see the
         panel's own header for the rationale). Node click opens the page. -->
    <WikiGraphPanel v-else-if="wikiSel" :wiki="wikiSel" class="flex-1 min-h-0" @open-page="openPage" />
    <p v-else class="text-sm text-zinc-500">No wikis yet — build one from a corpus and its page-link graph appears here.</p>
  </div>
</template>
