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
import { useRoute, useRouter } from 'vue-router'
import ForceGraph3D from '3d-force-graph'
import SpriteText from 'three-spritetext'
import { api, type WorldGraphResp, type WorldNode, type WorldNodeDetail, type WorldBrief } from '@/api'
import { useStewdioStore } from '../../stores/stewdio'
import CosmosPanel from './CosmosPanel.vue'

// This panel is embedded OUTSIDE Stewdio too (the /graph Graphs hub). The chat
// it opens lives in Stewdio's cockpit, so when we're elsewhere, hop there —
// the staged openChat is honored on mount (ChatPanel's immediate watchers).
const route = useRoute()
const router = useRouter()

defineOptions({ inheritAttrs: false })
const store = useStewdioStore()

// view mode: 'world' = this world's entity graph (the original panel); 'cosmos'
// = the cross-service constellation (CosmosPanel, mounted alongside via v-show so
// its graph survives a toggle). One toggle, two lenses on the same knowledge.
const mode = ref<'world' | 'cosmos'>('world')

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

// edge colour by RELATIONSHIP type, so the connecting lines actually read as a
// graph. Before, links were a near-invisible dim gray at the lib's default 0.2
// opacity — all you saw was the directional particles. Now each `rel` gets a
// stable bright colour from a categorical palette (deterministic hash → palette),
// surfaced in a legend so the colours mean something.
const REL_PALETTE = [
  '#f87171', '#fb923c', '#fbbf24', '#a3e635', '#34d399', '#22d3ee',
  '#60a5fa', '#a78bfa', '#f472b6', '#e879f9', '#fca5a5', '#5eead4',
]
function relColor(rel: string): string {
  let h = 0
  const s = rel || ''
  for (let i = 0; i < s.length; i++) h = (h * 31 + s.charCodeAt(i)) >>> 0
  return REL_PALETTE[h % REL_PALETTE.length] ?? '#94a3b8'
}
const relsPresent = ref<string[]>([]) // distinct relationship types in view → the legend
const showLegend = ref(true)

// the default sphere radius in 3d-force-graph is cbrt(nodeVal) · nodeRelSize.
// We pin nodeRelSize so the label offset (below) uses the same constant and a
// name always clears its circle, hub or leaf.
const NODE_REL_SIZE = 4
const nodeRadius = (n: WorldNode) => Math.cbrt(1 + (n.degree ?? 0)) * NODE_REL_SIZE

const el = ref<HTMLDivElement>()
const worlds = ref<WorldBrief[]>([])
const selected = ref<WorldNodeDetail | WorldNode | null>(null)
const detail = ref<WorldNodeDetail | null>(null) // lazily-loaded typed edges + metadata

// #301 item 1 — richer node detail. The graph node carries no metadata (we don't
// bloat every node); the lazily-loaded /node detail does. For a code entity it
// surfaces the HTTP route (method + path) and the repo-relative file; source_url
// (item 5) is the browsable "↗ source" link the server builds from repo_origin +
// file_path + the world's ref. All empty for lore entities → the block hides.
const nodeMeta = computed(() => detail.value?.metadata ?? null)
const nodeRoute = computed(() => {
  const m = nodeMeta.value
  if (!m) return ''
  const method = String(m.method ?? '').trim()
  const path = String(m.path ?? '').trim()
  return method || path ? `${method} ${path}`.trim() : ''
})
const nodeFile = computed(() => String(nodeMeta.value?.file_path ?? '').trim())
const nodeSourceUrl = computed(() => detail.value?.source_url ?? '')
const active = ref(new Set<string>())            // kinds currently shown
const activeProjects = ref(new Set<string>())    // source projects/buckets currently shown (cross-project toggle)
const query = ref('')
const err = ref('')
const loading = ref(false)
const orbiting = ref(true)
const showSearch = ref(false)

