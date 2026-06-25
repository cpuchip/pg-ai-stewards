<script setup lang="ts">
// Stewdio left panel — project-filtered browser of work items + their docs (the
// "manager surface") + a launcher to kick off a new pipeline. Clicking an item
// (or launching one) sets the shared selection, which drives the center artifact
// / plan-progress view and the chat panel. (Stewdio P1 + P2 launcher)
import { ref, computed, onMounted, watch } from 'vue'
import { api, type StudyBrief, type WorkItemRow } from '@/api'
import { useStewdioStore } from '../../stores/stewdio'

defineOptions({ inheritAttrs: false })
const store = useStewdioStore()

const projects = ref<{ slug: string; name?: string }[]>([])
const pipelines = ref<{ family: string; description: string }[]>([])
const docs = ref<StudyBrief[]>([])
const items = ref<WorkItemRow[]>([])
const err = ref('')
const loading = ref(false)

// launcher
const showLaunch = ref(false)
const launchPipeline = ref('')
const launchInput = ref('')
const launching = ref(false)
const launchErr = ref('')

// S5 — intent-named launcher. The 53 raw pipeline families are internal vocabulary;
// the everyday launcher surfaces the FIVE things the engine is FOR, mapped to the
// user-facing pipelines that actually exist on this install (filtered against the
// live list). "＋ more pipelines…" still exposes the full raw list for power users
// and any family not mapped to a verb.
// Only the verbs whose pipelines actually run from a binding-question/topic (this
// launcher's single input). Digest (book/video) is shelf/source-driven and Build
// (code) needs a repo + acceptance criteria — both need their own input form, so
// they're NOT surfaced here yet (reachable via the Dev-gated "more pipelines…"; a
// proper adaptive form is the follow-up). Each verb's `also` is trimmed to families
// that are likewise topic-safe.
type Verb = { key: string; icon: string; blurb: string; primary: string; also: string[] }
const VERBS: Verb[] = [
  { key: 'Research', icon: '🔍', blurb: 'Gather and synthesize across many sources', primary: 'research-write', also: ['research-summary'] },
  { key: 'Generate', icon: '📄', blurb: 'Build a document or report you can download', primary: 'doc-build', also: ['study-write'] },
  { key: 'Reflect', icon: '🪞', blurb: 'Survey a question and propose new work', primary: 'planning', also: [] },
]
const selectedVerb = ref('')
const showMore = ref(false)
// each verb's available pipelines = its [primary, ...also] that actually exist here.
const availableVerbs = computed(() =>
  VERBS.map(v => ({ ...v, fams: [v.primary, ...v.also].filter(f => pipelines.value.some(p => p.family === f)) }))
    .filter(v => v.fams.length))
const pickedFamilies = computed(() => {
  const v = availableVerbs.value.find(x => x.key === selectedVerb.value)
  return v ? v.fams.map(f => pipelines.value.find(p => p.family === f)).filter((p): p is { family: string; description: string } => !!p) : []
})
const pickedBlurb = computed(() => availableVerbs.value.find(x => x.key === selectedVerb.value)?.blurb || '')
function pickVerb(key: string, fams: string[]) { selectedVerb.value = key; launchPipeline.value = fams[0] || '' }
// open/close the launcher; reset its state on open so each session starts clean.
function toggleLaunch() {
  showLaunch.value = !showLaunch.value
  if (showLaunch.value) { selectedVerb.value = ''; showMore.value = false; launchPipeline.value = ''; launchErr.value = '' }
}

async function loadProjects() {
  try { projects.value = (await api.projectsList()).items ?? [] } catch { /* optional */ }
}
async function loadPipelines() {
  try { pipelines.value = (await api.pipelinesList()).items ?? [] } catch { /* optional */ }
}
async function loadItems() {
  loading.value = true; err.value = ''
  try {
    const proj = store.projectFilter || undefined
    const [d, w] = await Promise.allSettled([
      api.studiesList({ limit: 200 }),
      api.workItemsList({ project_association: proj, limit: 100 }),
    ])
    docs.value = d.status === 'fulfilled' ? (d.value.items ?? []) : []
    items.value = w.status === 'fulfilled' ? (w.value.items ?? []) : []
  } catch (e) { err.value = String(e) } finally { loading.value = false }
}

async function launch() {
  if (!launchPipeline.value) { launchErr.value = 'pick a pipeline'; return }
  launching.value = true; launchErr.value = ''
  try {
    const text = launchInput.value.trim()
    const r = await api.workItemCreate({
      pipeline: launchPipeline.value,
      slug: `${launchPipeline.value}-${Date.now().toString(36)}`,
      input: text ? { binding_question: text, assignment: text } : {},
      user_input: text || undefined,
      dispatch: true,
    })
    store.select(r.id, 'work_item', text || launchPipeline.value)
    showLaunch.value = false; launchInput.value = ''
    selectedVerb.value = ''; showMore.value = false; launchPipeline.value = '' // clean for next time
    loadItems()
  } catch (e) { launchErr.value = String(e) } finally { launching.value = false }
}

const stateClass = (s: string) =>
  s === 'completed' ? 'text-emerald-400'
  : s === 'failed' || s === 'cancelled' ? 'text-rose-400'
  : s === 'in_progress' ? 'text-amber-400' : 'text-zinc-400'

onMounted(() => { loadProjects(); loadPipelines(); loadItems() })
watch(() => store.projectFilter, loadItems)
</script>

