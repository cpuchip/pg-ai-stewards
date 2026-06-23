<script setup lang="ts">
// Stewdio left panel — the project-filtered work-item / doc browser (the
// "manager surface"). P0: placeholder. P1 wires /api/work-items/list
// (project-filtered) + /api/studies/list into a tree; selecting an item sets
// the store's selectedRef and opens it in the center panel.
defineOptions({ inheritAttrs: false }) // dockview passes panel props (api/containerApi); absorb, don't render
</script>

<template>
  <div class="h-full overflow-auto p-3 text-sm bg-zinc-950">
    <div class="text-zinc-200 font-medium mb-1">Work items</div>
    <div class="text-zinc-500 text-xs leading-relaxed">
      Project-filtered browser of work items + their docs.
      <span class="text-zinc-600">Wired in P1.</span>
    </div>
  </div>
</template>
