<script setup lang="ts">
import { computed, ref } from 'vue'
import { RouterLink, RouterView, useRoute } from 'vue-router'

// Stewdio is a full-bleed VS-Code-like cockpit: it needs the whole viewport
// below the header (no main padding, no footer) so dockview can fill the space.
const route = useRoute()
const fullBleed = computed(() => route.name === 'stewdio')

// Mobile nav (mobile-usability P1, 2026-07-03). The full ~19-tab inline row
// has no wrap and no width cap, so on a phone it forced the whole document
// wider than the viewport — the "zoomed out / desktop mode" Michael saw isn't
// a missing viewport meta (index.html already has one), it's this row pushing
// the layout wider than device-width. Below md (768px) it's replaced by a
// hamburger + dropdown sheet — the same idiom as Stewdio's own "▦ panels"
// launcher and the AttentionBell dropdown (toggle button, absolute panel,
// click an item to close) — with the four load-bearing entries pinned first
// (Stewdio, Work items, Studies, Models) since a phone user is there to
// answer/chat, not operate the full cockpit.
const navOpen = ref(false)
const NAV_LINKS = [
  { to: '/stewdio', label: 'Stewdio' },
  { to: '/work-items', label: 'Work items' },
  { to: '/studies', label: 'Studies' },
  { to: '/models', label: 'Models' },
  { to: '/', label: 'Dashboard' },
  { to: '/sessions', label: 'Sessions' },
  { to: '/watchman', label: 'Watchman' },
  { to: '/scheduled', label: 'Scheduled' },
  { to: '/bridge', label: 'Bridge' },
  { to: '/graph', label: 'Graph' },
  { to: '/new', label: 'New work' },
  { to: '/brainstorm', label: 'Brainstorm' },
  { to: '/intents', label: 'Intents' },
  { to: '/covenants', label: 'Covenant' },
  { to: '/sabbath', label: 'Sabbath' },
  { to: '/lessons', label: 'Lessons' },
  { to: '/trust', label: 'Trust' },
  { to: '/councils', label: 'Councils' },
  { to: '/projects', label: 'Projects' },
]
</script>

<template>
  <!-- h-dvh not h-screen: 100vh doesn't shrink for mobile browser chrome/keyboard,
       so a fixed-vh shell can leave content (esp. a chat input) hidden under it. -->
  <div class="h-dvh flex flex-col">
    <header class="border-b border-zinc-800 px-4 md:px-6 py-3 flex items-center gap-4 md:gap-6 shrink-0">
      <h1 class="text-lg font-semibold tracking-tight shrink-0">stewards-ui</h1>

      <!-- desktop/tablet: the full inline nav, unchanged -->
      <nav class="hidden md:flex gap-4 text-sm text-zinc-400">
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

      <!-- mobile: hamburger -> dropdown sheet -->
      <div class="md:hidden relative ml-auto">
        <button
          class="text-zinc-300 hover:text-zinc-100 border border-zinc-800 rounded px-3 min-h-[44px] min-w-[44px] text-base"
          :aria-expanded="navOpen" aria-label="menu"
          @click="navOpen = !navOpen">☰</button>
        <nav v-if="navOpen" class="absolute right-0 top-full mt-2 w-56 max-w-[85vw] max-h-[75vh] overflow-y-auto rounded border border-zinc-800 bg-zinc-900 shadow-xl z-50 py-1">
          <RouterLink v-for="l in NAV_LINKS" :key="l.to" :to="l.to" @click="navOpen = false"
            class="flex items-center min-h-[44px] px-3 text-sm text-zinc-300 hover:bg-zinc-800 hover:text-zinc-100">{{ l.label }}</RouterLink>
        </nav>
      </div>
    </header>

    <main :class="fullBleed ? 'flex-1 min-h-0' : 'flex-1 p-4 md:p-6 overflow-y-auto'">
      <RouterView />
    </main>

    <footer v-if="!fullBleed" class="border-t border-zinc-800 px-6 py-2 text-xs text-zinc-500 shrink-0">
      pg-ai-stewards &middot; v1 phase 1 (foundation scaffold)
    </footer>
  </div>
</template>
