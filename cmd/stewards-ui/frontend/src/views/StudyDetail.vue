<script setup lang="ts">
import { ref, watch, onMounted, computed } from 'vue'
import { useRoute, useRouter, RouterLink } from 'vue-router'
import MarkdownIt from 'markdown-it'
import { api, type StudyDetail } from '@/api'
import SourcesPulledPanel from './wiki/SourcesPulledPanel.vue'
import { makeLinkClick } from './stewdio/useDocLinks'

const route = useRoute()
const router = useRouter()
const md = new MarkdownIt({ html: false, linkify: true, typographer: false })

// War-game 2026-07-07 finding #5: this page rendered the doc body with plain
// v-html and no link handler, so a relative markdown link like
// `[Full report](other-doc.md)` fell through to the browser's own relative-URL
// resolution → `/studies/other-doc.md` → a 404 (the API's slug has no `.md`).
// makeLinkClick already solves this for Stewdio's ArtifactPanel/ChatPanel
// (strips the .md + basename); reuse it here instead of duplicating the regex.
const onLink = makeLinkClick((ref, kind) => {
  router.push(kind === 'work_item' ? `/work-items/${encodeURIComponent(ref)}` : `/studies/${encodeURIComponent(ref)}`)
})

const study = ref<StudyDetail | null>(null)
const error = ref<string>('')
const loading = ref(false)
// "Sources pulled" tab (WIKI-GRAPH item 4) — reset whenever the slug changes.
const tab = ref<'doc' | 'sources'>('doc')

async function load(slug: string) {
  loading.value = true
  error.value = ''
  study.value = null
  tab.value = 'doc'
  try {
    study.value = await api.studyGet(slug)
  } catch (e) {
    error.value = String(e)
  } finally {
    loading.value = false
  }
}

const slugFromRoute = computed(() => String(route.params.slug ?? ''))

onMounted(() => load(slugFromRoute.value))
watch(slugFromRoute, (s) => {
  if (s) load(s)
})

const renderedBody = computed(() => {
  if (!study.value?.body) return ''
  return md.render(study.value.body)
})

function fmtDate(s?: string) {
  if (!s) return ''
  return new Date(s).toLocaleString()
}
</script>

<template>
  <div class="space-y-6">
    <div>
      <RouterLink to="/studies" class="text-xs text-zinc-500 hover:text-zinc-300">
        ← all studies
      </RouterLink>
    </div>

    <p v-if="loading" class="text-sm text-zinc-400">loading…</p>
    <p v-else-if="error" class="text-sm text-red-400">{{ error }}</p>

    <template v-if="study">
      <header class="border-b border-zinc-800 pb-4">
        <h2 class="text-2xl font-semibold tracking-tight">{{ study.title || study.slug }}</h2>
        <div class="text-xs text-zinc-500 mt-2 flex gap-3 font-mono">
          <span>kind: {{ study.kind }}</span>
          <span>slug: {{ study.slug }}</span>
          <span v-if="study.updated_at">updated: {{ fmtDate(study.updated_at) }}</span>
        </div>
      </header>

      <!-- Doc ⇄ Sources pulled tab strip (WIKI-GRAPH item 4) -->
      <div class="inline-flex rounded overflow-hidden border border-zinc-700 text-xs">
        <button class="px-2 py-1" :class="tab === 'doc' ? 'bg-sky-900/50 text-sky-200' : 'text-zinc-400 hover:bg-zinc-800'"
                @click="tab = 'doc'">Doc</button>
        <button class="px-2 py-1 border-l border-zinc-700" :class="tab === 'sources' ? 'bg-sky-900/50 text-sky-200' : 'text-zinc-400 hover:bg-zinc-800'"
                @click="tab = 'sources'">Sources pulled</button>
      </div>

      <!-- doc-theme (THEME, audit §V): the same render-time skin ArtifactPanel
           uses, replacing this ad hoc prose-* utility soup with one shared class. -->
      <article v-if="tab === 'doc'" class="doc-theme prose prose-invert max-w-none" v-html="renderedBody" @click="onLink"></article>
      <SourcesPulledPanel v-else :doc-ref="study.slug" @open="(ref) => router.push(`/studies/${encodeURIComponent(ref)}`)" />

      <!-- Citations -->
      <section
        v-if="study.citations.length"
        class="rounded-md border border-zinc-800 bg-zinc-900/50 overflow-hidden"
      >
        <div class="px-4 py-3 border-b border-zinc-800">
          <h3 class="text-sm font-semibold">Citations ({{ study.citations.length }})</h3>
        </div>
        <ul class="divide-y divide-zinc-800/50">
          <li
            v-for="(c, i) in study.citations"
            :key="i"
            class="px-4 py-2 text-sm flex items-baseline gap-3"
          >
            <span class="font-mono text-zinc-300">{{ c.ref }}</span>
            <span v-if="c.count" class="text-xs text-zinc-500 ml-auto">
              cited {{ c.count }}×
            </span>
          </li>
        </ul>
      </section>

      <!-- Similar -->
      <section
        v-if="study.similar.length"
        class="rounded-md border border-zinc-800 bg-zinc-900/50 overflow-hidden"
      >
        <div class="px-4 py-3 border-b border-zinc-800">
          <h3 class="text-sm font-semibold">Similar studies</h3>
        </div>
        <ul class="divide-y divide-zinc-800/50">
          <li v-for="h in study.similar" :key="h.slug" class="px-4 py-2 text-sm">
            <RouterLink
              :to="`/studies/${encodeURIComponent(h.slug)}`"
              class="flex items-baseline gap-3"
            >
              <span class="text-zinc-200">{{ h.title || h.slug }}</span>
              <span v-if="h.distance" class="ml-auto text-xs text-zinc-500 tabular-nums">
                {{ h.distance.toFixed(3) }}
              </span>
            </RouterLink>
          </li>
        </ul>
      </section>
    </template>
  </div>
</template>
