<script setup lang="ts">
// The wiki-scoped live graph — nodes = pages (+ optional source docs as dimmer
// nodes via `includeDocs`), edges = page_links. Reuses the app's existing 2D
// Cytoscape pattern (Graph.vue's studies-citations graph) rather than the 3D
// force-graph WorldGraphPanel/CosmosPanel use.
//
// 2D over 3D, deliberately: the World/Cosmos panels earn 3D because they're a
// showpiece constellation over hundreds-to-thousands of entities where depth
// and orbit sell the "living graph" feel. A wiki graph is read, not toured —
// its whole job is "which pages connect to which, and can I read the label
// while doing it." Cytoscape's flat layout + horizontal text keeps labels
// legible at a glance; a 3D camera fighting for readable text on a
// vocabulary-dense wiki (short page titles, lots of them) would cost more
// than it'd add. Same call Graph.vue already made for the citations graph.
import { ref, onMounted, onUnmounted, watch, useTemplateRef } from 'vue'
import cytoscape from 'cytoscape'
import type { Core, NodeSingular } from 'cytoscape'
import { api, type WikiGraphNode } from '@/api'

const props = defineProps<{
  wiki?: string
  // search-highlight seam: a plain substring filter today. If the WIKI-SEARCH
  // builder's search API becomes reachable, swap the `matches` computed below
  // for a query against it — everything downstream (the highlight/fade split)
  // stays the same, it just needs the matching id set.
  highlight?: string
}>()
const emit = defineEmits<{ 'open-page': [slug: string] }>()

const containerRef = useTemplateRef<HTMLDivElement>('container')
const loading = ref(false)
const error = ref('')
const available = ref(true)
const includeDocs = ref(false)
const query = ref(props.highlight ?? '')
const stats = ref<{ nodes: number; edges: number } | null>(null)
let cy: Core | null = null

const STATUS_COLOR: Record<string, string> = {
  published: '#34d399', // emerald
  draft: '#38bdf8',      // sky
  stub: '#71717a',       // zinc
  superseded: '#f43f5e', // rose
}
function nodeColor(n: WikiGraphNode): string {
  if (n.is_doc) return '#3f3f46'
  if (!n.exists) return '#18181b' // red link — near-black fill, rose border does the talking
  return STATUS_COLOR[n.status ?? ''] ?? '#a1a1aa'
}
function nodeBorder(n: WikiGraphNode): string {
  if (!n.exists) return '#f43f5e'
  if (n.is_doc) return '#52525b'
  return STATUS_COLOR[n.status ?? ''] ?? '#a1a1aa'
}

// Cytoscape's own element data drives node coloring directly (nodeColor/
// nodeBorder read the element passed in) — no separate lookup map needed.
// This legend list is a real `ref`, set directly in `load()` whenever the
// graph reloads (a plain closure variable wouldn't be tracked by Vue).
const statusesPresent = ref<string[]>([])

async function load() {
  loading.value = true
  error.value = ''
  try {
    const g = await api.wikiGraph(props.wiki, includeDocs.value)
    available.value = g.available
    stats.value = { nodes: g.nodes.length, edges: g.edges.length }
    statusesPresent.value = [...new Set(
      g.nodes.filter((n) => n.status && n.exists && !n.is_doc).map((n) => n.status as string),
    )].sort()
    if (cy) cy.destroy()
    if (!containerRef.value) return
    cy = cytoscape({
      container: containerRef.value,
      elements: [
        ...g.nodes.map((n) => ({
          data: { id: n.id, label: n.label, status: n.status, exists: n.exists, is_doc: n.is_doc },
        })),
        ...g.edges.map((e, i) => ({
          data: { id: `e${i}-${e.source}->${e.target}`, source: e.source, target: e.target, kind: e.kind },
        })),
      ],
      style: [
        {
          selector: 'node',
          style: {
            'background-color': (el: NodeSingular) => nodeColor(el.data() as WikiGraphNode),
            'border-color': (el: NodeSingular) => nodeBorder(el.data() as WikiGraphNode),
            'border-width': 1.5,
            'border-style': (el: NodeSingular) => ((el.data('exists') as boolean) ? 'solid' : 'dashed'),
            label: 'data(label)',
            color: '#e4e4e7',
            'font-size': '10px',
            'text-valign': 'center',
            'text-halign': 'right',
            'text-margin-x': 6,
            'text-opacity': (el: NodeSingular) => (el.data('is_doc') ? 0.55 : 1),
            opacity: (el: NodeSingular) => (el.data('is_doc') ? 0.55 : 1),
            width: (el: NodeSingular) => (el.data('is_doc') ? 8 : 12),
            height: (el: NodeSingular) => (el.data('is_doc') ? 8 : 12),
          },
        },
        {
          selector: 'node.dim',
          style: { opacity: 0.15, 'text-opacity': 0.15 },
        },
        {
          selector: 'node.hit',
          style: { 'border-width': 3, 'border-color': '#fbbf24' },
        },
        { selector: 'node:selected', style: { 'border-width': 3, 'border-color': '#e4e4e7' } },
        {
          selector: 'edge',
          style: {
            width: 1,
            'line-color': (el) => (el.data('kind') === 'source' ? '#3f3f46' : '#52525b'),
            'line-style': (el) => (el.data('kind') === 'source' ? 'dotted' : 'solid'),
            'curve-style': 'bezier',
            'target-arrow-color': '#52525b',
            'target-arrow-shape': 'triangle',
            'arrow-scale': 0.5,
          },
        },
        { selector: 'edge.dim', style: { opacity: 0.1 } },
      ],
      layout: { name: 'cose', animate: false, nodeRepulsion: 9000, idealEdgeLength: 70 } as never,
    })
    cy.on('tap', 'node', (evt) => {
      const n = evt.target.data() as WikiGraphNode
      if (n.is_doc) return // dimmer context nodes aren't navigable pages
      emit('open-page', String(evt.target.id()))
    })
    applyHighlight()
  } catch (e) {
    error.value = String(e)
  } finally {
    loading.value = false
  }
}

