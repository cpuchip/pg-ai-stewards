<script setup lang="ts">
// Stewdio — the work-item cockpit. P0: the VS-Code-like dockview shell — three
// resizable/draggable panels (browser | artifact | chat). Real content wired in
// P1+. Spec: .spec/proposals/stewards-studio.md. dockview + its theme CSS are
// imported here (not globally) so they load lazily with this route only.
import { DockviewVue, type VueComponent } from 'dockview-vue'
import type { DockviewReadyEvent } from 'dockview'
import 'dockview-core/dist/styles/dockview.css'
import { useStewdioStore } from '../stores/stewdio'
import BrowserPanel from './stewdio/BrowserPanel.vue'
import ArtifactPanel from './stewdio/ArtifactPanel.vue'
import ChatPanel from './stewdio/ChatPanel.vue'

// touch the store so it's instantiated for the session (panels coordinate through it in P1+)
useStewdioStore()

// dockview maps these names → the Vue components it mounts in each panel.
// (The `as unknown as VueComponent` casts bridge an SFC's inferred type to
// dockview-vue's stricter VueComponent type — a known vue-tsc friction.)
const components: Record<string, VueComponent> = {
  browser: BrowserPanel as unknown as VueComponent,
  artifact: ArtifactPanel as unknown as VueComponent,
  chat: ChatPanel as unknown as VueComponent,
}

function onReady(event: DockviewReadyEvent) {
  const api = event.api
  // left → center → right, each docked to the right of the previous (resizable splits)
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
</script>

<template>
  <div class="h-full w-full">
    <DockviewVue
      class="dockview-theme-abyss"
      style="height: 100%; width: 100%;"
      :components="components"
      @ready="onReady"
    />
  </div>
</template>
