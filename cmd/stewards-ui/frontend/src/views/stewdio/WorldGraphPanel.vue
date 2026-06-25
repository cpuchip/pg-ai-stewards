<script setup lang="ts">
// Stewdio World panel — the Loreworks 3D knowledge graph (the showpiece).
// A ForceGraph3D constellation of a world's entities + relationships: nodes
// coloured by kind with persistent floating name labels, edges as directional
// particle flows, bloom for the "constellation" look. A toolbar picks the world,
// searches names (fly-to on match), and filters by kind via legend chips. Clicking
// a node opens a right detail drawer — summary, typed connections (navigable),
// and source provenance (the "grounded in the canon" payoff). Source-ref doc
// chips re-select the corpus doc in the cockpit (graph → source, one ring out).
// Spec: .spec/proposals/loreworks-presentation-plan.md (§3D knowledge graph).
import { ref, onMounted, onUnmounted, watch, computed, nextTick } from 'vue'
import ForceGraph3D from '3d-force-graph'
import SpriteText from 'three-spritetext'
import { api, type WorldGraphResp, type WorldNode, type WorldNodeDetail, type WorldBrief } from '@/api'
import { useStewdioStore } from '../../stores/stewdio'

defineOptions({ inheritAttrs: false })
const store = useStewdioStore()

// node colour by kind — the six world kinds + `concept` (the auto-created edge
// endpoint fallback from world_edge_upsert).
const KIND_COLOR: Record<string, string> = {
  character: '#f472b6', // pink   — the saturated sphere colour
  place:     '#34d399', // emerald
  faction:   '#f59e0b', // amber
  item:      '#38bdf8', // sky
  event:     '#a78bfa', // violet
  lore:      '#e879f9', // fuchsia
  concept:   '#71717a', // zinc (auto-created endpoints)
}
// label text uses a lightened (-200) tint of the kind colour: bright enough to
// read crisply on a dark plate without the bloom that used to wash it out, while
// the sphere keeps the vivid saturated colour so the kind coding still pops.
const KIND_LABEL: Record<string, string> = {
  character: '#fbcfe8', // pink-200
  place:     '#a7f3d0', // emerald-200
  faction:   '#fde68a', // amber-200
  item:      '#bae6fd', // sky-200
  event:     '#ddd6fe', // violet-200
  lore:      '#f5d0fe', // fuchsia-200
  concept:   '#e4e4e7', // zinc-200
}
const kindColor = (k: string) => KIND_COLOR[k] ?? '#71717a'
const labelColor = (k: string) => KIND_LABEL[k] ?? '#e4e4e7'

// the default sphere radius in 3d-force-graph is cbrt(nodeVal) · nodeRelSize.
// We pin nodeRelSize so the label offset (below) uses the same constant and a
// name always clears its circle, hub or leaf.
const NODE_REL_SIZE = 4
const nodeRadius = (n: WorldNode) => Math.cbrt(1 + (n.degree ?? 0)) * NODE_REL_SIZE

const el = ref<HTMLDivElement>()
const worlds = ref<WorldBrief[]>([])
const selected = ref<WorldNodeDetail | WorldNode | null>(null)
const detail = ref<WorldNodeDetail | null>(null) // lazily-loaded typed edges
const active = ref(new Set<string>())            // kinds currently shown
const query = ref('')
const err = ref('')
const loading = ref(false)
const orbiting = ref(true)
const showSearch = ref(false)

// eslint-disable-next-line @typescript-eslint/no-explicit-any
type Graph = any
let graph: Graph | null = null
let nodeById = new Map<number, WorldNode>()
let ro: ResizeObserver | null = null
let resizeRaf = 0

const kinds = computed(() => [...new Set([...nodeById.values()].map(n => n.kind))].sort())
const currentWorld = computed(() => worlds.value.find(w => w.slug === store.worldSlug) || null)

