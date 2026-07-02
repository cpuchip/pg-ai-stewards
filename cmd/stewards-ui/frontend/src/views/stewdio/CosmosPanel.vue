<script setup lang="ts">
// Stewdio Cosmos panel — the CROSS-SERVICE view (the World panel's other mode).
// Where WorldGraphPanel shows ONE world's entity graph, this shows the whole
// constellation: each world (a service, extracted by lodestar) is a node, each
// stewards.cross_world_edges row a link, and the worlds cluster into GALAXIES —
// Louvain communities that read as candidate platforms (service groups so
// tightly coupled you'd pull them out together). Nodes are coloured by galaxy
// (so the clusters pop), links by protocol (grpc/http/db/config…). A project
// selector scopes the universe: "all" = every service, or one project's subtree.
// Backend: GET /api/world/cosmos (api/cosmos.go) — mass + galaxies + modularity
// computed deterministically (ported from lodestar's gravity analysis).
import { ref, onMounted, onUnmounted, watch, computed, nextTick } from 'vue'
import ForceGraph3D from '3d-force-graph'
import SpriteText from 'three-spritetext'
import { api, type CosmosWorld, type CosmosEdge } from '@/api'
import { useStewdioStore } from '../../stores/stewdio'

defineOptions({ inheritAttrs: false })

// mode lives in the parent (WorldGraphPanel) so the toggle is one source of
// truth; we render the toggle here too and emit the switch back to World.
const props = defineProps<{ mode: 'world' | 'cosmos' }>()
const emit = defineEmits<{ 'update:mode': ['world' | 'cosmos'] }>()

const store = useStewdioStore()

// galaxy colours — a candidate platform gets a stable hue from its rank (galaxies
// arrive largest-first). This is the whole point of the view: SEE the clusters.
const GALAXY_PALETTE = [
  '#38bdf8', '#f472b6', '#34d399', '#f59e0b', '#a78bfa',
  '#e879f9', '#fb923c', '#22d3ee', '#a3e635', '#f87171',
  '#5eead4', '#fbbf24',
]
const galaxyColor = (g: number) => GALAXY_PALETTE[((g % GALAXY_PALETTE.length) + GALAXY_PALETTE.length) % GALAXY_PALETTE.length]

// link colours by PROTOCOL — how two services are bound. Distinct, high-contrast
// hues; a shared DB (the hardest coupling) is the alarming red.
const PROTOCOL_COLOR: Record<string, string> = {
  grpc:    '#a78bfa', // violet
  http:    '#38bdf8', // sky
  pubsub:  '#f59e0b', // amber
  graphql: '#e879f9', // fuchsia
  schema:  '#34d399', // emerald
  db:      '#ef4444', // red — strongest coupling
  config:  '#f472b6', // pink
  package: '#facc15', // yellow
  k8s:     '#326ce5', // kubernetes blue — a declared deploy-time service dependency
}
const protocolColor = (p: string) => PROTOCOL_COLOR[p] ?? '#94a3b8'

const NODE_REL_SIZE = 4
const nodeRadius = (n: CosmosWorld) => Math.cbrt(1 + (n.mass ?? 0)) * NODE_REL_SIZE

const el = ref<HTMLDivElement>()
const projects = ref<{ name: string; doc_count?: number }[]>([])
const project = ref('all')
const worlds = ref<CosmosWorld[]>([])
const edges = ref<CosmosEdge[]>([])
const galaxies = ref<string[][]>([])
const modularity = ref(0)
const blackHole = ref(false)
const selected = ref<CosmosWorld | null>(null)
const err = ref('')
const loading = ref(false)
const orbiting = ref(true)
const exploded = ref(true) // spread galaxies to per-cluster anchors so the clusters stay legible under hub gravity
const showGalaxyLegend = ref(true)
const showProtoLegend = ref(true)
let loaded = false

// eslint-disable-next-line @typescript-eslint/no-explicit-any
type Graph = any
let graph: Graph | null = null
let galaxyOf = new Map<string, number>()
let galaxyAnchors: { x: number; y: number; z: number }[] = [] // per-galaxy sphere anchors (the explode force)
let degMap = new Map<string, number>()                        // world slug → # incident cross-service links
let ro: ResizeObserver | null = null
let resizeRaf = 0

