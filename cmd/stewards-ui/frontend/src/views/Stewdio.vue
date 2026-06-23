<script setup lang="ts">
// Stewdio — the work-item cockpit. The VS-Code-like dockview shell — three
// resizable/draggable panels (browser | artifact | chat). dockview + its theme
// CSS are imported here (not globally) so they load lazily with this route only.
// P4: the panel layout is serialized to localStorage (toJSON/fromJSON) so a
// user's arrangement survives reloads; "⟲ layout" resets to the default.
// Spec: .spec/proposals/stewards-studio.md.
import { DockviewVue, type VueComponent } from 'dockview-vue'
import type { DockviewApi, DockviewReadyEvent } from 'dockview'
import 'dockview-core/dist/styles/dockview.css'
import { useStewdioStore } from '../stores/stewdio'
import BrowserPanel from './stewdio/BrowserPanel.vue'
import ArtifactPanel from './stewdio/ArtifactPanel.vue'
import ChatPanel from './stewdio/ChatPanel.vue'

// touch the store so it's instantiated for the session (panels coordinate through it)
useStewdioStore()

const LAYOUT_KEY = 'stewdio.layout.v1'
let dockApi: DockviewApi | null = null

// dockview maps these names → the Vue components it mounts in each panel.
// (The `as unknown as VueComponent` casts bridge an SFC's inferred type to
// dockview-vue's stricter VueComponent type — a known vue-tsc friction.)
const components: Record<string, VueComponent> = {
  browser: BrowserPanel as unknown as VueComponent,
  artifact: ArtifactPanel as unknown as VueComponent,
  chat: ChatPanel as unknown as VueComponent,
}

// the default 3-zone layout: left → center → right, each docked to the right.
function buildDefault(api: DockviewApi) {
  api.clear()
  api.addPanel({ id: 'browser', component: 'browser', title: 'Work items' })
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

  // persist on any layout change (lightly debounced).
  let t: number | null = null
  api.onDidLayoutChange(() => {
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
</script>

<template>
  <div class="h-full w-full relative">
    <button
      class="absolute top-1 right-2 z-20 text-[11px] text-zinc-500 hover:text-zinc-200 bg-zinc-900/70 border border-zinc-800 rounded px-1.5 py-0.5"
      title="reset the panel layout to the default" @click="resetLayout">⟲ layout</button>
    <DockviewVue
      class="dockview-theme-abyss"
      style="height: 100%; width: 100%;"
      :components="components"
      @ready="onReady"
    />
  </div>
</template>