// ── huge-world guardrails ─────────────────────────────────────────────────
// A lodestar-imported platform world can carry 10k+ entities. The showpiece
// styling is PER-NODE/PER-EDGE expensive: a SpriteText label = one canvas
// texture per node; linkWidth>0 = one tube MESH per edge; particles+arrows =
// per-frame CPU work per edge. At that scale the scene saturates the browser's
// shared GPU process — which every window on the machine (and the DWM
// compositor: the Start menu!) depends on. Two walls:
//   1. the server caps the payload to the top-N entities by degree (MAX_NODES),
//   2. above the LITE thresholds we drop to cheap rendering: GL lines (one
//      draw call for ALL edges), labels only on the top hubs + hover, faceted
//      spheres, no particles/arrows, and no blocking warmup ticks.
const MAX_NODES = 3000            // server-side top-N cap per load
const LITE_NODES = 1200           // lite rendering above this many nodes…
const LITE_LINKS = 2000           // …or this many links
const HUB_LABELS = 120            // in lite mode, only the top-K hubs get labels
let lite = false                  // current render tier (set per load)
let hubIds = new Set<number>()    // nodes that keep a SpriteText label in lite mode
const truncNote = ref('')         // "showing top N of M…" banner text

// "Build a World" — self-serve: name + a canon source (upload a PDF/zip, an
// existing project, or pasted canon) → dispatch the world-build agent. The same
// form EXPANDS an existing world: reuse its name + project and upload more.
const showBuild = ref(false)
const projects = ref<{ name: string; doc_count?: number }[]>([])
const buildName = ref('')
const buildProject = ref('')
const buildRefs = ref<string[]>([])   // other projects to reference + cross-link
const buildCanon = ref('')
const buildInstr = ref('')
const buildFile = ref<File | null>(null)
const building = ref(false)
const buildErr = ref('')
const chatting = ref(false)   // "Chat with this world" dispatch in flight
// projects available to reference (exclude the primary the user typed).
const refCandidates = computed(() => projects.value.filter(p => p.name && p.name !== buildProject.value.trim()))
function onBuildFile(e: Event) {
  buildFile.value = (e.target as HTMLInputElement).files?.[0] ?? null
}

// eslint-disable-next-line @typescript-eslint/no-explicit-any
type Graph = any
let graph: Graph | null = null
let nodeById = new Map<number, WorldNode>()
let ro: ResizeObserver | null = null
let resizeRaf = 0

const kinds = computed(() => [...new Set([...nodeById.values()].map(n => n.kind))].sort())
// the buckets present in this world's graph (a cross-project world has >1) — drive
// the per-project show/hide toggle.
const graphProjects = computed(() => [...new Set([...nodeById.values()].flatMap(n => n.projects ?? []))].sort())
function toggleProject(p: string) {
  const next = new Set(activeProjects.value)
  if (next.has(p)) next.delete(p); else next.add(p)
  activeProjects.value = next
  applyVisibility()
}
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
  const onP = activeProjects.value
  // a node shows if its KIND is on AND (it has no project, or at least one of its
  // projects is on) — so toggling a referenced bucket off hides its nodes.
  const nodeVisible = (n: WorldNode): boolean => {
    if (!on.has(n.kind)) return false
    const ps = n.projects ?? []
    if (ps.length === 0) return true
    return ps.some(p => onP.has(p))
  }
  // After the first tick l.source/l.target are node objects; pre-tick they're ids
  // — resolve against nodeById so the predicate is correct on the very first frame.
  const resolve = (end: number | WorldNode): WorldNode | undefined =>
    typeof end === 'object' ? end : nodeById.get(end)
  graph.nodeVisibility((n: WorldNode) => nodeVisible(n))
  graph.linkVisibility((l: { source: number | WorldNode; target: number | WorldNode }) => {
    const s = resolve(l.source), t = resolve(l.target)
    return !!s && !!t && nodeVisible(s) && nodeVisible(t)
  })
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

// O3: a ref can carry an `object` locator (att:<id>) → open the EXACT source
// page/image in the artifact panel (the object viewer), not just the derived doc.
function openObject(locator?: string) {
  if (!locator) return
  store.select(locator, 'object', locator)
}

