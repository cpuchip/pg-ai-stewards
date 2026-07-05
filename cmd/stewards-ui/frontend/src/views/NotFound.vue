<script setup lang="ts">
// Router catch-all (/:pathMatch(.*)*). Before this, an unknown URL rendered a
// silent blank <RouterView /> — nothing told the user where they were. Same
// card/zinc idiom as Placeholder / the rest of the shell.
import { useRoute, RouterLink } from 'vue-router'
const route = useRoute()
</script>

<template>
  <div class="max-w-lg space-y-4">
    <div class="text-6xl font-semibold tracking-tight text-zinc-700 tabular-nums">404</div>
    <h2 class="text-2xl font-semibold tracking-tight">Page not found</h2>
    <div class="rounded-md border border-zinc-800 bg-zinc-900/50 p-6 space-y-3">
      <p class="text-sm text-zinc-300">
        There's no view at this address. It may have moved, or the link was mistyped.
      </p>
      <p class="text-xs text-zinc-500 font-mono break-all">route: {{ route.fullPath }}</p>
      <div class="flex flex-wrap gap-3 pt-1">
        <RouterLink
          to="/"
          class="inline-flex items-center rounded border border-zinc-700 px-3 py-1.5 text-sm text-zinc-200 hover:border-sky-700/60 hover:text-sky-200"
        >← Back to Dashboard</RouterLink>
        <RouterLink
          to="/stewdio"
          class="inline-flex items-center rounded border border-zinc-800 px-3 py-1.5 text-sm text-zinc-400 hover:text-sky-300"
        >Open Stewdio</RouterLink>
      </div>
    </div>
  </div>
</template>
