<script setup lang="ts">
// Roles panel (95, ux ease-of-life 2026-07-03) — Michael, fresh off the setup
// wizard: "could use a few more ux ease of life features. like turning off
// models for the different model kinds (reason, ingest...) I cant disable the
// local models we've enabled through lm studio or flexllama."
//
// Each role (reason/ingest/critic/vision/…) resolves to an ORDERED chain of
// provider+model members (model_aliases); pick_alias_member walks the chain
// lowest-priority-first and now (95) skips any member with enabled=false. This
// panel is the "click, not SQL" surface for that: per-member on/off + arrow
// reorder, LOCAL members (lm_studio/flexllama) visually badged since they're
// the ones Michael actually wants to rest, and a one-click "rest all local
// models" action (+ its inverse) that flips every local member across every
// role at once. Every action here only flips a flag — never deletes a row —
// so nothing needs a confirm dialog.
import { ref, computed, onMounted } from 'vue'
import { api, type AliasRow } from '@/api'


const aliases = ref<AliasRow[]>([])
const loading = ref(true)
const error = ref('')
const busy = ref('')          // `${role}:${provider}:${model}` while a call is in flight
const restBusy = ref(false)

// Known roles surface first, in this order; anything else found in the data
// (a custom alias an operator wired up) trails after, alphabetically.
const knownRoles = ['reason', 'ingest', 'critic', 'vision']

const grouped = computed(() => {
  const m: Record<string, AliasRow[]> = {}
  for (const a of aliases.value) {
    (m[a.alias] ??= []).push(a)
  }
  for (const role of Object.keys(m)) {
    m[role]?.sort((x, y) => x.priority - y.priority || x.provider.localeCompare(y.provider))
  }
  return m
})

const roleOrder = computed(() => {
  const present = Object.keys(grouped.value)
  const known = knownRoles.filter(r => present.includes(r))
  const other = present.filter(r => !knownRoles.includes(r)).sort()
  return [...known, ...other]
})

const localCount = computed(() => aliases.value.filter(a => a.is_local).length)
const localEnabledCount = computed(() => aliases.value.filter(a => a.is_local && a.enabled).length)

async function load() {
  loading.value = true
  error.value = ''
  try {
    const r = await api.modelAliases()
    aliases.value = r.aliases
  } catch (e) {
    error.value = String(e)
  } finally {
    loading.value = false
  }
}

function keyOf(role: string, a: AliasRow): string {
  return `${role}:${a.provider}:${a.model}`
}

async function toggleEnabled(role: string, a: AliasRow) {
  const k = keyOf(role, a)
  busy.value = k
  try {
    await api.aliasEnabled({ alias: role, provider: a.provider, model: a.model, enabled: !a.enabled })
    await load()
  } catch (e) {
    error.value = String(e)
  } finally {
    busy.value = ''
  }
}

// Reorder renumbers the WHOLE role chain to 0..N-1 in the new order (rather
// than swapping raw priority values) so arrows stay reliable even when two
// members happen to share a priority (e.g. the public-default floor of 5).
async function reorder(role: string, fromIdx: number, toIdx: number) {
  const list = grouped.value[role]
  if (!list || toIdx < 0 || toIdx >= list.length) return
  const reordered = [...list]
  const [item] = reordered.splice(fromIdx, 1)
  if (!item) return
  reordered.splice(toIdx, 0, item)
  busy.value = keyOf(role, item)
  try {
    await Promise.all(reordered.map((r, i) =>
      api.aliasPriority({ alias: role, provider: r.provider, model: r.model, priority: i })
    ))
    await load()
  } catch (e) {
    error.value = String(e)
  } finally {
    busy.value = ''
  }
}
function moveUp(role: string, idx: number) { reorder(role, idx, idx - 1) }
function moveDown(role: string, idx: number) { reorder(role, idx, idx + 1) }

// The one-click local switch + its inverse — Michael's pain point, named.
async function restLocal(enabled: boolean) {
  restBusy.value = true
  error.value = ''
  try {
    await api.aliasRestLocal(enabled)
    await load()
  } catch (e) {
    error.value = String(e)
  } finally {
    restBusy.value = false
  }
}

onMounted(load)
</script>

<template>
  <section class="roles-panel">
    <header class="roles-header">
      <h2>Roles</h2>
      <p class="roles-sub">
        Each role resolves to its members in priority order (top = tried first). Disabling a
        member skips it everywhere that role dispatches — no restart, no SQL.
      </p>
    </header>

    <div class="local-bar" v-if="localCount">
      <span class="local-summary">
        <span class="dot" :class="localEnabledCount ? 'on' : 'off'"></span>
        {{ localEnabledCount }} / {{ localCount }} local member{{ localCount === 1 ? '' : 's' }} enabled
        (<code>lm_studio</code> / <code>flexllama</code>)
      </span>
      <button class="btn" :disabled="restBusy" @click="restLocal(false)">
        {{ restBusy ? 'working…' : 'Rest all local models' }}
      </button>
      <button class="btn" :disabled="restBusy" @click="restLocal(true)">
        {{ restBusy ? 'working…' : 'Wake all local models' }}
      </button>
    </div>

    <div v-if="error" class="roles-error">{{ error }}</div>
    <div v-if="loading" class="roles-status">Loading…</div>
    <div v-else-if="!roleOrder.length" class="roles-status">
      No role aliases registered yet — assign one above in the setup wizard.
    </div>

    <div v-else class="role-list">
      <div v-for="role in roleOrder" :key="role" class="role-block">
        <h3 class="role-title">{{ role }}</h3>
        <ul class="member-list">
          <li v-for="(m, idx) in grouped[role]" :key="m.provider + ':' + m.model"
              class="member-row" :class="{ disabled: !m.enabled }">
            <span class="badge" :class="m.is_local ? 'badge-local' : 'badge-cloud'">
              {{ m.is_local ? 'LOCAL' : 'cloud' }}
            </span>
            <span class="provider mono">{{ m.provider }}</span>
            <span class="model mono">{{ m.model }}</span>
            <span class="priority" title="try order — lower = tried first">p{{ m.priority }}</span>
            <span class="reorder">
              <button class="btn arrow" title="move earlier in the chain"
                      :disabled="idx === 0 || busy === keyOf(role, m)"
                      @click="moveUp(role, idx)">▲</button>
              <button class="btn arrow" title="move later in the chain"
                      :disabled="idx === (grouped[role]?.length ?? 0) - 1 || busy === keyOf(role, m)"
                      @click="moveDown(role, idx)">▼</button>
            </span>
            <button class="btn toggle" :class="m.enabled ? 'on' : 'off'"
                    :disabled="busy === keyOf(role, m)"
                    :title="m.enabled ? 'enabled — click to disable' : 'disabled — click to enable'"
                    @click="toggleEnabled(role, m)">
              {{ m.enabled ? 'ON' : 'OFF' }}
            </button>
          </li>
        </ul>
      </div>
    </div>
  </section>
