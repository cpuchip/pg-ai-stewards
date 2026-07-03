<script setup lang="ts">
// The unified "Needs your answer" bell (89) — replaces 84's tool-confirm-only
// "Needs you" tray with every human-blocking kind (Hinge reviews, the
// tool-effect gate, a paused pipeline stage, an A2A blocking question) in one
// place. Michael: "we could create a new panel for notifications that need
// to be answered to make it super easy." Cards render a kind chip, the
// question, and ONE-TAP answer buttons when the item has quick-reply options
// (approve/decline/…), or a free-text input when it doesn't. Answering is
// optimistic (the card leaves immediately; a failure restores it) so it feels
// instant on a phone-width viewport — the panel's own width is capped to the
// viewport and every tap target is sized for a thumb, not a cursor.
import { ref, onMounted, onBeforeUnmount } from 'vue'
import { attentionApi, type AttentionItem } from '../../api'

const items = ref<AttentionItem[]>([])
const count = ref(0)
const open = ref(false)
const busy = ref<string | null>(null)          // keyOf(item) currently being answered
const drafts = ref<Record<string, string>>({}) // free-text draft per item, keyed the same way
let timer: number | null = null

function keyOf(it: Pick<AttentionItem, 'source_kind' | 'source_id'>): string {
  return `${it.source_kind}:${it.source_id}`
}

// Human-readable label for the kind chip — the raw source_kind values
// (hinge/gate/review/a2a_question/ask) are internal plumbing names.
function kindLabel(k: string): string {
  return ({
    gate: 'tool call',
    hinge: 'review',
    review: 'continue',
    a2a_question: 'question',
    ask: 'ask',
  } as Record<string, string>)[k] ?? k
}

// A quick-reply button's color follows its meaning, not just its kind —
// approve reads positive, decline/reject reads negative, everything else
// (revise, …) is neutral.
function optionClass(opt: string): string {
  const o = opt.toLowerCase()
  if (o === 'approve' || o === 'approved') return 'border-emerald-700/60 bg-emerald-900/30 text-emerald-200 hover:bg-emerald-900/60'
  if (o === 'decline' || o === 'declined' || o === 'reject') return 'border-rose-700/60 bg-rose-900/30 text-rose-200 hover:bg-rose-900/60'
  return 'border-zinc-700 bg-zinc-800/60 text-zinc-300 hover:bg-zinc-800'
}

async function refresh() {
  try {
    const [list, c] = await Promise.all([attentionApi.list(), attentionApi.count()])
    items.value = list
    count.value = c.count
  } catch { /* transient — keep the last known list/count */ }
}

async function answer(it: AttentionItem, value: string) {
  if (!value) return
  const key = keyOf(it)
  busy.value = key
  const prev = items.value
  // optimistic: the card leaves immediately; restore it on failure.
  items.value = items.value.filter(x => keyOf(x) !== key)
  try {
    await attentionApi.answer(it.source_kind, it.source_id, value)
    count.value = Math.max(0, count.value - 1)
    delete drafts.value[key]
    if (items.value.length === 0) open.value = false
  } catch {
    items.value = prev
  } finally {
    busy.value = null
  }
}

onMounted(() => {
  refresh()
  timer = window.setInterval(refresh, 12000)
})
onBeforeUnmount(() => { if (timer !== null) clearInterval(timer) })
</script>

<template>
  <div class="relative">
    <button
      class="text-[11px] rounded px-1.5 py-0.5 min-h-[44px] md:min-h-0 border flex items-center gap-1"
      :class="count
        ? 'text-amber-200 border-amber-600/60 bg-amber-900/30'
        : 'text-zinc-500 hover:text-zinc-200 bg-zinc-900/70 border-zinc-800'"
      :title="count ? count + ' item(s) need your answer' : 'nothing needs your answer'"
      @click="open = !open">
      <span>🔔 Needs your answer</span>
      <span v-if="count"
            class="inline-flex items-center justify-center min-w-[15px] h-[15px] px-1 rounded-full bg-amber-500 text-zinc-950 text-[9px] font-semibold">{{ count }}</span>
    </button>
    <div v-if="open"
         class="absolute right-0 mt-1 w-80 max-w-[92vw] max-h-[70vh] overflow-y-auto rounded border border-zinc-800 bg-zinc-900 shadow-xl z-50">
      <div class="px-3 py-2 text-[11px] text-zinc-400 border-b border-zinc-800 sticky top-0 bg-zinc-900">
        Needs your answer
      </div>
      <div v-if="!items.length" class="px-3 py-4 text-[11px] text-zinc-500">
        Nothing waiting. Hinge reviews, gated tool calls, paused stages, and blocking questions land here.
      </div>
      <div v-for="it in items" :key="keyOf(it)" class="px-3 py-2.5 border-b border-zinc-800/70 last:border-0">
        <div class="flex items-center gap-2">
          <span class="text-[9px] uppercase tracking-wide text-zinc-500 border border-zinc-700 rounded px-1 shrink-0">{{ kindLabel(it.source_kind) }}</span>
          <span class="text-[12px] font-medium text-amber-200 truncate">{{ it.title }}</span>
        </div>
        <div class="text-[12px] text-zinc-300 mt-1 whitespace-pre-wrap break-words">{{ it.question }}</div>
        <div class="flex flex-wrap items-center gap-2 mt-2">
          <template v-if="it.options && it.options.length">
            <button v-for="opt in it.options" :key="opt"
              class="text-sm rounded px-3 py-2 min-h-[44px] border disabled:opacity-40"
              :class="optionClass(opt)"
              :disabled="busy === keyOf(it)"
              @click="answer(it, opt)">{{ opt }}</button>
          </template>
          <template v-else>
            <input v-model="drafts[keyOf(it)]" type="text" placeholder="your answer…"
              class="flex-1 min-w-[140px] text-sm rounded px-2.5 py-2 min-h-[44px] bg-zinc-800 border border-zinc-700 text-zinc-100"
              :disabled="busy === keyOf(it)"
              @keyup.enter="answer(it, drafts[keyOf(it)] || '')" />
            <button
              class="text-sm rounded px-3 py-2 min-h-[44px] border border-emerald-700/60 bg-emerald-900/30 text-emerald-200 hover:bg-emerald-900/60 disabled:opacity-40"
              :disabled="busy === keyOf(it) || !drafts[keyOf(it)]"
              @click="answer(it, drafts[keyOf(it)] || '')">Send</button>
          </template>
        </div>
        <div v-if="busy === keyOf(it)" class="text-[10px] text-zinc-500 mt-1">…</div>
      </div>
    </div>
  </div>
</template>