<template>
  <div class="h-full overflow-auto bg-zinc-950 text-sm">
    <div class="sticky top-0 z-10 bg-zinc-950 border-b border-zinc-800 px-3 py-2 flex items-center gap-2">
      <span class="text-zinc-400 text-xs">Project</span>
      <select v-model="store.projectFilter"
              class="flex-1 bg-zinc-900 border border-zinc-800 rounded px-2 py-1 text-xs text-zinc-200">
        <option :value="null">all</option>
        <option v-for="p in projects" :key="p.slug" :value="p.slug">{{ p.name || p.slug }}</option>
      </select>
      <button class="text-xs px-2 py-1 rounded bg-sky-600/30 border border-sky-700/50 text-sky-300 hover:bg-sky-600/50"
              @click="toggleLaunch" title="kick off a task">＋ New task</button>
    </div>

    <div v-if="showLaunch" class="px-3 py-2 border-b border-zinc-800 bg-zinc-900/50 space-y-2">
      <div class="text-zinc-400 text-[11px] uppercase tracking-wide">What do you want to do?</div>
      <!-- the five things the engine is for -->
      <div class="grid grid-cols-2 gap-1.5">
        <button v-for="v in availableVerbs" :key="v.key"
                class="text-left px-2 py-1.5 rounded border text-xs transition"
                :class="selectedVerb === v.key ? 'border-emerald-700/60 bg-emerald-900/20 text-emerald-200' : 'border-zinc-800 bg-zinc-900 text-zinc-300 hover:border-zinc-700'"
                :title="v.blurb" @click="pickVerb(v.key, v.fams)">
          <span class="mr-1">{{ v.icon }}</span>{{ v.key }}
        </button>
      </div>
      <div v-if="!availableVerbs.length" class="text-zinc-600 text-xs">no pipelines available on this install</div>
      <!-- picked verb: its blurb + (when more than one) which exact pipeline -->
      <div v-if="selectedVerb" class="space-y-1.5">
        <div class="text-zinc-500 text-[11px]">{{ pickedBlurb }}</div>
        <select v-if="pickedFamilies.length > 1" v-model="launchPipeline"
                class="w-full bg-zinc-900 border border-zinc-800 rounded px-2 py-1 text-xs text-zinc-200">
          <option v-for="p in pickedFamilies" :key="p.family" :value="p.family">{{ p.description || p.family }}</option>
        </select>
      </div>
      <!-- escape hatch: the full raw family list — a Developer surface (the raw slugs
           are the same jargon the everyday surface ducks; power users flip ⚙ Dev) -->
      <button v-if="store.dev" class="text-[11px] text-zinc-600 hover:text-zinc-300" @click="showMore = !showMore">
        {{ showMore ? '− fewer' : '＋ more pipelines…' }}
      </button>
      <select v-if="store.dev && showMore" v-model="launchPipeline" @change="selectedVerb = ''"
              class="w-full bg-zinc-900 border border-zinc-800 rounded px-2 py-1 text-xs text-zinc-200">
        <option value="">pick a pipeline…</option>
        <option v-for="p in pipelines" :key="p.family" :value="p.family">{{ p.family }}</option>
      </select>
      <textarea v-model="launchInput" rows="2" placeholder="binding question / topic (optional)"
                class="w-full bg-zinc-900 border border-zinc-800 rounded px-2 py-1 text-xs text-zinc-200 resize-none"></textarea>
      <div class="flex items-center gap-2">
        <button :disabled="launching || !launchPipeline" class="text-xs px-3 py-1 rounded bg-sky-600 text-white disabled:opacity-50" @click="launch">
          {{ launching ? 'launching…' : 'Launch' }}
        </button>
        <span v-if="launchPipeline" class="text-zinc-600 text-[10px] truncate">{{ launchPipeline }}</span>
        <span v-if="launchErr" class="text-rose-400 text-[11px]">{{ launchErr }}</span>
      </div>
    </div>

    <div v-if="err" class="px-3 py-2 text-rose-400 text-xs">{{ err }}</div>

    <div class="px-3 py-2">
      <div class="text-zinc-500 text-[11px] uppercase tracking-wide mb-1">Docs</div>
      <ul class="space-y-0.5">
        <li v-for="d in docs" :key="d.slug">
          <button
            class="w-full text-left px-2 py-1 rounded hover:bg-zinc-900 truncate"
            :class="store.selectedRef === d.slug ? 'bg-zinc-800 text-zinc-100' : 'text-zinc-300'"
            :title="d.title || d.slug"
            @click="store.select(d.slug, 'doc', d.title || d.slug)">
            <span class="text-zinc-600 text-[10px] mr-1">{{ d.kind }}</span>{{ d.title || d.slug }}
          </button>
        </li>
        <li v-if="!docs.length && !loading" class="text-zinc-600 text-xs px-2 py-1">no docs</li>
      </ul>
    </div>

    <div class="px-3 py-2 border-t border-zinc-900">
      <div class="text-zinc-500 text-[11px] uppercase tracking-wide mb-1">Work items</div>
      <ul class="space-y-0.5">
        <li v-for="w in items" :key="w.id">
          <button
            class="w-full text-left px-2 py-1 rounded hover:bg-zinc-900 truncate"
            :class="store.selectedRef === w.id ? 'bg-zinc-800 text-zinc-100' : 'text-zinc-300'"
            :title="w.slug || w.id"
            @click="store.select(w.id, 'work_item', w.slug || w.id)">
            <span class="text-[10px] mr-1" :class="stateClass(w.status)">●</span>{{ w.slug || w.id.slice(0, 8) }}
            <span class="text-zinc-600 text-[10px]">{{ w.pipeline }}</span>
          </button>
        </li>
        <li v-if="!items.length && !loading" class="text-zinc-600 text-xs px-2 py-1">no work items</li>
      </ul>
    </div>
  </div>
</template>