const worldsCount = computed(() => worlds.value.length)
const protocolsPresent = computed(() => [...new Set(edges.value.map(e => e.protocol).filter(Boolean))].sort())
// degree (# incident cross-service links) for the drawer.
function degreeOf(slug: string): number {
  let d = 0
  for (const e of edges.value) if (e.from === slug || e.to === slug) d++
  return d
}
function galaxyIndexOf(slug: string): number {
  return galaxyOf.get(slug) ?? -1
}
function galaxyMembers(slug: string): string[] {
  const g = galaxyIndexOf(slug)
  return g >= 0 ? (galaxies.value[g] ?? []) : []
}

// #301 item 6 — show the real member service names in the platform legend (was
// just "N services"). A galaxy is a list of world slugs; map each to its display
// label (the slug minus the project/ prefix, computed server-side in cosmosLabel),
// falling back to the last path segment for any slug not in the loaded set.
const labelBySlug = computed(() => {
  const m = new Map<string, string>()
  for (const wld of worlds.value) m.set(wld.slug, wld.label)
  return m
})
function labelOf(slug: string): string {
  return labelBySlug.value.get(slug) ?? slug.split('/').pop() ?? slug
}
function previewMembers(slugs: string[], n = 3): string {
  const labels = slugs.map(labelOf)
  return labels.length <= n ? labels.join(', ') : labels.slice(0, n).join(', ') + ` +${labels.length - n} more`
}
// which platform rows are expanded to their full (scrollable) member list.
const expandedGalaxies = ref(new Set<number>())
function toggleGalaxy(gi: number) {
  const next = new Set(expandedGalaxies.value)
  if (next.has(gi)) next.delete(gi)
  else next.add(gi)
  expandedGalaxies.value = next
}