function neighborNode(id: number): WorldNode | null {
  return nodeById.get(id) ?? null
}
function focusNeighbor(id: number) {
  const n = neighborNode(id)
  if (n) selectNode(n)
}

// applyRenderTier flips the expensive showpiece styling on/off for the CURRENT
// graph size. Must run BEFORE graphData() so the objects are built in the right
// tier (nodeThreeObject / link geometry are chosen at build time).
function applyRenderTier(nodes: WorldNode[], linkCount: number) {
  if (!graph) return
  lite = nodes.length > LITE_NODES || linkCount > LITE_LINKS
  hubIds = new Set<number>()
  if (lite) {
    // top-K hubs by degree keep their name labels; the rest label on hover.
    const ranked = [...nodes].sort((a, b) => (b.degree ?? 0) - (a.degree ?? 0))
    for (const n of ranked.slice(0, HUB_LABELS)) hubIds.add(n.id)
  }
  graph
    .nodeResolution(lite ? 8 : 18)              // faceted spheres are ~5× fewer triangles
    .linkWidth(lite ? 0 : 1.4)                  // 0 → GL LineSegments: ONE draw call for all edges (>0 = a tube mesh PER edge)
    .linkOpacity(lite ? 0.35 : 0.7)
    .linkDirectionalParticles(lite ? 0 : 2)     // particles recompute per-frame per-edge on the CPU
    .linkDirectionalArrowLength(lite ? 0 : 3.2) // each arrow is its own cone mesh
    .warmupTicks(lite ? 0 : 60)                 // never BLOCK the main thread pre-settling a big sim
    .cooldownTime(lite ? 8000 : 4000)
}

