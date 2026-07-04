<script setup lang="ts">
// Obsidian-style local graph: a small 1-2 hop neighborhood mini-graph, meant
// to sit in a corner of the page view. Same 2D Cytoscape choice as
// WikiGraphPanel (see its header comment) — at this size (a few dozen px per
// node) a 3D camera would be pure overhead, not legibility.
import { ref, onMounted, onUnmounted, watch, useTemplateRef } from 'vue'
import cytoscape from 'cytoscape'
import type { Core, NodeSingular } from 'cytoscape'
import { api } from '@/api'

const props = defineProps<{ slug: string }>()
const emit = defineEmits<{ 'open-page': [slug: string] }>()

const containerRef = useTemplateRef<HTMLDivElement>('container')
const hops = ref<1 | 2>(2)
const loading = ref(false)
const available = ref(true)
const empty = ref(false)
let cy: Core | null = null

async function load() {
  if (!props.slug) return
  loading.value = true
  try {
    const g = await api.wikiLocalGraph(props.slug, hops.value)
    available.value = g.available
    empty.value = g.nodes.length <= 1
    if (cy) cy.destroy()
    if (!containerRef.value) return
    cy = cytoscape({
      container: containerRef.value,
      elements: [
        ...g.nodes.map((n) => ({
          data: { id: n.id, label: n.id === props.slug ? `● ${n.label}` : n.label, exists: n.exists, center: n.id === props.slug },
        })),
        ...g.edges.map((e, i) => ({ data: { id: `e${i}`, source: e.source, target: e.target } })),
      ],
      style: [
        {
          selector: 'node',
          style: {
            'background-color': (el: NodeSingular) => (el.data('center') ? '#38bdf8' : el.data('exists') ? '#71717a' : '#18181b'),
            'border-color': (el: NodeSingular) => (el.data('exists') ? '#a1a1aa' : '#f43f5e'),
            'border-width': 1,
            'border-style': (el: NodeSingular) => (el.data('exists') ? 'solid' : 'dashed'),
            label: 'data(label)',
            color: '#d4d4d8',
            'font-size': '8px',
            'text-valign': 'bottom',
            'text-margin-y': 3,
            width: (el: NodeSingular) => (el.data('center') ? 10 : 6),
            height: (el: NodeSingular) => (el.data('center') ? 10 : 6),
          },
        },
        {
          selector: 'edge',
          style: { width: 0.75, 'line-color': '#3f3f46', 'curve-style': 'bezier' },
        },
      ],
      layout: { name: 'cose', animate: false, nodeRepulsion: 4000, idealEdgeLength: 30 } as never,
      // a corner mini-graph is for orientation, not exploration — no user pan/zoom fuss.
      userZoomingEnabled: false,
      userPanningEnabled: false,
      boxSelectionEnabled: false,
    })
    cy.on('tap', 'node', (evt) => {
      const id = String(evt.target.id())
      if (id !== props.slug) emit('open-page', id)
    })
  } catch {
    available.value = false
  } finally {
    loading.value = false
  }
}

watch(() => props.slug, load)
watch(hops, load)
onMounted(load)
onUnmounted(() => { if (cy) cy.destroy() })
</script>

<template>
  <div class="relative rounded-md border border-zinc-800 bg-zinc-950/90 backdrop-blur-sm p-1.5 w-56 h-40 flex flex-col gap-1 shadow-lg">
    <div class="flex items-center justify-between text-[10px] text-zinc-500 px-0.5">
      <span>local graph</span>
      <div class="inline-flex rounded overflow-hidden border border-zinc-800">
        <button class="px-1" :class="hops === 1 ? 'bg-zinc-800 text-zinc-200' : 'text-zinc-500'" @click="hops = 1">1</button>
        <button class="px-1" :class="hops === 2 ? 'bg-zinc-800 text-zinc-200' : 'text-zinc-500'" @click="hops = 2">2</button>
      </div>
    </div>
    <div ref="container" class="flex-1 min-h-0 rounded bg-zinc-950"></div>
    <div v-if="loading" class="absolute inset-0 flex items-center justify-center text-[10px] text-zinc-600 pointer-events-none">…</div>
    <div v-else-if="!available || empty" class="absolute inset-0 flex items-center justify-center text-[10px] text-zinc-700 text-center px-4 pointer-events-none">
      {{ available ? 'no linked pages yet' : 'not available' }}
    </div>
  </div>
</template>
