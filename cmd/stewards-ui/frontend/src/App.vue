<script setup lang="ts">
import { computed } from 'vue'
import { RouterLink, RouterView, useRoute } from 'vue-router'

// Stewdio is a full-bleed VS-Code-like cockpit: it needs the whole viewport
// below the header (no main padding, no footer) so dockview can fill the space.
const route = useRoute()
const fullBleed = computed(() => route.name === 'stewdio')
</script>

<template>
  <div class="h-screen flex flex-col">
    <header class="border-b border-zinc-800 px-6 py-3 flex items-center gap-6 shrink-0">
      <h1 class="text-lg font-semibold tracking-tight">stewards-ui</h1>
      <nav class="flex gap-4 text-sm text-zinc-400">
        <RouterLink to="/" class="hover:text-zinc-100">Dashboard</RouterLink>
        <RouterLink to="/stewdio" class="hover:text-zinc-100 text-sky-400">Stewdio</RouterLink>
        <RouterLink to="/studies" class="hover:text-zinc-100">Studies</RouterLink>
        <RouterLink to="/work-items" class="hover:text-zinc-100">Work items</RouterLink>
        <RouterLink to="/sessions" class="hover:text-zinc-100">Sessions</RouterLink>
        <RouterLink to="/watchman" class="hover:text-zinc-100">Watchman</RouterLink>
        <RouterLink to="/scheduled" class="hover:text-zinc-100">Scheduled</RouterLink>
        <RouterLink to="/bridge" class="hover:text-zinc-100">Bridge</RouterLink>
        <RouterLink to="/graph" class="hover:text-zinc-100">Graph</RouterLink>
        <RouterLink to="/new" class="hover:text-zinc-100">New work</RouterLink>
        <RouterLink to="/brainstorm" class="hover:text-zinc-100">Brainstorm</RouterLink>
        <span class="text-zinc-700">|</span>
        <RouterLink to="/intents" class="hover:text-zinc-100">Intents</RouterLink>
        <RouterLink to="/covenants" class="hover:text-zinc-100">Covenant</RouterLink>
        <RouterLink to="/sabbath" class="hover:text-zinc-100">Sabbath</RouterLink>
        <RouterLink to="/lessons" class="hover:text-zinc-100">Lessons</RouterLink>
        <RouterLink to="/trust" class="hover:text-zinc-100">Trust</RouterLink>
        <RouterLink to="/councils" class="hover:text-zinc-100">Councils</RouterLink>
        <RouterLink to="/projects" class="hover:text-zinc-100">Projects</RouterLink>
        <RouterLink to="/models" class="hover:text-zinc-100">Models</RouterLink>
      </nav>
    </header>

    <main :class="fullBleed ? 'flex-1 min-h-0' : 'flex-1 p-6'">
      <RouterView />
    </main>

    <footer v-if="!fullBleed" class="border-t border-zinc-800 px-6 py-2 text-xs text-zinc-500 shrink-0">
      pg-ai-stewards &middot; v1 phase 1 (foundation scaffold)
    </footer>
  </div>
</template>
