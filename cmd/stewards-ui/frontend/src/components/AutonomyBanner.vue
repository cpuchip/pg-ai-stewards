<script setup lang="ts">
// Ratified 2026-07-07 (war-game PAUSED-visibility ask): the substrate's global
// kill switch (stewards.config.autonomy_paused) previously surfaced only as a
// small pill buried in the Dashboard's "Local rig" card. This is a prominent,
// shared banner for the three places autonomy actually matters to a human
// watching the system: the Dashboard, the Scheduled-pipelines page, and the
// Stewdio cockpit. Renders nothing (a zero-height comment node) when
// autonomy is running, so it never disturbs layout in the common case.
import { ref, onMounted, onUnmounted } from 'vue'
import { api } from '@/api'

const paused = ref(false)
let timer: number | undefined

async function check() {
  try {
    paused.value = (await api.autonomy()).paused
  } catch {
    // tolerate — the banner just won't show; it's an informational surface,
    // not something a failed poll should turn into a page-level error.
  }
}

onMounted(() => {
  check()
  timer = window.setInterval(check, 30000)
})
onUnmounted(() => {
  if (timer) window.clearInterval(timer)
})
</script>

<template>
  <div
    v-if="paused"
    class="rounded-md border border-amber-600/60 bg-amber-950/40 px-4 py-2.5 text-sm text-amber-200 flex items-center gap-2"
  >
    <span class="text-base leading-none">⏸</span>
    <span>
      Autonomy paused — schedules and reflect loops are OFF (config
      <code class="font-mono text-amber-300">autonomy_paused</code>)
    </span>
  </div>
</template>