async function loadWorld(slug: string) {
  if (!graph || !slug) return
  err.value = ''
  loading.value = true
  selected.value = null
  detail.value = null
  truncNote.value = ''
  try {
    const g: WorldGraphResp = await api.worldGraph(slug, true, MAX_NODES)
    nodeById = new Map(g.nodes.map(n => [n.id, n]))
    active.value = new Set(g.nodes.map(n => n.kind)) // all kinds on
    activeProjects.value = new Set(g.nodes.flatMap(n => n.projects ?? [])) // all buckets on
    relsPresent.value = [...new Set(g.links.map(l => l.rel).filter(Boolean))].sort() // legend
    applyRenderTier(g.nodes, g.links.length)
    if (g.truncated && g.total_nodes) {
      truncNote.value = `big world — showing the top ${g.nodes.length.toLocaleString()} of ${g.total_nodes.toLocaleString()} entities (by connections); search covers what's shown`
    } else if (lite) {
      truncNote.value = `${g.nodes.length.toLocaleString()} entities — lite rendering (labels on hubs + hover)`
    }
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
  // Hidden (v-show → display:none) or not yet laid out: skip. Sizing to 0×0 is
  // pointless AND poisons the trackball rect (see below). The ResizeObserver
  // re-fires with the real size the moment the panel is shown, self-healing.
  if (r.width === 0 || r.height === 0) return
  graph.width(r.width).height(r.height)
  // #301 item 2 — the mouse-freeze fix. TrackballControls caches its screen rect
  // ONCE at construction (three's TrackballControls.handleResize, called only from
  // the ctor) and 3d-force-graph never calls it again on resize. So a graph built
  // or resized while hidden (0×0) keeps a stale/zero screen → the rotate/pan math
  // divides by screen.width/height = 0 → NaN → orbit frozen, while click raycasting
  // (which uses the live canvas rect) still works. Recompute it against the now-live
  // element every resize. Guarded: only trackball/orbit expose handleResize.
  ;(graph.controls() as { handleResize?: () => void }).handleResize?.()
}

function toggleBuild() {
  showBuild.value = !showBuild.value
  if (showBuild.value) {
    buildName.value = ''; buildProject.value = ''; buildRefs.value = []; buildCanon.value = ''; buildInstr.value = ''; buildErr.value = ''; buildFile.value = null
    // selectable projects = formal + corpus tags (so an imported corpus shows up)
    api.worldProjects().then(r => { projects.value = r.items ?? [] }).catch(() => {})
  }
}

// dispatch the world-build agent over the chosen canon, then switch to the new
// world and open the build session so the user watches the graph fill in.
async function buildWorld() {
  const name = buildName.value.trim()
  if (!name) { buildErr.value = 'name the world'; return }
  if (!buildFile.value && !buildProject.value.trim() && !buildCanon.value.trim()) {
    buildErr.value = 'give it a source — upload a file, pick/name a project, or paste canon'; return
  }
  building.value = true; buildErr.value = ''
  try {
    const r = await api.worldBuild({
      name,
      project: buildProject.value.trim() || undefined,
      reference_projects: buildRefs.value.length ? buildRefs.value : undefined,
      canon: buildCanon.value.trim() || undefined,
      instructions: buildInstr.value.trim() || undefined,
      file: buildFile.value || undefined,
    })
    showBuild.value = false
    worlds.value = (await api.worldList()).items   // pick up the freshly-registered world
    store.worldSlug = r.slug
    store.requestedSession = r.session_id          // open the build session in chat to watch it work
  } catch (e) {
    buildErr.value = String(e)
  } finally {
    building.value = false
  }
}

// "Chat with this world" — open a read-only loremaster session grounded in the
// current world. The first turn runs the loremaster agent (which has world_neighbors
// for cross-service links); we then open that session in the cockpit chat. Grounded
// on '__all__' so chatRef is truthy and requestedSession reliably opens the chat —
// the world grounding itself lives in the session (seeded server-side).
async function chatThisWorld() {
  const slug = store.worldSlug
  if (!slug || chatting.value) return
  chatting.value = true
  err.value = ''
  try {
    const r = await api.chatWithWorld(slug)
    store.openChat('', 'all', '', r.session_id)
    if (route.path !== '/stewdio') router.push('/stewdio')
  } catch (e) {
    err.value = String(e)
  } finally {
    chatting.value = false
  }
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
      // ★ huge-world wall: every SpriteText is its OWN canvas texture on the
      // GPU. In lite mode only the top hubs get one — the rest are plain
      // spheres with the built-in hover tooltip (nodeLabel), which costs
      // nothing until pointed at. Returning undefined = default sphere only.
      if (lite && !hubIds.has(n.id)) return undefined as unknown as object
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
    .linkColor((l: { rel: string }) => relColor(l.rel)) // colour-coded by relationship
    .linkWidth(1.4)                                      // visible lines (was 0.5)
    .linkOpacity(0.7)                                    // the lib defaults to 0.2 → near-invisible
    .linkDirectionalParticles(2)
    .linkDirectionalParticleWidth(1.6)
    .linkDirectionalParticleColor((l: { rel: string }) => relColor(l.rel)) // particles match the line
    .linkDirectionalParticleSpeed(0.006)
    .linkDirectionalArrowLength(3.2)
    .linkDirectionalArrowColor((l: { rel: string }) => relColor(l.rel))
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

// pause this graph's WebGL loop while the cosmos lens is showing (two live
// force graphs shouldn't both burn GPU); resume + re-fit when we come back.
watch(mode, (m) => {
  if (!graph) return
  if (m === 'cosmos') graph.pauseAnimation()
  else { graph.resumeAnimation(); nextTick(resize) }
})

onUnmounted(() => {
  cancelAnimationFrame(resizeRaf)
  ro?.disconnect()
  try { graph?._destructor?.() } catch { /* ignore */ }
  graph = null
})
</script>

<template>
  <div class="h-full w-full relative bg-zinc-950 overflow-hidden">
    <!-- WORLD mode — this world's entity graph (the original panel) -->
    <div v-show="mode === 'world'" class="h-full w-full flex relative overflow-hidden">
    <!-- graph column — the relative host for the absolute toolbar / legends / overlays.
         The detail drawer (below) is a flex SIBLING that reflows this column narrower
         when open (#301 item 3), instead of overlaying and hiding the graph. min-w-0
         lets this flex column shrink below the canvas's pixel width when the drawer
         opens (default min-width:auto would pin it and clip instead of reflow). -->
    <div class="relative flex-1 min-w-0 min-h-0 flex flex-col overflow-hidden">
    <!-- toolbar: mode toggle · world picker · search · legend/filter chips · orbit -->
    <div class="absolute top-1 left-2 right-2 z-20 flex items-center gap-2 flex-wrap text-[11px]">
      <!-- mode toggle: World ⇄ Cosmos (cross-service) -->
      <div class="inline-flex rounded overflow-hidden border border-zinc-700 shrink-0">
        <button class="px-1.5 py-0.5 bg-sky-900/50 text-sky-200"
                title="this world's entity graph">🌍 World</button>
        <button class="px-1.5 py-0.5 text-zinc-400 hover:text-zinc-100 hover:bg-zinc-800 border-l border-zinc-700"
                title="the cross-service constellation" @click="mode = 'cosmos'">✦ Cosmos</button>
      </div>
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
      <button
        @click="toggleBuild"
        class="rounded px-1.5 py-0.5 border border-emerald-700/60 text-emerald-300 bg-emerald-900/30 hover:bg-emerald-900/50"
        title="build a new world from a source corpus">🌍 build</button>

      <!-- Chat with this world → a read-only loremaster session (asks the graph,
           incl. cross-service links via world_neighbors) -->
      <button
        @click="chatThisWorld"
        :disabled="chatting || !store.worldSlug"
        class="rounded px-1.5 py-0.5 border border-sky-700/60 text-sky-300 bg-sky-900/30 hover:bg-sky-900/50 disabled:opacity-50"
        :title="`chat with ${currentWorld?.name || 'this world'} — ask the loremaster (cross-service links included)`">
        {{ chatting ? '…' : '💬 Chat' }}</button>

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

      <!-- per-project (bucket) toggle — only for a cross-project world. Hide a
           referenced bucket's nodes for performance / visual ease. -->
      <template v-if="graphProjects.length > 1">
        <span class="text-zinc-700 mx-0.5">|</span>
        <button v-for="p in graphProjects" :key="'proj-'+p"
                @click="toggleProject(p)"
                class="rounded px-1.5 py-0.5 border border-zinc-700 flex items-center gap-1 transition-opacity"
                :class="activeProjects.has(p) ? 'opacity-100 text-emerald-300 bg-emerald-900/20' : 'opacity-40 text-zinc-400'"
                :title="activeProjects.has(p) ? `hide project ${p}` : `show project ${p}`">
          <span>📁</span><span>{{ p }}</span>
        </button>
      </template>

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

    <!-- Build a World form -->
    <div v-if="showBuild" class="absolute top-9 left-2 right-2 z-30 rounded-lg border border-zinc-800 bg-zinc-900/95 shadow-xl p-3 space-y-2 text-[12px] max-w-md">
      <div class="text-zinc-300 font-medium">🌍 Build a world <span class="text-zinc-600 font-normal">(or expand one)</span></div>
      <input v-model="buildName" placeholder="world name (e.g. Star Trek Adventures)"
             class="w-full bg-zinc-950 border border-zinc-800 rounded px-2 py-1 text-zinc-200" />

      <!-- canon source: upload a file (primary) -->
      <div>
        <label class="text-zinc-500 text-[11px]">Canon — upload a PDF / Office doc / zip / folder:</label>
        <input type="file" @change="onBuildFile"
               accept=".pdf,.txt,.md,.markdown,.html,.htm,.docx,.doc,.pptx,.xlsx,.zip,.epub"
               class="w-full text-[11px] text-zinc-300 mt-0.5 file:mr-2 file:rounded file:border-0 file:bg-zinc-800 file:px-2 file:py-1 file:text-zinc-200" />
        <div v-if="buildFile" class="text-emerald-400 text-[10px] mt-0.5">{{ buildFile.name }} ({{ (buildFile.size/1048576).toFixed(1) }} MB)</div>
      </div>

      <!-- project: new (type a name) OR existing (pick from the list, incl. imported corpora) -->
      <div>
        <label class="text-zinc-500 text-[11px]">Project — a new name, or pick an existing one to add to / build from:</label>
        <input v-model="buildProject" list="world-projects" placeholder="defaults to the world name"
               class="w-full bg-zinc-950 border border-zinc-800 rounded px-2 py-1 text-zinc-200 mt-0.5" />
        <datalist id="world-projects">
          <option v-for="p in projects" :key="p.name" :value="p.name">{{ p.name }}<span v-if="p.doc_count"> · {{ p.doc_count }} docs</span></option>
        </datalist>
      </div>

      <!-- reference other projects — read them too + cross-link (merge into one graph) -->
      <div v-if="refCandidates.length">
        <label class="text-zinc-500 text-[11px]">Reference other projects (read + cross-link into this graph):</label>
        <div class="mt-0.5 max-h-24 overflow-auto rounded border border-zinc-800 bg-zinc-950 p-1 space-y-0.5">
          <label v-for="p in refCandidates" :key="p.name" class="flex items-center gap-1.5 px-1 py-0.5 rounded hover:bg-zinc-900 cursor-pointer">
            <input type="checkbox" :value="p.name" v-model="buildRefs" class="accent-emerald-600" />
            <span class="text-zinc-300">{{ p.name }}</span>
            <span v-if="p.doc_count" class="text-zinc-600 ml-auto">{{ p.doc_count }} docs</span>
          </label>
        </div>
        <div v-if="buildRefs.length" class="text-emerald-400 text-[10px] mt-0.5">+ {{ buildRefs.join(', ') }}</div>
      </div>

      <div class="text-zinc-600 text-[10px]">…or paste canon directly (for a small/quick world):</div>
      <textarea v-model="buildCanon" rows="2" placeholder="paste source lore here (optional)"
                class="w-full bg-zinc-950 border border-zinc-800 rounded px-2 py-1 text-zinc-200 resize-none"></textarea>
      <input v-model="buildInstr" placeholder="extra direction (optional, e.g. focus on factions + ships)"
             class="w-full bg-zinc-950 border border-zinc-800 rounded px-2 py-1 text-zinc-200" />
      <div class="flex items-center gap-2">
        <button :disabled="building" class="text-xs px-3 py-1 rounded bg-emerald-600 text-white disabled:opacity-50" @click="buildWorld">
          {{ building ? 'dispatching…' : 'Build' }}
        </button>
        <button class="text-xs px-2 py-1 rounded text-zinc-400 hover:text-zinc-200" @click="showBuild = false">Cancel</button>
        <span v-if="buildErr" class="text-rose-400 text-[11px] truncate">{{ buildErr }}</span>
      </div>
      <div class="text-zinc-600 text-[10px] leading-snug">Upload → it's imported into the project, then the world-build agent extracts entities + relationships. Reuse an existing world name + project to EXPAND it (new lore merges in). Runs as a chat session (opens on the right); the graph fills in — re-pick the world to refresh. Private by default.</div>
    </div>

    <!-- the 3D canvas. `isolate z-0` (#301 item 4): a WebGL canvas is promoted to
         its own compositing layer, and dockview promotes its containers too (via
         transform/will-change), which let the canvas layer paint OVER the cockpit
         chrome (the ▦ panels menu / selectors). Isolating the canvas into its own
         low stacking context traps it below that chrome. -->
    <div ref="el" class="flex-1 min-h-0 relative z-0 isolate"></div>

    <!-- edge colour legend — what the connecting lines mean (relationship types) -->
    <div v-if="relsPresent.length" class="absolute left-3 bottom-3 z-10 max-w-[55%]">
      <button class="text-[10px] text-zinc-300 hover:text-white bg-zinc-900/80 border border-zinc-800 rounded px-1.5 py-0.5"
              :title="`${relsPresent.length} relationship type(s) — the edge colours`"
              @click="showLegend = !showLegend">{{ showLegend ? '▾' : '▸' }} edges ({{ relsPresent.length }})</button>
      <div v-if="showLegend" class="mt-1 bg-zinc-900/85 border border-zinc-800 rounded p-2 max-h-44 overflow-auto flex flex-wrap gap-x-3 gap-y-1">
        <span v-for="r in relsPresent" :key="r" class="inline-flex items-center gap-1 text-[10px] text-zinc-300">
          <span class="inline-block w-3.5 h-1 rounded-sm shrink-0" :style="{ backgroundColor: relColor(r) }"></span>{{ r }}
        </span>
      </div>
    </div>

    <!-- huge-world banner: what the cap/lite tier is doing, so a truncated view
         never masquerades as the whole world -->
    <div v-if="truncNote" class="absolute top-9 left-2 z-10">
      <span class="text-[10px] text-amber-300/90 bg-zinc-900/85 border border-amber-800/50 rounded px-1.5 py-0.5">
        ⚡ {{ truncNote }}
      </span>
    </div>

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

    <div v-if="err" class="absolute bottom-2 left-2 right-2 text-rose-400 text-xs z-20">{{ err }}</div>
    </div><!-- /graph column -->

    <!-- detail drawer — a flex SIBLING of the graph column (not an absolute overlay),
         so opening it reflows the graph narrower and keeps it visible (#301 item 3).
         The graph's ResizeObserver re-fits the canvas when the column width changes. -->
    <aside v-if="selected"
           class="w-80 shrink-0 h-full bg-zinc-900/95 border-l border-zinc-800 overflow-auto p-3 text-[13px]">
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

      <!-- #301 item 1 + 5 — entity details: the HTTP route (method + path) and the
           repo-relative file for a code entity, plus a "↗ source" link to the file on
           the branch (item 5). Hidden entirely for lore entities (no such metadata). -->
      <div v-if="nodeRoute || nodeFile || nodeSourceUrl" class="mb-3 space-y-1 text-[12px]">
        <div v-if="nodeRoute" class="flex items-baseline gap-1.5">
          <span class="text-zinc-600 shrink-0">route</span>
          <code class="text-sky-300 break-all">{{ nodeRoute }}</code>
        </div>
        <div v-if="nodeFile" class="flex items-baseline gap-1.5">
          <span class="text-zinc-600 shrink-0">file</span>
          <code class="text-zinc-300 break-all">{{ nodeFile }}</code>
        </div>
        <a v-if="nodeSourceUrl" :href="nodeSourceUrl" target="_blank" rel="noopener noreferrer"
           class="inline-flex items-center gap-1 text-emerald-400 hover:text-emerald-300"
           :title="nodeSourceUrl">↗ source</a>
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
          <div class="text-[11px] mt-0.5 flex items-center gap-2 flex-wrap">
            <button v-if="isDocSlug(s.doc)" class="text-sky-500 hover:text-sky-400"
                    :title="`open ${s.doc} in the artifact panel`" @click="openDoc(s.doc)">
              {{ s.doc }}<span v-if="s.chunk != null"> · chunk {{ s.chunk }}</span>
            </button>
            <span v-else-if="s.doc || s.chunk != null" class="text-zinc-600">
              {{ s.doc || 'source' }}<span v-if="s.chunk != null"> · chunk {{ s.chunk }}</span>
            </span>
            <!-- O3: jump to the EXACT original page/image this was pulled from -->
            <button v-if="s.object" class="text-emerald-400 hover:text-emerald-300"
                    :title="`open the source ${s.page != null ? 'page ' + s.page : 'file'}`"
                    @click="openObject(s.object)">
              🖼 source<span v-if="s.page != null"> · p{{ s.page }}</span>
            </button>
          </div>
        </div>
      </div>
    </aside>
    </div>

    <!-- COSMOS mode — the cross-service constellation (its own graph, kept alive
         via v-show so a toggle doesn't tear down + reflow the force layout) -->
    <div v-show="mode === 'cosmos'" class="h-full w-full">
      <CosmosPanel :mode="mode" @update:mode="mode = $event" />
    </div>
  </div>
</template>
