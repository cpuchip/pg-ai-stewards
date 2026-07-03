<script setup lang="ts">
// Stewdio — the work-item cockpit. The VS-Code-like dockview shell — three
// resizable/draggable panels (browser | artifact | chat). dockview + its theme
// CSS are imported here (not globally) so they load lazily with this route only.
// P4: the panel layout is serialized to localStorage (toJSON/fromJSON) so a
// user's arrangement survives reloads; "⟲ layout" resets to the default.
// Spec: .spec/proposals/stewards-studio.md.
import { ref, computed, watch } from 'vue'
import { DockviewVue, type VueComponent } from 'dockview-vue'
import type { DockviewApi, DockviewReadyEvent } from 'dockview'
import 'dockview-core/dist/styles/dockview.css'
import { useStewdioStore } from '../stores/stewdio'
import BrowserPanel from './stewdio/BrowserPanel.vue'
import ArtifactPanel from './stewdio/ArtifactPanel.vue'
import ChatPanel from './stewdio/ChatPanel.vue'
import SessionsPanel from './stewdio/SessionsPanel.vue'
import ModelsPanel from './stewdio/ModelsPanel.vue'
import WorldGraphPanel from './stewdio/WorldGraphPanel.vue'
import AttentionBell from './stewdio/AttentionBell.vue'

// the shared cockpit store — panels coordinate through it; we read store.dev here
// to drive the Details toggle (one surface, two depths) + gate the details-only panes.
const store = useStewdioStore()

const LAYOUT_KEY = 'stewdio.layout.v3' // v3: 'Library' rename + dev-pane pruning propagate to existing installs
let dockApi: DockviewApi | null = null
const showLauncher = ref(false)
const openPanelIds = ref<string[]>([]) // reactive — which panes are currently open (launcher dots)

// b3: VS-Code-style collapse of the LEFTMOST and RIGHTMOST columns. Geometric —
// the rail collapses whichever group sits at that edge, so wherever you dock a
// panel (e.g. Sessions on the left), the matching edge rail collapses it. The
// collapsed group is tracked by its dockview id so expand restores the exact
// group even at width 0; collapse state is re-derived from the DOM on every
// layout change (survives reload + close).
const savedEdgeW = { left: 300, right: 380 }
const collapsedId = ref<{ left: string | null; right: string | null }>({ left: null, right: null })
const edgeCollapsed = computed(() => ({ left: !!collapsedId.value.left, right: !!collapsedId.value.right }))

function groupWidth(g: { element: HTMLElement }): number {
  return Math.round(g.element.getBoundingClientRect().width)
}
// the group currently at a given edge (min left / max right), skipping any that
// are already collapsed so the next non-collapsed column becomes the edge.
function geomEdgeGroup(side: 'left' | 'right') {
  const groups = dockApi?.groups ?? []
  let best: (typeof groups)[number] | null = null
  let bestv = side === 'left' ? Infinity : -Infinity
  for (const g of groups) {
    if (groupWidth(g) < 24) continue
    const r = g.element.getBoundingClientRect()
    const v = side === 'left' ? r.left : r.right
    if (side === 'left' ? v < bestv : v > bestv) { bestv = v; best = g }
  }
  return best
}
function toggleEdge(side: 'left' | 'right') {
  if (!dockApi) return
  const cid = collapsedId.value[side]
  if (cid) {
    const g = dockApi.groups.find(x => x.id === cid)
    if (g) g.api.setSize({ width: savedEdgeW[side] })
    collapsedId.value = { ...collapsedId.value, [side]: null }
  } else {
    const g = geomEdgeGroup(side)
    if (!g) return
    savedEdgeW[side] = groupWidth(g) || savedEdgeW[side]
    g.api.setConstraints({ minimumWidth: 0 })
    g.api.setSize({ width: 0 })
    collapsedId.value = { ...collapsedId.value, [side]: g.id }
  }
}
function measureEdges() {
  // drop a tracked collapse if its group was removed or is no longer narrow.
  const c = { ...collapsedId.value }
  for (const side of ['left', 'right'] as const) {
    const id = c[side]
    if (!id) continue
    const g = dockApi?.groups.find(x => x.id === id)
    if (!g || groupWidth(g) > 24) c[side] = null
  }
  if (c.left !== collapsedId.value.left || c.right !== collapsedId.value.right) collapsedId.value = c
}