// live name/alias matches for the search dropdown (cap ~8).
const matches = computed<WorldNode[]>(() => {
  const q = query.value.trim().toLowerCase()
  if (!q) return []
  const out: WorldNode[] = []
  for (const n of nodeById.values()) {
    const hit = n.name.toLowerCase().includes(q) ||
      (n.aliases || []).some(a => a.toLowerCase().includes(q))
    if (hit) out.push(n)
    if (out.length >= 8) break
  }
  return out
})

function applyVisibility() {
  if (!graph) return
  const on = active.value
  // After the first tick l.source/l.target are node objects; pre-tick they're ids
  // — resolve against nodeById so the predicate is correct on the very first frame.
  const kindOf = (end: number | WorldNode): string => {
    if (typeof end === 'object') return end.kind
    return nodeById.get(end)?.kind ?? 'concept'
  }
  graph.nodeVisibility((n: WorldNode) => on.has(n.kind))
  graph.linkVisibility((l: { source: number | WorldNode; target: number | WorldNode }) =>
    on.has(kindOf(l.source)) && on.has(kindOf(l.target)))
}

function toggleKind(k: string) {
  const next = new Set(active.value)
  if (next.has(k)) next.delete(k); else next.add(k)
  active.value = next
  applyVisibility()
}

function stopOrbit() {
  if (!graph) return
  orbiting.value = false
  const ctrl = graph.controls() as { autoRotate?: boolean }
  ctrl.autoRotate = false
}
function toggleOrbit() {
  if (!graph) return
  orbiting.value = !orbiting.value
  const ctrl = graph.controls() as { autoRotate?: boolean; autoRotateSpeed?: number }
  ctrl.autoRotate = orbiting.value
  ctrl.autoRotateSpeed = 0.6
}

// camera fly-to a node + select it. Pull the camera out along the node's vector
// so it frames the node from a readable distance.
function focusNode(n: WorldNode) {
  if (!graph) return
  const dist = 80
  const ratio = 1 + dist / Math.hypot(n.x ?? 1, n.y ?? 1, n.z ?? 1)
  graph.cameraPosition(
    { x: (n.x ?? 0) * ratio, y: (n.y ?? 0) * ratio, z: (n.z ?? 0) * ratio },
    n as { x: number; y: number; z: number },
    1200,
  )
}

async function selectNode(n: WorldNode, fly = true) {
  selected.value = n
  detail.value = null
  if (fly) focusNode(n)
  stopOrbit()
  // lazy-load the typed edge list (rel, direction, neighbour name, evidence).
  const slug = store.worldSlug
  if (!slug) return
  try {
    detail.value = await api.worldNode(slug, n.id)
  } catch { /* the drawer still renders from the enriched node */ }
}

function pickMatch(n: WorldNode) {
  query.value = ''
  showSearch.value = false
  selectNode(n)
}
function onSearchEnter() {
  const first = matches.value[0]
  if (first) pickMatch(first)
}

// a source_ref doc is a corpus doc slug — make it clickable to surface the source
// in the cockpit's artifact panel (graph → source, the same provenance move chat
// makes). Guard: only treat a bare token (no slash/scheme) as a doc slug.
function isDocSlug(doc?: string): boolean {
  if (!doc) return false
  return !/[\/\s]/.test(doc) && !/^(https?:)?\/\//i.test(doc)
}
function openDoc(doc?: string) {
  if (!doc || !isDocSlug(doc)) return
  store.select(doc, 'doc', doc)
}

function neighborNode(id: number): WorldNode | null {
  return nodeById.get(id) ?? null
}
function focusNeighbor(id: number) {
  const n = neighborNode(id)
  if (n) selectNode(n)
}

async function loadWorld(slug: string) {
  if (!graph || !slug) return
  err.value = ''
  loading.value = true
  selected.value = null
  detail.value = null
  try {
    const g: WorldGraphResp = await api.worldGraph(slug, true)
    nodeById = new Map(g.nodes.map(n => [n.id, n]))
    active.value = new Set(g.nodes.map(n => n.kind)) // all kinds on
    graph.graphData(g)
    applyVisibility()
  } catch (e) {
    err.value = String(e)
    nodeById = new Map()
    try { graph.graphData({ nodes: [], links: [] }) } catch { /* ignore */ }
  } finally {
    loading.value = false
  }
}