// search-highlight: matching nodes get a gold ring + full opacity; the rest
// dim so the match reads at a glance. Empty query = everything normal.
function applyHighlight() {
  if (!cy) return
  const q = query.value.trim().toLowerCase()
  cy.nodes().removeClass('hit dim')
  cy.edges().removeClass('dim')
  if (!q) return
  const hits = cy.nodes().filter((n) => String(n.data('label') ?? '').toLowerCase().includes(q))
  hits.addClass('hit')
  cy.nodes().difference(hits).addClass('dim')
  cy.edges().filter((e) => !hits.contains(e.source()) && !hits.contains(e.target())).addClass('dim')
}
watch(query, applyHighlight)
watch(() => props.highlight, (h) => { if (h !== undefined) query.value = h })
watch(() => props.wiki, load)
watch(includeDocs, load)

onMounted(load)
onUnmounted(() => { if (cy) cy.destroy() })
defineExpose({ reload: load })
</script>

<template>
  <div class="h-full flex flex-col gap-2">
    <div class="flex items-center gap-2 flex-wrap text-[11px]">
      <span v-if="loading" class="text-zinc-500">loading…</span>
      <span v-else-if="stats" class="text-zinc-500">
        {{ stats.nodes }} pages · {{ stats.edges }} links
        <span v-if="!available" class="text-amber-400"> · wiki schema not available yet</span>
      </span>
      <button class="rounded px-1.5 py-0.5 border shrink-0"
              :class="includeDocs ? 'text-emerald-300 border-emerald-700/60 bg-emerald-900/30' : 'text-zinc-500 hover:text-zinc-200 bg-zinc-900/70 border-zinc-800'"
              title="show each page's source docs as dimmer context nodes"
              @click="includeDocs = !includeDocs">📄 source docs</button>
      <input v-model="query" placeholder="highlight…"
             class="bg-zinc-900/80 border border-zinc-800 rounded px-1.5 py-0.5 text-zinc-200 w-28 focus:w-40 transition-all ml-auto" />
      <button class="rounded px-1.5 py-0.5 border border-zinc-700 hover:bg-zinc-800 text-zinc-300" @click="load">reload</button>
    </div>

    <!-- status legend -->
    <div v-if="statusesPresent.length" class="flex items-center gap-3 text-[10px] text-zinc-400">
      <span v-for="s in statusesPresent" :key="s" class="inline-flex items-center gap-1">
        <span class="w-2 h-2 rounded-full" :style="{ background: STATUS_COLOR[s] }"></span>{{ s }}
      </span>
      <span class="inline-flex items-center gap-1">
        <span class="w-2 h-2 rounded-full border border-dashed" style="border-color:#f43f5e"></span>red link
      </span>
    </div>

    <p v-if="error" class="text-sm text-rose-400">{{ error }}</p>

    <div ref="container" class="flex-1 min-h-[240px] rounded-md border border-zinc-800 bg-zinc-950"></div>

    <p class="text-[11px] text-zinc-600">
      Click a page to open it. Dashed rose = a red link (linked to, not yet written). Layout: Cytoscape `cose`.
    </p>
  </div>
</template>