// dockview maps these names → the Vue components it mounts in each panel.
// (The `as unknown as VueComponent` casts bridge an SFC's inferred type to
// dockview-vue's stricter VueComponent type — a known vue-tsc friction.)
const components: Record<string, VueComponent> = {
  browser: BrowserPanel as unknown as VueComponent,
  artifact: ArtifactPanel as unknown as VueComponent,
  chat: ChatPanel as unknown as VueComponent,
  sessions: SessionsPanel as unknown as VueComponent,
  models: ModelsPanel as unknown as VueComponent,
  world: WorldGraphPanel as unknown as VueComponent,
}

// the windowing manager's catalog — every pane the user can open/reopen.
const PANELS: { id: string; component: string; title: string; dev?: boolean }[] = [
  { id: 'browser', component: 'browser', title: 'Library' },
  { id: 'artifact', component: 'artifact', title: 'Artifact' },
  { id: 'chat', component: 'chat', title: 'Chat' },
  { id: 'sessions', component: 'sessions', title: 'Sessions' },
  { id: 'world', component: 'world', title: 'World' }, // Loreworks 3D knowledge graph — the showpiece, on the everyday surface
  { id: 'models', component: 'models', title: 'Activity', dev: true }, // live models/tokens/dispatch stream → Details only
]
// the Activity pane is a details surface; hide it from the launcher unless Details is on.
const visiblePanels = computed(() => PANELS.filter(p => store.dev || !p.dev))

// open a panel by id — focus it if already open, else add it (reopens a closed pane).
function openPanel(p: { id: string; component: string; title: string }) {
  if (!dockApi) return
  const existing = dockApi.getPanel(p.id)
  if (existing) { existing.api.setActive() }
  else { dockApi.addPanel({ id: p.id, component: p.component, title: p.title }) }
  showLauncher.value = false
}

// the default 3-zone layout: left → center → right, each docked to the right.
function buildDefault(api: DockviewApi) {
  api.clear()
  api.addPanel({ id: 'browser', component: 'browser', title: 'Library' })
  api.addPanel({
    id: 'artifact', component: 'artifact', title: 'Artifact',
    position: { referencePanel: 'browser', direction: 'right' },
  })
  api.addPanel({
    id: 'chat', component: 'chat', title: 'Chat',
    position: { referencePanel: 'artifact', direction: 'right' },
  })
}

function onReady(event: DockviewReadyEvent) {
  const api = event.api
  dockApi = api

  // restore a saved layout if one parses + yields panels; else build the default.
  let restored = false
  const saved = localStorage.getItem(LAYOUT_KEY)
  if (saved) {
    try { api.fromJSON(JSON.parse(saved)); restored = api.panels.length > 0 }
    catch { try { api.clear() } catch { /* ignore */ } restored = false }
  }
  if (!restored) buildDefault(api)
  applyCatalogTitles() // a restored layout persists OLD pane titles (dockview toJSON) — re-apply the catalog (e.g. 'Models'→'Activity') without churning saved layouts
  closeDevPanes() // Details OFF is authoritative: drop any details-only pane a stale layout restored

  // persist on any layout change (lightly debounced) + keep the open-pane set fresh.
  const refreshOpen = () => { openPanelIds.value = api.panels.map(p => p.id) }
  refreshOpen()
  measureEdges()
  let t: number | null = null
  api.onDidLayoutChange(() => {
    refreshOpen()
    measureEdges()
    if (t !== null) clearTimeout(t)
    t = window.setTimeout(() => {
      try { localStorage.setItem(LAYOUT_KEY, JSON.stringify(api.toJSON())) } catch { /* quota — ignore */ }
    }, 400)
  })
}

function resetLayout() {
  localStorage.removeItem(LAYOUT_KEY)
  if (dockApi) buildDefault(dockApi)
}

// Dev OFF is authoritative over the SCREEN, not just the launcher menu: close any
// developer-only pane (PANELS dev:true) that a saved layout restored or that was
// open when Developer was switched off. Without this the Models pane — the biggest
// ops surface — could linger on the everyday view (visiblePanels only governs the
// launcher list). Closing it also avoids the "closed → can't reopen" dead-end,
// since the launcher re-lists it the moment Developer is back on.
function closeDevPanes() {
  if (!dockApi || store.dev) return
  for (const p of PANELS.filter(x => x.dev)) dockApi.getPanel(p.id)?.api.close()
}
// dockview persists each pane's title in its saved layout and restores it verbatim,
// so a rename in the PANELS catalog (e.g. 'Models'→'Activity') wouldn't reach a pane
// an existing user already had open. Re-assert the catalog title on every restored
// pane — cheaper + less disruptive than bumping LAYOUT_KEY (which resets arrangements).
function applyCatalogTitles() {
  if (!dockApi) return
  for (const p of PANELS) dockApi.getPanel(p.id)?.api.setTitle(p.title)
}
watch(() => store.dev, () => closeDevPanes())
</script>