function resize() {
  if (!graph || !el.value) return
  const r = el.value.getBoundingClientRect()
  graph.width(r.width).height(r.height)
}

onMounted(async () => {
  await nextTick()
  if (!el.value) return

  graph = ForceGraph3D()(el.value)
    .backgroundColor('#09090b')        // zinc-950 — matches the cockpit
    .showNavInfo(false)
    .nodeColor((n: WorldNode) => kindColor(n.kind))
    .nodeVal((n: WorldNode) => 1 + (n.degree ?? 0))
    .nodeRelSize(NODE_REL_SIZE)          // pin the radius scale (see nodeRadius)
    .nodeOpacity(0.92)                   // a touch of translucency for depth
    .nodeResolution(18)                  // smooth spheres (default 8 = faceted)
    .nodeLabel((n: WorldNode) => n.name)
    .nodeThreeObject((n: WorldNode) => {
      // crisp, high-contrast plate label — legibility is the job now that the
      // bloom is gone. Lightened kind tint + glyph stroke + near-solid plate.
      const s = new SpriteText(n.name)
      s.color = labelColor(n.kind)
      s.textHeight = 5 + Math.min(7, n.degree ?? 0) // hubs get bigger labels
      s.fontWeight = '600'
      s.strokeWidth = 0.6                            // dark outline → reads over edges
      s.strokeColor = 'rgba(9,9,11,0.95)'
      s.backgroundColor = 'rgba(9,9,11,0.82)'        // near-solid zinc-950 plate
      s.borderWidth = 0.5
      s.borderColor = kindColor(n.kind) + 'aa'       // subtle kind-coloured frame
      s.borderRadius = 3
      s.padding = 2
      // lift the label clear of the sphere so the name sits ABOVE the circle
      // instead of hidden under it — offset scales with the node radius.
      s.position.y = nodeRadius(n) + s.textHeight / 2 + 4
      return s
    })
    .nodeThreeObjectExtend(true)        // keep the sphere AND the label
    .linkLabel((l: { rel: string }) => l.rel)
    .linkColor(() => 'rgba(113,113,122,0.38)') // dimmer → labels win the hierarchy
    .linkWidth(0.5)
    .linkDirectionalParticles(2)
    .linkDirectionalParticleWidth(1.2)
    .linkDirectionalParticleSpeed(0.006)
    .linkDirectionalArrowLength(3)
    .linkDirectionalArrowRelPos(1)
    .onNodeClick((n: WorldNode) => { selectNode(n) })
    .onNodeDrag(() => stopOrbit())
    .warmupTicks(60)                    // pre-settle → no "explosion" on open
    .cooldownTime(4000)                 // then freeze (deterministic-looking)

  // forces: legible spread, not a hairball.
  graph.d3Force('charge')?.strength(-120)
  graph.d3Force('link')?.distance(40).strength(1)
  graph.d3AlphaDecay(0.0228)

  // No bloom: the UnrealBloomPass washed out the SpriteText labels (they're
  // sprites, so the pass smeared them) and Michael couldn't read the nodes.
  // Legibility wins over the "constellation glow" — the look now comes from the
  // smooth coloured spheres + crisp plate labels + directional edge particles
  // against near-black, not from post-processing. (If a subtle glow is ever
  // wanted on a recording, add it with a HIGH threshold so it never touches the
  // labels: new UnrealBloomPass(undefined, 0.3, 0.4, 0.9).)

  // start alive: idle orbit until first interaction.
  const ctrl = graph.controls() as { autoRotate?: boolean; autoRotateSpeed?: number }
  ctrl.autoRotate = true
  ctrl.autoRotateSpeed = 0.6

  resize()
  ro = new ResizeObserver(() => {
    cancelAnimationFrame(resizeRaf)
    resizeRaf = requestAnimationFrame(resize)
  })
  ro.observe(el.value)

  try {
    worlds.value = (await api.worldList()).items
  } catch (e) {
    err.value = String(e)
  }
  const slug = store.worldSlug && worlds.value.some(w => w.slug === store.worldSlug)
    ? store.worldSlug
    : worlds.value[0]?.slug || ''
  if (slug) {
    store.worldSlug = slug
    await loadWorld(slug)
  }
})

