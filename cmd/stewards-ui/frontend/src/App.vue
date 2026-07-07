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
// Since the nav merge (feat/lightening) Search is a tab inside Library, so
// the shortcut navigates to /library/search — not just "focus whatever is
// open" — then asks the mounted Search panel to focus its query box.
function onGlobalKeydown(e: KeyboardEvent) {
  if (e.key !== '/' || e.metaKey || e.ctrlKey || e.altKey) return
  const el = e.target as HTMLElement | null
  const tag = el?.tagName
  if (tag === 'INPUT' || tag === 'TEXTAREA' || el?.isContentEditable) return
  e.preventDefault()
  const onSearchTab = route.name === 'library' && route.params.tab === 'search'
  if (!onSearchTab) router.push('/library/search')
  requestSearchFocus()
}
onMounted(() => window.addEventListener('keydown', onGlobalKeydown))
onUnmounted(() => window.removeEventListener('keydown', onGlobalKeydown))

// Close any open nav dropdown (mobile sheet, desktop "More", or "Dev") on navigation.
watch(() => route.fullPath, () => { navOpen.value = false; moreOpen.value = false; devOpen.value = false })

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

// Nav consolidation (feat/lightening, 2026-07-07 — .spec/lightening/
// ui-merge-map.md): primary nav is exactly 10 destinations. Twelve old
// top-level pages now live as tabs inside Library/Ledger/Steering (their old
// paths redirect, see router.ts). The md-band overflow idiom stays (the
// "More ▾" dropdown from 2026-07-05) but the fold point drops to 1100px
// because the full row is now ~½ the width it used to be: PRIMARY_LINKS are
// always inline on md+, SECONDARY_LINKS come inline at ≥1100 and fold into
// "More ▾" below that.
const moreOpen = ref(false)
const PRIMARY_LINKS = [
  { to: '/', label: 'Dashboard' },
  { to: '/work-items', label: 'Work items' },
  { to: '/stewdio', label: 'Stewdio', accent: true },
  { to: '/library', label: 'Library' },
  { to: '/ledger', label: 'Ledger' },
  { to: '/steering', label: 'Steering' },
]
const SECONDARY_LINKS = [
  { to: '/graph', label: 'Graphs' },
  { to: '/wiki', label: 'Wiki' },
  { to: '/models', label: 'Models' },
  { to: '/new', label: 'New' },
]
// Dev-tools flyout ("Dev ▾") — Sessions (list) duplicates Stewdio's
// SessionsPanel with less context and Brainstorm is a power-user dispatch
// form (fold-into-New still undecided), so neither earns a permanent
// top-level slot. Their routes stay real; this is placement, not deletion.
const devOpen = ref(false)
const DEV_LINKS = [
  { to: '/sessions', label: 'Sessions' },
  { to: '/brainstorm', label: 'Brainstorm' },
]
// Mobile hamburger sheet keeps its own curated order (Stewdio first — a phone
// user is there to answer/chat, not operate the full cockpit). Dev-tools
// links render below these, behind a small "dev tools" divider.
const NAV_LINKS = [
  { to: '/stewdio', label: 'Stewdio' },
  { to: '/work-items', label: 'Work items' },
  { to: '/library', label: 'Library' },
  { to: '/', label: 'Dashboard' },
  { to: '/ledger', label: 'Ledger' },
  { to: '/steering', label: 'Steering' },
  { to: '/graph', label: 'Graphs' },
  { to: '/wiki', label: 'Wiki' },
  { to: '/models', label: 'Models' },
  { to: '/new', label: 'New' },
]
</script>

<template>
  <!-- h-dvh not h-screen: 100vh doesn't shrink for mobile browser chrome/keyboard,
       so a fixed-vh shell can leave content (esp. a chat input) hidden under it. -->
  <div class="h-dvh flex flex-col">
    <header class="border-b border-zinc-800 px-4 md:px-6 py-3 flex items-center gap-4 md:gap-6 shrink-0">
      <h1 class="text-lg font-semibold tracking-tight shrink-0">stewards-ui</h1>

      <!-- desktop/tablet: load-bearing primary row + a "More ▾" overflow. The
           secondary links show inline when the viewport fits the whole row
           (≥1100 since the nav merge); below that they live in the dropdown so
           the header never overflows. "Dev ▾" is the dev-tools flyout —
           Sessions/Brainstorm stay reachable without a permanent nav slot. -->
      <nav class="hidden md:flex items-center gap-4 text-sm text-zinc-400">
        <RouterLink
          v-for="l in PRIMARY_LINKS" :key="l.to" :to="l.to"
          class="py-2 hover:text-zinc-100 whitespace-nowrap" :class="l.accent ? 'text-sky-400' : ''"
        >{{ l.label }}</RouterLink>

        <!-- secondary: inline when the row fits… -->
        <RouterLink
          v-for="l in SECONDARY_LINKS" :key="`inline-${l.to}`" :to="l.to"
          class="hidden min-[1100px]:inline py-2 hover:text-zinc-100 whitespace-nowrap"
        >{{ l.label }}</RouterLink>

        <!-- …otherwise folded behind More -->
        <div class="relative min-[1100px]:hidden">
          <button
            class="py-2 hover:text-zinc-100 whitespace-nowrap"
            :aria-expanded="moreOpen" aria-label="more navigation"
            @click="moreOpen = !moreOpen"
          >More ▾</button>
          <nav
            v-if="moreOpen"
            class="absolute right-0 top-full mt-2 w-48 max-h-[70vh] overflow-y-auto rounded border border-zinc-800 bg-zinc-900 shadow-xl z-50 py-1"
          >
            <RouterLink
              v-for="l in SECONDARY_LINKS" :key="`more-${l.to}`" :to="l.to" @click="moreOpen = false"
              class="block px-3 py-2 text-sm text-zinc-300 hover:bg-zinc-800 hover:text-zinc-100"
            >{{ l.label }}</RouterLink>
          </nav>
        </div>

        <!-- dev-tools flyout (same toggle+absolute-panel idiom as More/AttentionBell) -->
        <div class="relative">
          <button
            class="py-2 text-zinc-500 hover:text-zinc-100 whitespace-nowrap"
            :aria-expanded="devOpen" aria-label="developer tools"
            @click="devOpen = !devOpen"
          >Dev ▾</button>
          <nav
            v-if="devOpen"
            class="absolute right-0 top-full mt-2 w-40 rounded border border-zinc-800 bg-zinc-900 shadow-xl z-50 py-1"
          >
            <RouterLink
              v-for="l in DEV_LINKS" :key="`dev-${l.to}`" :to="l.to" @click="devOpen = false"
              class="block px-3 py-2 text-sm text-zinc-300 hover:bg-zinc-800 hover:text-zinc-100"
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
          <div class="px-3 pt-2 pb-1 text-[10px] uppercase tracking-wide text-zinc-600 border-t border-zinc-800 mt-1">dev tools</div>
          <RouterLink v-for="l in DEV_LINKS" :key="`dev-${l.to}`" :to="l.to" @click="navOpen = false"
            class="flex items-center min-h-[44px] px-3 text-sm text-zinc-400 hover:bg-zinc-800 hover:text-zinc-100">{{ l.label }}</RouterLink>
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