<template>
  <div class="h-full w-full relative">
    <!-- b3: collapse/expand the leftmost (Work items) column, VS-Code style.
         z-40 + isolate (#301 item 4): the cockpit chrome must sit ABOVE a panel's
         WebGL canvas. A canvas is composited on its own layer and dockview promotes
         its containers (transform/will-change), which can let the canvas paint over
         plain z-20 chrome; an isolated high-z stacking context keeps the chrome on top
         (the canvas is also trapped low, see WorldGraphPanel/CosmosPanel). -->
    <button
      class="absolute top-1 left-2 z-40 isolate text-[11px] text-zinc-400 hover:text-zinc-100 bg-zinc-900/70 border border-zinc-800 rounded px-1.5 py-0.5"
      :title="edgeCollapsed.left ? 'show the left panel' : 'collapse the left panel'"
      @click="toggleEdge('left')">{{ edgeCollapsed.left ? '❯' : '❮' }}</button>
    <!-- windowing manager: open / reopen any pane -->
    <div class="absolute top-1 right-2 z-40 isolate flex items-center gap-1">
      <!-- the unified "Needs your answer" bell (89): every human-blocking item
           (Hinge reviews, the tool-effect gate, a paused pipeline stage, an A2A
           blocking question) in one place, superseding 84's tool-confirm-only tray. -->
      <AttentionBell />
      <!-- b3: collapse/expand the rightmost (Chat) column -->
      <button
        class="text-[11px] text-zinc-400 hover:text-zinc-100 bg-zinc-900/70 border border-zinc-800 rounded px-1.5 py-0.5"
        :title="edgeCollapsed.right ? 'show the right panel' : 'collapse the right panel'"
        @click="toggleEdge('right')">{{ edgeCollapsed.right ? '❮' : '❯' }}</button>
      <div class="relative">
        <button
          class="text-[11px] text-zinc-400 hover:text-zinc-100 bg-zinc-900/70 border border-zinc-800 rounded px-1.5 py-0.5"
          title="open or reopen a panel" @click="showLauncher = !showLauncher">▦ panels</button>
        <div v-if="showLauncher" class="absolute right-0 mt-1 w-40 rounded border border-zinc-800 bg-zinc-900 shadow-lg overflow-hidden">
          <button v-for="p in visiblePanels" :key="p.id"
                  class="w-full text-left px-2 py-1 text-[11px] text-zinc-300 hover:bg-zinc-800 flex items-center justify-between"
                  @click="openPanel(p)">
            <span>{{ p.title }}</span>
            <span class="text-emerald-500 text-[9px]">{{ openPanelIds.includes(p.id) ? '●' : '' }}</span>
          </button>
        </div>
      </div>
      <button
        class="text-[11px] text-zinc-500 hover:text-zinc-200 bg-zinc-900/70 border border-zinc-800 rounded px-1.5 py-0.5"
        title="reset the panel layout to the default" @click="resetLayout">⟲ layout</button>
      <!-- the one surface, two depths switch — OFF keeps the everyday surface clean;
           ON reveals the live Activity pane (models / tokens / dispatch stream),
           inline tool-call detail, and the developer/raw surfaces. -->
      <button
        class="text-[11px] rounded px-1.5 py-0.5 border"
        :class="store.dev
          ? 'text-emerald-300 border-emerald-700/60 bg-emerald-900/30'
          : 'text-zinc-500 hover:text-zinc-200 bg-zinc-900/70 border-zinc-800'"
        :title="store.dev
          ? 'Details mode ON — live activity, models, tokens & tool calls shown. Click to return to the clean surface.'
          : 'Details mode OFF — clean everyday surface. Click to see what the engine is doing (models, tokens, tool calls).'"
        @click="store.dev = !store.dev">⚙ Details</button>
    </div>
    <DockviewVue
      class="dockview-theme-abyss"
      style="height: 100%; width: 100%;"
      :components="components"
      @ready="onReady"
    />
  </div>
</template>
