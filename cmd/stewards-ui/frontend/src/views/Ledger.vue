<script setup lang="ts">
// /ledger — the GOVERNANCE/AUDIT shelf (feat/lightening nav merge, 2026-07-07,
// per .spec/lightening/ui-merge-map.md). Six read-mostly "is the system
// keeping its commitments" pages live here as tabs instead of six top-level
// nav slots: Covenant, Watchman, Bridge, Trust, Councils, Sabbath. The tab
// panels are the SAME components that used to own /covenants, /watchman,
// /bridge, /trust, /councils and /sabbath — reused, not rewritten — and the
// old paths redirect into the matching tab (router.ts) so bookmarks keep
// working. Tab state lives in the path (/ledger/:tab) so deep links and
// refresh keep the tab; same idiom as /wiki/page/:slug.
import { computed } from 'vue'
import { useRouter } from 'vue-router'
import Covenants from './Covenants.vue'
import Watchman from './Watchman.vue'
import BridgeState from './BridgeState.vue'
import Trust from './Trust.vue'
import Councils from './Councils.vue'
import Sabbath from './Sabbath.vue'

const props = defineProps<{ tab?: string }>()
const router = useRouter()

const TABS = [
  { key: 'covenant', label: 'Covenant', component: Covenants },
  { key: 'watchman', label: 'Watchman', component: Watchman },
  { key: 'bridge', label: 'Bridge', component: BridgeState },
  { key: 'trust', label: 'Trust', component: Trust },
  { key: 'councils', label: 'Councils', component: Councils },
  { key: 'sabbath', label: 'Sabbath', component: Sabbath },
] as const

// Smart default (merge-map guidance): NOT the first tab. Trust, Sabbath and
// Councils were all empty in the 2026-07-07 war-game walk and Covenant is a
// single config row; Watchman always has pass rows on a live system, so it
// is the "first tab with real content" heuristic without probing the backend.
const DEFAULT_TAB = 'watchman'

const active = computed(
  () => TABS.find((t) => t.key === props.tab) ?? TABS.find((t) => t.key === DEFAULT_TAB)!,
)

function go(key: string) {
  router.push(`/ledger/${key}`)
}
</script>

<template>
  <div class="space-y-4">
    <div class="flex items-center justify-between flex-wrap gap-2">
      <h2 class="text-2xl font-semibold tracking-tight">Ledger</h2>
      <div class="flex items-center gap-2 text-sm flex-wrap">
        <button
          v-for="t in TABS" :key="t.key"
          @click="go(t.key)"
          :class="active.key === t.key ? 'border-sky-600 text-sky-300 bg-sky-900/30' : 'border-zinc-700 text-zinc-400 hover:bg-zinc-800'"
          class="px-3 py-1 rounded border"
        >{{ t.label }}</button>
      </div>
    </div>

    <!-- Only the active tab is mounted (same as Graph.vue's v-if tabs), so
         each panel's own onMounted load fires when its tab is opened. -->
    <component :is="active.component" />
  </div>
</template>
