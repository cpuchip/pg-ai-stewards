<script setup lang="ts">
// Stewdio center panel — tabbed artifact / plan viewer (the "editor surface").
// P0: placeholder. P1 renders a finished doc (markdown) for a selected work
// item; P2 renders a running work item's plan=progress (stages lighting up).
defineOptions({ inheritAttrs: false })
</script>

<template>
  <div class="h-full overflow-auto p-4 text-sm bg-zinc-950">
    <div class="text-zinc-200 font-medium mb-1">Artifact</div>
    <div class="text-zinc-500 text-xs leading-relaxed">
      Open a work item to view its built doc, or a running one's live
      plan&nbsp;=&nbsp;progress. <span class="text-zinc-600">Wired in P1/P2.</span>
    </div>
  </div>
</template>