function toggleExplode() {
  exploded.value = !exploded.value
  graph?.d3ReheatSimulation()
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

function focusNode(n: CosmosWorld) {
  if (!graph) return
  const dist = 80
  const ratio = 1 + dist / Math.hypot(n.x ?? 1, n.y ?? 1, n.z ?? 1)
  graph.cameraPosition(
    { x: (n.x ?? 0) * ratio, y: (n.y ?? 0) * ratio, z: (n.z ?? 0) * ratio },
    n as { x: number; y: number; z: number },
    1200,
  )
}

function selectNode(n: CosmosWorld) {
  selected.value = n
  focusNode(n)
  stopOrbit()
}

// cross-link: jump to this service's per-world ENTITY graph (the other mode).
// Set the shared world slug and flip the parent back to World mode.
function openEntityGraph(slug: string) {
  store.worldSlug = slug
  emit('update:mode', 'world')
}

async function loadProjects() {
  try {
    const r = await api.worldProjects()
    projects.value = r.items ?? []
  } catch { /* selector still offers "all" */ }
}

async function loadCosmos() {
  if (!graph) return
  err.value = ''
  loading.value = true
  selected.value = null
  try {
    const r = await api.worldCosmos(project.value)
    // rank each world's galaxy for colouring (galaxies arrive largest-first).
    galaxyOf = new Map()
    r.galaxies.forEach((members, gi) => members.forEach(slug => galaxyOf.set(slug, gi)))
    worlds.value = r.worlds.map(w => ({ ...w, galaxy: galaxyOf.get(w.slug) ?? -1 }))
    edges.value = r.edges
    galaxies.value = r.galaxies
    // degree map: a mega-hub's links each pull weakly (below) so it stops collapsing clusters.
    degMap = new Map()
    for (const e of r.edges) {
      degMap.set(e.from, (degMap.get(e.from) ?? 0) + 1)
      degMap.set(e.to, (degMap.get(e.to) ?? 0) + 1)
    }
    // spread each galaxy to its own sphere anchor (golden-angle) → the explode force target.
    {
      const G = Math.max(1, r.galaxies.length)
      const R = 140 + G * 3
      galaxyAnchors = r.galaxies.map((_, i) => {
        const t = (i + 0.5) / G
        const phi = Math.acos(1 - 2 * t)
        const theta = Math.PI * (1 + Math.sqrt(5)) * i
        return { x: R * Math.sin(phi) * Math.cos(theta), y: R * Math.cos(phi), z: R * Math.sin(phi) * Math.sin(theta) }
      })
    }
    modularity.value = r.modularity
    blackHole.value = r.black_hole
    // build fresh graph objects: nodes need `id`, links need `source`/`target`.
    const nodes = worlds.value.map(w => ({ ...w, id: w.slug }))
    const links = r.edges.map(e => ({ source: e.from, target: e.to, protocol: e.protocol, contract_key: e.contract_key, confidence: e.confidence }))
    graph.graphData({ nodes, links })
  } catch (e) {
    err.value = String(e)
    worlds.value = []; edges.value = []; galaxies.value = []
    try { graph.graphData({ nodes: [], links: [] }) } catch { /* ignore */ }
  } finally {
    loading.value = false
  }
}

function onProject() {
  loadCosmos()
}

function resize() {
  if (!graph || !el.value) return
  const r = el.value.getBoundingClientRect()
  // Hidden (v-show) or unsized: skip — sizing to 0×0 poisons the trackball rect
  // (see below). The ResizeObserver re-fires with the real size on show.
  if (r.width === 0 || r.height === 0) return
  graph.width(r.width).height(r.height)
  // #301 item 2 — TrackballControls caches its screen rect once at construction and
  // 3d-force-graph never re-runs handleResize; a graph built while hidden (this
  // panel mounts hidden under v-show) keeps a 0×0 rect → orbit/pan divide by zero →
  // frozen while clicks still work. Recompute against the live element every resize.
  ;(graph.controls() as { handleResize?: () => void }).handleResize?.()
}

onMounted(async () => {
  await nextTick()
  if (!el.value) return

  graph = ForceGraph3D()(el.value)
    .backgroundColor('#09090b')
    .showNavInfo(false)
    .nodeColor((n: CosmosWorld) => galaxyColor(n.galaxy ?? 0))
    .nodeVal((n: CosmosWorld) => 1 + (n.mass ?? 0))
    .nodeRelSize(NODE_REL_SIZE)
    .nodeOpacity(0.92)
    .nodeResolution(18)
    .nodeLabel((n: CosmosWorld) => `${n.label}  ·  ${n.project}`)
    .nodeThreeObject((n: CosmosWorld) => {
      const s = new SpriteText(n.label)
      s.color = '#e4e4e7'
      s.textHeight = 5 + Math.min(7, Math.cbrt(1 + (n.mass ?? 0)) * 2)
      s.fontWeight = '600'
      s.strokeWidth = 0.6
      s.strokeColor = 'rgba(9,9,11,0.95)'
      s.backgroundColor = 'rgba(9,9,11,0.82)'
      s.borderWidth = 0.5
      s.borderColor = galaxyColor(n.galaxy ?? 0) + 'aa'
      s.borderRadius = 3
      s.padding = 2
      s.position.y = nodeRadius(n) + s.textHeight / 2 + 4
      return s
    })
    .nodeThreeObjectExtend(true)
    .linkLabel((l: { protocol: string; contract_key?: string }) => l.contract_key ? `${l.protocol} · ${l.contract_key}` : l.protocol)
    .linkColor((l: { protocol: string }) => protocolColor(l.protocol))
    .linkWidth(1.4)
    .linkOpacity(0.7)
    .linkDirectionalParticles(2)
    .linkDirectionalParticleWidth(1.6)
    .linkDirectionalParticleColor((l: { protocol: string }) => protocolColor(l.protocol))
    .linkDirectionalParticleSpeed(0.006)
    .linkDirectionalArrowLength(3.2)
    .linkDirectionalArrowColor((l: { protocol: string }) => protocolColor(l.protocol))
    .linkDirectionalArrowRelPos(1)
    .onNodeClick((n: CosmosWorld) => { selectNode(n) })
    .onNodeDrag(() => stopOrbit())
    .warmupTicks(60)
    .cooldownTime(4000)

  graph.d3Force('charge')?.strength(-140)
  // Degree-normalized link strength: a hub's many links each pull WEAKLY (d3's own
  // default, which the constant strength(1) had defeated) so env/grpc stop collapsing
  // the clusters into one knot; a lib shared by a few services still pulls its cluster tight.
  graph.d3Force('link')?.distance(50).strength((l: { source: unknown; target: unknown }) => {
    const id = (x: unknown) => (typeof x === 'object' && x ? (x as { id: string }).id : (x as string))
    const s = degMap.get(id(l.source)) ?? 1
    const t = degMap.get(id(l.target)) ?? 1
    return 1 / Math.max(1, Math.min(s, t))
  })
  // Explode force: nudge each world toward its galaxy's anchor so the clusters physically
  // separate. Reads exploded/galaxyAnchors each tick, so toggling + reloading needs no re-add.
  const galaxyForce = () => {
    let ns: { x: number; y: number; z: number; vx: number; vy: number; vz: number; galaxy?: number }[] = []
    const f = (alpha: number) => {
      if (!exploded.value || galaxyAnchors.length === 0) return
      const k = 0.085 * alpha
      for (const n of ns) {
        const a = galaxyAnchors[n.galaxy ?? -1]
        if (!a) continue
        n.vx += (a.x - n.x) * k
        n.vy += (a.y - n.y) * k
        n.vz += (a.z - n.z) * k
      }
    }
    ;(f as unknown as { initialize: (nodes: unknown[]) => void }).initialize = (nodes) => { ns = nodes as typeof ns }
    return f
  }
  graph.d3Force('galaxy', galaxyForce())
  graph.d3AlphaDecay(0.0228)

  const ctrl = graph.controls() as { autoRotate?: boolean; autoRotateSpeed?: number }
  ctrl.autoRotate = true
  ctrl.autoRotateSpeed = 0.6

  resize()
  ro = new ResizeObserver(() => {
    cancelAnimationFrame(resizeRaf)
    resizeRaf = requestAnimationFrame(resize)
  })
  ro.observe(el.value)

  // the panel is always mounted (v-show); only wake it when it becomes visible.
  if (props.mode === 'cosmos') await activate()
  else graph.pauseAnimation()
})

// lazily load + wake on first (and every) switch INTO cosmos mode; pause the
// WebGL loop while hidden so two graphs don't both burn GPU.
async function activate() {
  if (!graph) return
  graph.resumeAnimation()
  resize()
  if (!loaded) {
    loaded = true
    await loadProjects()
    await loadCosmos()
  }
}

watch(() => props.mode, (m) => {
  if (!graph) return
  if (m === 'cosmos') activate()
  else graph.pauseAnimation()
})

onUnmounted(() => {
  cancelAnimationFrame(resizeRaf)
  ro?.disconnect()
  try { graph?._destructor?.() } catch { /* ignore */ }
  graph = null
})
</script>

<template>
  <div class="h-full w-full flex bg-zinc-950 relative overflow-hidden">
    <!-- graph column — relative host for the absolute toolbar / legends / overlays;
         the detail drawer (below) is a flex SIBLING that reflows this column narrower
         when open (#301 item 3) instead of overlaying and hiding the graph. min-w-0
         lets this flex column shrink below the canvas's pixel width when the drawer
         opens (default min-width:auto would pin it and clip instead of reflow). -->
    <div class="relative flex-1 min-w-0 min-h-0 flex flex-col overflow-hidden">
    <!-- toolbar: mode toggle · project scope · header stats · orbit -->
    <div class="absolute top-1 left-2 right-2 z-20 flex items-center gap-2 flex-wrap text-[11px]">
      <div class="inline-flex rounded overflow-hidden border border-zinc-700 shrink-0">
        <button class="px-1.5 py-0.5 text-zinc-400 hover:text-zinc-100 hover:bg-zinc-800"
                title="this world's entity graph" @click="emit('update:mode', 'world')">🌍 World</button>
        <button class="px-1.5 py-0.5 bg-sky-900/50 text-sky-200 border-l border-zinc-700"
                title="the cross-service constellation">✦ Cosmos</button>
      </div>

      <select v-model="project" @change="onProject"
              class="bg-zinc-900/80 border border-zinc-800 rounded px-1.5 py-0.5 text-zinc-200 max-w-[200px]"
              title="scope the universe to a project (or all services)">
        <option value="all">✦ all services (universe)</option>
        <option v-for="p in projects" :key="p.name" :value="p.name">{{ p.name }}</option>
      </select>

      <span v-if="!loading && worldsCount" class="text-zinc-500">
        {{ worldsCount }} service{{ worldsCount === 1 ? '' : 's' }} ·
        {{ galaxies.length }} platform{{ galaxies.length === 1 ? '' : 's' }} ·
        Q {{ modularity.toFixed(2) }}
      </span>
      <span v-if="blackHole"
            class="rounded px-1.5 py-0.5 border border-rose-700/60 text-rose-300 bg-rose-900/30"
            title="dense yet structureless — a distributed monolith (nothing separates cleanly)">🕳 black hole</span>

      <button
        @click="toggleExplode"
        class="ml-auto rounded px-1.5 py-0.5 border shrink-0"
        :class="exploded
          ? 'text-sky-300 border-sky-700/60 bg-sky-900/30'
          : 'text-zinc-500 hover:text-zinc-200 bg-zinc-900/70 border-zinc-800'"
        :title="exploded ? 'galaxies spread to their clusters — click to collapse to raw gravity' : 'spread the galaxies apart so the clusters are legible'">
        {{ exploded ? '✦ galaxies' : '✧ collapse' }}
      </button>
      <button
        @click="toggleOrbit"
        class="rounded px-1.5 py-0.5 border shrink-0"
        :class="orbiting
          ? 'text-emerald-300 border-emerald-700/60 bg-emerald-900/30'
          : 'text-zinc-500 hover:text-zinc-200 bg-zinc-900/70 border-zinc-800'"
        :title="orbiting ? 'stop the idle orbit' : 'orbit the camera'">
        {{ orbiting ? '⏸ orbit' : '▷ orbit' }}
      </button>
    </div>

    <!-- the 3D canvas. `isolate z-0` (#301 item 4): trap the WebGL canvas in its own
         low stacking context so its compositing layer can't paint over the cockpit
         chrome (the ▦ panels menu / selectors), which dockview's transform/will-change
         layers would otherwise let it do. -->
    <div ref="el" class="flex-1 min-h-0 relative z-0 isolate"></div>

    <!-- galaxy legend = the candidate platforms (largest first) -->
    <div v-if="galaxies.length" class="absolute left-3 bottom-3 z-10 max-w-[45%]">
      <button class="text-[10px] text-zinc-300 hover:text-white bg-zinc-900/80 border border-zinc-800 rounded px-1.5 py-0.5"
              :title="`${galaxies.length} candidate platform(s) — Louvain communities`"
              @click="showGalaxyLegend = !showGalaxyLegend">
        {{ showGalaxyLegend ? '▾' : '▸' }} platforms ({{ galaxies.length }})
      </button>
      <div v-if="showGalaxyLegend" class="mt-1 bg-zinc-900/85 border border-zinc-800 rounded p-2 max-h-52 overflow-auto space-y-1.5">
        <!-- #301 item 6 — each platform row shows its real member service names.
             Click to expand the full (scrollable) list; the preview truncates to
             "a, b, c +N more" and the tooltip carries every member. -->
        <div v-for="(g, gi) in galaxies" :key="gi" class="text-[10px]">
          <button class="flex items-center gap-1.5 w-full text-left hover:text-white" @click="toggleGalaxy(gi)">
            <span class="inline-block w-2.5 h-2.5 rounded-full shrink-0" :style="{ backgroundColor: galaxyColor(gi) }"></span>
            <span class="text-zinc-400 shrink-0">platform {{ gi + 1 }}</span>
            <span class="text-zinc-600 shrink-0">·</span>
            <span class="text-zinc-500 shrink-0">{{ g.length }} service{{ g.length === 1 ? '' : 's' }}</span>
            <span class="text-zinc-600 ml-auto shrink-0">{{ expandedGalaxies.has(gi) ? '▾' : '▸' }}</span>
          </button>
          <div class="pl-4 text-zinc-300" :title="g.map(labelOf).join(', ')">
            <template v-if="expandedGalaxies.has(gi)">
              <div class="mt-0.5 max-h-24 overflow-auto space-y-0.5">
                <div v-for="s in g" :key="s" class="truncate">{{ labelOf(s) }}</div>
              </div>
            </template>
            <div v-else class="truncate">{{ previewMembers(g) }}</div>
          </div>
        </div>
      </div>
    </div>

    <!-- protocol legend = how services are bound (link colours) -->
    <div v-if="protocolsPresent.length" class="absolute right-3 bottom-3 z-10 max-w-[45%]">
      <button class="text-[10px] text-zinc-300 hover:text-white bg-zinc-900/80 border border-zinc-800 rounded px-1.5 py-0.5"
              :title="`${protocolsPresent.length} protocol(s) — the link colours`"
              @click="showProtoLegend = !showProtoLegend">
        {{ showProtoLegend ? '▾' : '▸' }} protocols ({{ protocolsPresent.length }})
      </button>
      <div v-if="showProtoLegend" class="mt-1 bg-zinc-900/85 border border-zinc-800 rounded p-2 flex flex-wrap gap-x-3 gap-y-1 justify-end">
        <span v-for="p in protocolsPresent" :key="p" class="inline-flex items-center gap-1 text-[10px] text-zinc-300">
          <span class="inline-block w-3.5 h-1 rounded-sm shrink-0" :style="{ backgroundColor: protocolColor(p) }"></span>{{ p }}
        </span>
      </div>
    </div>

    <!-- loading / empty overlays -->
    <div v-if="loading" class="absolute inset-0 flex items-center justify-center pointer-events-none">
      <div class="text-zinc-500 text-sm animate-pulse">mapping the cosmos…</div>
    </div>
    <div v-else-if="!err && worldsCount === 0"
         class="absolute inset-0 flex items-center justify-center pointer-events-none">
      <div class="text-zinc-600 text-sm text-center">
        no cross-service edges here<br />
        <span class="text-zinc-700 text-xs">import code repos (lodestar) into this project to see its constellation</span>
      </div>
    </div>

    <div v-if="err" class="absolute bottom-2 left-2 right-2 text-rose-400 text-xs z-20">{{ err }}</div>
    </div><!-- /graph column -->

    <!-- detail drawer — a flex SIBLING of the graph column (not an absolute overlay),
         so opening it reflows the graph narrower and keeps it visible (#301 item 3). -->
    <aside v-if="selected"
           class="w-80 shrink-0 h-full bg-zinc-900/95 border-l border-zinc-800 overflow-auto p-3 text-[13px]">
      <div class="flex items-start justify-between gap-2 mb-2">
        <div class="text-zinc-100 text-base font-medium leading-tight break-all">{{ selected.label }}</div>
        <button class="text-zinc-500 hover:text-zinc-200 shrink-0" title="close" @click="selected = null">✕</button>
      </div>

      <div class="flex items-center gap-2 mb-3 flex-wrap">
        <span v-if="galaxyIndexOf(selected.slug) >= 0"
              class="rounded-full px-2 py-0.5 text-[11px] font-medium"
              :style="{ background: galaxyColor(galaxyIndexOf(selected.slug)) + '22', color: galaxyColor(galaxyIndexOf(selected.slug)), border: `1px solid ${galaxyColor(galaxyIndexOf(selected.slug))}` }">
          platform {{ galaxyIndexOf(selected.slug) + 1 }}
        </span>
        <span class="text-zinc-600 text-[11px]">
          {{ degreeOf(selected.slug) }} link{{ degreeOf(selected.slug) === 1 ? '' : 's' }}
        </span>
        <span class="text-zinc-600 text-[11px]">mass {{ selected.mass.toFixed(1) }}</span>
      </div>

      <div class="text-zinc-500 text-[11px] mb-3">
        <span class="text-zinc-600">project</span> {{ selected.project || '—' }}<br />
        <span class="text-zinc-600">slug</span> <span class="break-all">{{ selected.slug }}</span>
      </div>

      <button class="w-full text-left rounded border border-sky-800/60 bg-sky-900/20 text-sky-300 hover:bg-sky-900/40 px-2 py-1 mb-4 text-[12px]"
              title="open this service's entity graph" @click="openEntityGraph(selected.slug)">
        → open entity graph
      </button>

      <!-- fellow services in this candidate platform -->
      <div v-if="galaxyMembers(selected.slug).length > 1">
        <div class="text-zinc-500 text-[11px] uppercase tracking-wide mb-1.5">
          platform {{ galaxyIndexOf(selected.slug) + 1 }} · {{ galaxyMembers(selected.slug).length }} services
        </div>
        <ul class="space-y-1">
          <li v-for="s in galaxyMembers(selected.slug)" :key="s"
              class="flex items-center gap-1.5 text-[12px]"
              :class="s === selected.slug ? 'text-zinc-200 font-medium' : 'text-zinc-400'">
            <span class="w-1.5 h-1.5 rounded-full shrink-0" :style="{ background: galaxyColor(galaxyIndexOf(selected.slug)) }"></span>
            <span class="truncate" :title="s">{{ labelOf(s) }}</span>
          </li>
        </ul>
      </div>
    </aside>
  </div>
</template>
