<script setup lang="ts">
// /library — the FIND-SOMETHING-IN-THE-CORPUS shelf (feat/lightening nav
// merge, 2026-07-07, per .spec/lightening/ui-merge-map.md). Studies, Lessons
// and Search are all entry points into the same stewards.docs/lessons corpus
// (browse, browse-a-different-kind, type-a-query), so they live here as tabs.
// The panels are the SAME components that used to own /studies, /lessons and
// /search — reused, not rewritten — and the old paths redirect into the
// matching tab with their query strings preserved (router.ts), which also
// keeps Studies'/Search's own internal router.replace('/studies'|'/search')
// URL-state writes working unchanged. Tab state lives in the path
// (/library/:tab). Detail route /studies/:slug stays a real route.
//
// The global "/" shortcut (App.vue + searchShortcut.ts) lands on
// /library/search and focuses Search's query box.
import { computed } from 'vue'
import { useRouter } from 'vue-router'
import Studies from './Studies.vue'
import Lessons from './Lessons.vue'
import Search from './Search.vue'

const props = defineProps<{ tab?: string }>()
const router = useRouter()

const TABS = [
  { key: 'studies', label: 'Studies', component: Studies },
  { key: 'lessons', label: 'Lessons', component: Lessons },
  { key: 'search', label: 'Search', component: Search },
] as const

const DEFAULT_TAB = 'studies'

const active = computed(
  () => TABS.find((t) => t.key === props.tab) ?? TABS.find((t) => t.key === DEFAULT_TAB)!,
)

function go(key: string) {
  router.push(`/library/${key}`)
}
</script>

<template>
  <div class="space-y-4">
    <div class="flex items-center justify-between flex-wrap gap-2">
      <h2 class="text-2xl font-semibold tracking-tight">Library</h2>
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
