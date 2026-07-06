<script setup lang="ts">
import { computed, onMounted, onUnmounted, ref, watch } from 'vue'
import { RouterLink, RouterView, useRoute, useRouter } from 'vue-router'
import { requestSearchFocus } from '@/searchShortcut'

// Stewdio is a full-bleed VS-Code-like cockpit: it needs the whole viewport
// below the header (no main padding, no footer) so dockview can fill the space.
const route = useRoute()
const router = useRouter()
const fullBleed = computed(() => route.name === 'stewdio')

// Global "/" -> Search (93: "give the human the models' search"). Skips when
// the user is already typing somewhere (input/textarea/contenteditable) so
// it never steals a literal "/" from a chat box or search field elsewhere.
function onGlobalKeydown(e: KeyboardEvent) {
  if (e.key !== '/' || e.metaKey || e.ctrlKey || e.altKey) return
  const el = e.target as HTMLElement | null
  const tag = el?.tagName
  if (tag === 'INPUT' || tag === 'TEXTAREA' || el?.isContentEditable) return
  e.preventDefault()
  if (route.name !== 'search') router.push('/search')
  requestSearchFocus()
}
onMounted(() => window.addEventListener('keydown', onGlobalKeydown))
onUnmounted(() => window.removeEventListener('keydown', onGlobalKeydown))

// Close any open nav dropdown (mobile sheet or desktop "More") on navigation.
watch(() => route.fullPath, () => { navOpen.value = false; moreOpen.value = false })

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

// Tablet/small-desktop nav overflow (2026-07-05). The full ~21-tab inline row
// is ~1335px wide, so from md (768) up to a wide desktop it overran the header —
// "Trust" clipped, Councils/Projects/Models fell off, and the page grew a
// horizontal scrollbar at 1280. The mobile hamburger only covers <768. So in
// the md–wide band we now show a small load-bearing PRIMARY row inline and fold
// the rest into a "More ▾" dropdown (the same toggle+absolute-panel idiom as the
// mobile sheet and AttentionBell). Only on a genuinely wide viewport (≥1600,
// where the full row fits with headroom) does the whole set return inline.
const moreOpen = ref(false)
const PRIMARY_LINKS = [
  { to: '/', label: 'Dashboard' },
  { to: '/stewdio', label: 'Stewdio', accent: true },
  { to: '/search', label: 'Search' },
  { to: '/studies', label: 'Studies' },
  { to: '/work-items', label: 'Work items' },
  { to: '/models', label: 'Models' },
]
const SECONDARY_LINKS = [
  { to: '/sessions', label: 'Sessions' },
  { to: '/watchman', label: 'Watchman' },
  { to: '/scheduled', label: 'Scheduled' },
  { to: '/bridge', label: 'Bridge' },
  { to: '/graph', label: 'Graphs' },
  { to: '/wiki', label: 'Wiki' },
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
// Mobile hamburger sheet keeps its own curated order (Stewdio first — a phone
// user is there to answer/chat, not operate the full cockpit).
const NAV_LINKS = [
  { to: '/stewdio', label: 'Stewdio' },
  { to: '/search', label: 'Search' },
  { to: '/work-items', label: 'Work items' },
  { to: '/studies', label: 'Studies' },
  { to: '/models', label: 'Models' },
  { to: '/', label: 'Dashboard' },
  { to: '/wiki', label: 'Wiki' },
  { to: '/sessions', label: 'Sessions' },
  { to: '/watchman', label: 'Watchman' },
  { to: '/scheduled', label: 'Scheduled' },
  { to: '/bridge', label: 'Bridge' },
  { to: '/graph', label: 'Graphs' },
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

      <!-- desktop/tablet: load-bearing primary row + a "More ▾" overflow. The
           secondary links show inline only when the viewport is wide enough for
           the whole set (≥1600); below that they live in the dropdown so the
           header never overflows. -->
      <nav class="hidden md:flex items-center gap-4 text-sm text-zinc-400">
        <RouterLink
          v-for="l in PRIMARY_LINKS" :key="l.to" :to="l.to"
          class="hover:text-zinc-100 whitespace-nowrap" :class="l.accent ? 'text-sky-400' : ''"
        >{{ l.label }}</RouterLink>

        <!-- secondary: inline on a genuinely wide viewport… -->
        <RouterLink
          v-for="l in SECONDARY_LINKS" :key="`inline-${l.to}`" :to="l.to"
          class="hidden min-[1600px]:inline hover:text-zinc-100 whitespace-nowrap"
        >{{ l.label }}</RouterLink>

        <!-- …otherwise folded behind More -->
        <div class="relative min-[1600px]:hidden">
          <button
            class="hover:text-zinc-100 whitespace-nowrap"
            :aria-expanded="moreOpen" aria-label="more navigation"
            @click="moreOpen = !moreOpen"
          >More ▾</button>
          <nav
            v-if="moreOpen"
            class="absolute right-0 top-full mt-2 w-48 max-h-[70vh] overflow-y-auto rounded border border-zinc-800 bg-zinc-900 shadow-xl z-50 py-1"
          >
            <RouterLink
              v-for="l in SECONDARY_LINKS" :key="`more-${l.to}`" :to="l.to" @click="moreOpen = false"
              class="block px-3 py-1.5 text-sm text-zinc-300 hover:bg-zinc-800 hover:text-zinc-100"
            >{{ l.label }}</RouterLink>
          </nav>
        </div>
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