</template>

<style scoped>
.roles-panel {
  border: 1px solid var(--border, #444);
  border-radius: 6px;
  padding: 1rem 1.25rem 1.25rem;
  margin-bottom: 2rem;
  background: var(--surface-alt, #161616);
}
.roles-header h2 { margin: 0 0 0.25rem; font-size: 1.1rem; }
.roles-sub { color: var(--text-muted, #888); margin: 0 0 0.9rem; font-size: 0.9rem; }

.local-bar {
  display: flex;
  flex-wrap: wrap;
  align-items: center;
  gap: 0.6rem;
  padding: 0.6rem 0.8rem;
  margin-bottom: 1rem;
  border: 1px solid var(--border-subtle, #2a2a2a);
  border-radius: 4px;
  background: var(--surface, #1a1a1a);
}
.local-summary { font-size: 0.85rem; color: var(--text-muted, #888); display: flex; align-items: center; gap: 0.4rem; }
.local-summary code { background: transparent; }
.dot { width: 0.5rem; height: 0.5rem; border-radius: 50%; display: inline-block; }
.dot.on { background: #2ecc71; }
.dot.off { background: #c0392b; }

.roles-error {
  padding: 0.5rem 0.8rem;
  background: rgba(192, 57, 43, 0.15);
  border: 1px solid #c0392b;
  border-radius: 4px;
  color: #ff6b5b;
  font-size: 0.9rem;
  margin: 0.6rem 0;
}
.roles-status { color: var(--text-muted, #888); padding: 0.5rem 0; font-size: 0.9rem; }

.role-list { display: flex; flex-direction: column; gap: 1rem; }
.role-block { }
.role-title {
  margin: 0 0 0.4rem;
  font-size: 0.95rem;
  font-weight: 600;
  text-transform: none;
}
.member-list { list-style: none; margin: 0; padding: 0; display: flex; flex-direction: column; gap: 0.35rem; }

.member-row {
  display: flex;
  align-items: center;
  gap: 0.6rem;
  padding: 0.4rem 0.6rem;
  border: 1px solid var(--border-subtle, #2a2a2a);
  border-radius: 4px;
  font-size: 0.88rem;
  flex-wrap: wrap;
}
.member-row.disabled { opacity: 0.55; }

.badge {
  font-size: 0.68rem;
  font-weight: 600;
  letter-spacing: 0.03em;
  padding: 0.1rem 0.4rem;
  border-radius: 3px;
  text-transform: uppercase;
}
.badge-local { color: #2ecc71; border: 1px solid #1e8449; background: rgba(46, 204, 113, 0.12); }
.badge-cloud { color: var(--text-muted, #888); border: 1px solid var(--border-subtle, #2a2a2a); background: transparent; }

.mono { font-family: var(--font-mono, monospace); }
.provider { color: var(--text-muted, #888); }
.model { flex: 1; min-width: 8rem; }
.priority { color: var(--text-muted, #888); font-size: 0.78rem; }

.reorder { display: flex; gap: 0.2rem; }
.btn {
  padding: 0.3rem 0.6rem;
  border: 1px solid var(--border, #444);
  border-radius: 4px;
  background: var(--surface, #1a1a1a);
  color: inherit;
  cursor: pointer;
  font-size: 0.82rem;
}
.btn:hover { background: var(--surface-hover, #2a2a2a); }
.btn:disabled { opacity: 0.4; cursor: default; }
.btn.arrow { padding: 0.2rem 0.45rem; line-height: 1; }
.btn.toggle { font-weight: 600; min-width: 3rem; }
.btn.toggle.on { border-color: #27ae60; color: #2ecc71; }
.btn.toggle.off { border-color: #7f2a20; color: #e07a6e; }

/* phone-usable (mobile-usability convention, 2026-07-03): interactive controls
   bump to >=44px touch targets under 768px, reverting to the compact desktop
   size above it — same threshold App.vue's nav collapse uses. */
@media (max-width: 768px) {
  .btn { min-height: 44px; padding: 0.4rem 0.8rem; }
  .btn.arrow { min-width: 44px; }
  .btn.toggle { min-width: 44px; }
  .member-row { gap: 0.5rem; }
}
@media (min-width: 769px) {
  .btn.arrow { min-height: 0; }
}
</style>