watch(() => store.worldSlug, (s) => { if (s) loadWorld(s) })

onUnmounted(() => {
  cancelAnimationFrame(resizeRaf)
  ro?.disconnect()
  try { graph?._destructor?.() } catch { /* ignore */ }
  graph = null
})
</script>

<template>
  <div class="h-full w-full flex flex-col bg-zinc-950 relative overflow-hidden">
    <!-- toolbar: world picker · search · legend/filter chips · orbit -->
    <div class="absolute top-1 left-2 right-2 z-20 flex items-center gap-2 flex-wrap text-[11px]">
      <select
        v-model="store.worldSlug"
        class="bg-zinc-900/80 border border-zinc-800 rounded px-1.5 py-0.5 text-zinc-200 max-w-[180px]"
        title="choose a world">
        <option v-for="w in worlds" :key="w.slug" :value="w.slug">
          {{ w.name }}{{ w.is_private ? ' 🔒' : '' }}
        </option>
      </select>
      <span v-if="currentWorld" class="text-zinc-600">
        {{ currentWorld.entity_count }} entities · {{ currentWorld.edge_count }} edges
      </span>

      <!-- search → fly-to -->
      <div class="relative">
        <input
          v-model="query"
          @focus="showSearch = true"
          @keydown.enter.prevent="onSearchEnter"
          @keydown.escape="showSearch = false"
          placeholder="search…"
          class="bg-zinc-900/80 border border-zinc-800 rounded px-1.5 py-0.5 text-zinc-200 w-28 focus:w-40 transition-all" />
        <div v-if="showSearch && matches.length"
             class="absolute left-0 mt-1 w-48 rounded border border-zinc-800 bg-zinc-900 shadow-lg overflow-hidden z-30">
          <button v-for="m in matches" :key="m.id"
                  class="w-full text-left px-2 py-1 hover:bg-zinc-800 flex items-center gap-1.5"
                  @click="pickMatch(m)">
            <span class="w-1.5 h-1.5 rounded-full shrink-0" :style="{ background: kindColor(m.kind) }"></span>
            <span class="text-zinc-200 truncate">{{ m.name }}</span>
            <span class="text-zinc-600 ml-auto">{{ m.kind }}</span>
          </button>
        </div>
      </div>

      <!-- legend chips = filter -->
      <button v-for="k in kinds" :key="k"
              @click="toggleKind(k)"
              class="rounded-full px-1.5 py-0.5 border flex items-center gap-1 transition-opacity"
              :class="active.has(k) ? 'opacity-100' : 'opacity-35'"
              :style="{ borderColor: kindColor(k) }"
              :title="active.has(k) ? `hide ${k}` : `show ${k}`">
        <span class="w-1.5 h-1.5 rounded-full" :style="{ background: kindColor(k) }"></span>
        <span class="text-zinc-300">{{ k }}</span>
      </button>

      <button
        @click="toggleOrbit"
        class="ml-auto rounded px-1.5 py-0.5 border"
        :class="orbiting
          ? 'text-emerald-300 border-emerald-700/60 bg-emerald-900/30'
          : 'text-zinc-500 hover:text-zinc-200 bg-zinc-900/70 border-zinc-800'"
        :title="orbiting ? 'stop the idle orbit' : 'orbit the camera'">
        {{ orbiting ? '⏸ orbit' : '▷ orbit' }}
      </button>
    </div>

    <!-- the 3D canvas -->
    <div ref="el" class="flex-1 min-h-0"></div>

    <!-- loading / empty overlays -->
    <div v-if="loading" class="absolute inset-0 flex items-center justify-center pointer-events-none">
      <div class="text-zinc-500 text-sm animate-pulse">building the world…</div>
    </div>
    <div v-else-if="!err && nodeById.size === 0"
         class="absolute inset-0 flex items-center justify-center pointer-events-none">
      <div class="text-zinc-600 text-sm text-center">
        no entities yet<br />
        <span class="text-zinc-700 text-xs">run a world build to populate this graph</span>
      </div>
    </div>

    <!-- detail drawer -->
    <aside v-if="selected"
           class="absolute top-0 right-0 h-full w-80 bg-zinc-900/95 border-l border-zinc-800 overflow-auto p-3 z-20 text-[13px]">
      <div class="flex items-start justify-between gap-2 mb-2">
        <div class="text-zinc-100 text-base font-medium leading-tight">{{ selected.name }}</div>
        <button class="text-zinc-500 hover:text-zinc-200 shrink-0" title="close" @click="selected = null">✕</button>
      </div>
      <div class="flex items-center gap-2 mb-3">
        <span class="rounded-full px-2 py-0.5 text-[11px] font-medium"
              :style="{ background: kindColor(selected.kind) + '22', color: kindColor(selected.kind), border: `1px solid ${kindColor(selected.kind)}` }">
          {{ selected.kind }}
        </span>
        <span v-if="selected.degree != null" class="text-zinc-600 text-[11px]">
          {{ selected.degree }} connection{{ selected.degree === 1 ? '' : 's' }}
        </span>
      </div>

      <div v-if="selected.aliases && selected.aliases.length" class="text-zinc-500 text-[11px] mb-2">
        aka {{ selected.aliases.join(', ') }}
      </div>

      <p v-if="selected.summary" class="text-zinc-300 leading-relaxed mb-4">{{ selected.summary }}</p>

      <!-- typed connections -->
      <div v-if="detail && detail.edges && detail.edges.length" class="mb-4">
        <div class="text-zinc-500 text-[11px] uppercase tracking-wide mb-1.5">Connections</div>
        <ul class="space-y-1">
          <li v-for="(e, i) in detail.edges" :key="i" class="flex items-center gap-1.5">
            <span class="text-zinc-600 shrink-0">{{ e.dir === 'out' ? '→' : '←' }}</span>
            <span class="text-zinc-500 shrink-0">{{ e.rel }}</span>
            <span class="text-zinc-700">·</span>
            <button class="text-sky-400 hover:text-sky-300 truncate text-left"
                    :title="`focus ${e.other_name}`"
                    @click="focusNeighbor(e.other_id)">{{ e.other_name }}</button>
          </li>
        </ul>
      </div>

      <!-- source provenance -->
      <div v-if="selected.source_refs && selected.source_refs.length">
        <div class="text-zinc-500 text-[11px] uppercase tracking-wide mb-1.5">Source</div>
        <div v-for="(s, i) in selected.source_refs" :key="i" class="mb-2.5">
          <blockquote v-if="s.quote"
                      class="border-l-2 border-zinc-700 pl-2 text-zinc-400 italic leading-relaxed">
            {{ s.quote }}
          </blockquote>
          <div class="text-[11px] mt-0.5">
            <button v-if="isDocSlug(s.doc)" class="text-sky-500 hover:text-sky-400"
                    :title="`open ${s.doc} in the artifact panel`" @click="openDoc(s.doc)">
              {{ s.doc }}<span v-if="s.chunk != null"> · chunk {{ s.chunk }}</span>
            </button>
            <span v-else class="text-zinc-600">
              {{ s.doc || 'source' }}<span v-if="s.chunk != null"> · chunk {{ s.chunk }}</span>
            </span>
          </div>
        </div>
      </div>
    </aside>

    <div v-if="err" class="absolute bottom-2 left-2 right-2 text-rose-400 text-xs z-20">{{ err }}</div>
  </div>
</template>
