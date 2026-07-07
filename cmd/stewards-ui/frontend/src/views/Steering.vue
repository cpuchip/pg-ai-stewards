<script setup lang="ts">
// /steering — HOW WORK GETS POINTED (feat/lightening nav merge, 2026-07-07,
// per .spec/lightening/ui-merge-map.md). Intents (the values a pipeline runs
// under), Projects (the corpus/bucket it's grouped into) and Scheduled (the
// cadence it fires on) set direction; work is DONE elsewhere (Stewdio /
// Work items). The panels are the SAME components that used to own /intents,
// /projects and /scheduled — reused, not rewritten — and the old paths
// redirect into the matching tab (router.ts). Tab state lives in the path
// (/steering/:tab) so deep links and refresh keep the tab.
import { computed } from 'vue'
import { useRouter } from 'vue-router'
import Intents from './Intents.vue'
import Projects from './Projects.vue'
import Scheduled from './Scheduled.vue'

const props = defineProps<{ tab?: string }>()
const router = useRouter()

const TABS = [
  { key: 'intents', label: 'Intents', component: Intents },
  { key: 'projects', label: 'Projects', component: Projects },
  { key: 'scheduled', label: 'Scheduled', component: Scheduled },
] as const

const DEFAULT_TAB = 'intents'

const active = computed(
  () => TABS.find((t) => t.key === props.tab) ?? TABS.find((t) => t.key === DEFAULT_TAB)!,
)

function go(key: string) {
  router.push(`/steering/${key}`)
}
</script>

<template>
  <div class="space-y-4">
    <div class="flex items-center justify-between flex-wrap gap-2">
      <h2 class="text-2xl font-semibold tracking-tight">Steering</h2>
      <div class="flex items-center gap-2 text-sm flex-wrap">
        <button
          v-for="t in TABS" :key="t.key"
          @click="go(t.key)"
          :class="active.key === t.key ? 'border-sky-600 text-sky-300 bg-sky-900/30' : 'border-zinc-700 text-zinc-400 hover:bg-zinc-800'"
          class="px-3 py-1 rounded border"
        >{{ t.label }}</button>
      </div>
    </div>

    <!-- Only the active tab is mounted (same as Graph.vue's v-if tabs). -->
    <component :is="active.component" />
  </div>
</template>
