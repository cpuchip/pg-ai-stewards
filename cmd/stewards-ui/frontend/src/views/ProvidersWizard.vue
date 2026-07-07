<script setup lang="ts">
// Providers & Models setup wizard (88/#256) — add key → test-on-save →
// pick models → assign role aliases → set a budget, all from one panel.
//
// The panel never sees a stored key again after save: the API returns
// is_set booleans and a live-probe verdict, nothing else. The pg badge is
// the honest half — stewards.credential_decrypt_check proves the DISPATCHER
// (not just this cockpit) can use the key.
import { ref, computed, onMounted } from 'vue'
import { api, type CredentialRow, type AliasRow, type ModelRow } from '@/api'

const emit = defineEmits<{ (e: 'changed'): void }>()

const masterKeySet = ref(true)
const masterKeyError = ref('')
const creds = ref<CredentialRow[]>([])
const aliases = ref<AliasRow[]>([])
const catalog = ref<ModelRow[]>([])
const loading = ref(true)
const listError = ref('')

// Presets keep the form to two real decisions: which provider, which key.
// `secret_kind` tells the form how to collect the credential: 'key' = paste a string
// (the default), 'json' = drop a service-account file (Vertex — the whole JSON becomes
// the encrypted secret; the dispatcher mints an OAuth token from it, see gcp_sa).
const presets: Record<string, { base_url: string; kind: string; budget?: number; hint?: string; secret_kind?: 'key' | 'json' }> = {
  opencode_zen:  { base_url: 'https://opencode.ai/zen/v1',        kind: 'openai', budget: 5, hint: 'free models + the Claude family (sonnet!) — budget defaults to $5/day' },
  opencode_go:   { base_url: 'https://opencode.ai/zen/go/v1',     kind: 'openai', hint: 'subscription tier: kimi / qwen / glm / minimax' },
  google_gemini: { base_url: 'https://generativelanguage.googleapis.com/v1beta/openai', kind: 'openai', hint: 'AI Studio key (trains on data — public work only)' },
  google_vertex: { base_url: 'https://aiplatform.googleapis.com/v1/projects/PROJECT/locations/global/endpoints/openapi', kind: 'openai', secret_kind: 'json', hint: 'Google Cloud Vertex AI — drop your service-account JSON key; replace PROJECT in the URL with your GCP project id' },
  loom:          { base_url: 'http://host.docker.internal:7777/v1', kind: 'openai', hint: 'loom agentic harness (serve) — drives Claude Code / Codex as workers; paste the loom token; models: sonnet / opus / codex' },
  nvidia:        { base_url: 'https://integrate.api.nvidia.com/v1', kind: 'openai', hint: 'free preview endpoints (trains on data — public work only)' },
  lm_studio:     { base_url: 'http://host.docker.internal:1234/v1', kind: 'openai', hint: 'fully local, no key needed' },
  anthropic:     { base_url: 'https://api.anthropic.com/v1',      kind: 'anthropic', hint: 'direct Anthropic API' },
  custom:        { base_url: '', kind: 'openai' },
}

const roleAliases = ['reason', 'ingest', 'critic', 'vision']

// --- add-provider form state ---
const preset = ref('opencode_zen')
const provider = ref('opencode_zen')
const baseUrl = ref('https://opencode.ai/zen/v1')
const kind = ref('openai')
const secret = ref('')
const budget = ref<number | null>(5)
const saving = ref(false)
const saveError = ref('')
const saveOk = ref('')

// --- model-pick state (appears after a verified save, or via "models") ---
const pickProvider = ref('')
const pickModels = ref<string[]>([])
const pickError = ref('')
const pickNote = ref('')
const pickBusy = ref(false)

// --- inline probe verdict per model (keyed by model id) ---
type ProbePhase = { phase: 'probing' | 'ok' | 'fail'; detail?: string }
const probeState = ref<Record<string, ProbePhase>>({})

// Manually name a model to probe — for providers whose /models can't be listed
// with a static bearer (Vertex service-account) or that don't enumerate.
const manualModel = ref('')
function addManualModel() {
  const m = manualModel.value.trim()
  if (m && !pickModels.value.includes(m)) pickModels.value = [...pickModels.value, m]
  manualModel.value = ''
}
const priceIn = ref<Record<string, string>>({})   // model -> $/Mtok input
const priceOut = ref<Record<string, string>>({})
const assignBusy = ref('')

function applyPreset() {
  const p = presets[preset.value]
  if (!p) return
  provider.value = preset.value === 'custom' ? '' : preset.value
  baseUrl.value = p.base_url
  kind.value = p.kind
  budget.value = p.budget ?? null
  secretKind.value = p.secret_kind ?? 'key'
  secret.value = ''
  jsonFileName.value = ''
}

// How the current preset collects its credential: 'key' (paste) or 'json' (file drop).
const secretKind = ref<'key' | 'json'>('key')
const jsonFileName = ref('')

// Vertex service-account file → the credential secret. Read the file client-side and
// put its JSON text into `secret`; it's saved through the same AES-256-GCM path as a
// pasted key (never echoed back). Validated as parseable JSON with the SA-shape fields.
async function onJsonFile(e: Event) {
  saveError.value = ''
  const f = (e.target as HTMLInputElement).files?.[0]
  if (!f) return
  const text = await f.text()
  let j: any
  try {
    j = JSON.parse(text)
  } catch {
    saveError.value = 'could not parse that file as JSON — drop the service-account key file'
    return
  }
  if (!j.client_email || !j.private_key) {
    saveError.value = 'that JSON is missing client_email / private_key — is it a service-account key?'
    return
  }
  // Auto-fill the GCP project into the endpoint from the SA's project_id so the
  // operator never has to hand-replace PROJECT (leaving it in is the #1 Vertex
  // setup trap — a placeholder base_url that silently shadows a working one).
  if (j.project_id && baseUrl.value.includes('PROJECT')) {
    baseUrl.value = baseUrl.value.replace(/PROJECT/g, j.project_id)
  }
  secret.value = text
  jsonFileName.value = f.name
}

const rolesFor = computed(() => {
  const m: Record<string, AliasRow[]> = {}
  for (const a of aliases.value) {
    if (!roleAliases.includes(a.alias)) continue
    ;(m[a.alias] ??= []).push(a)
  }
  return m
})

const presetHint = computed(() => presets[preset.value]?.hint ?? '')

// 95: the strip's summary must name what pick_alias_member actually resolves
// to — the first ENABLED member, not merely index 0 (a disabled priority-0
// member, e.g. rested via the Roles panel below, must not still be shown as
// "the" model for that role).
function preferredMember(role: string): AliasRow | undefined {
  const list = rolesFor.value[role]
  if (!list?.length) return undefined
  return list.find(m => m.enabled !== false) ?? list[0]
}

function modelHasRole(role: string, prov: string, model: string): boolean {
  return aliases.value.some(a => a.alias === role && a.provider === prov && a.model === model)
}

function modelPriced(prov: string, model: string): boolean {
  return catalog.value.some(m => m.provider === prov && m.model === model)
}

async function load() {
  loading.value = true
  listError.value = ''
  try {
    const [c, a, m] = await Promise.all([api.credentials(), api.modelAliases(), api.modelsList()])
    masterKeySet.value = c.master_key_set
    masterKeyError.value = c.master_key_error ?? ''
    creds.value = c.items
    aliases.value = a.aliases
    catalog.value = m.items
  } catch (e) {
    listError.value = String(e)
  } finally {
    loading.value = false
  }
}

async function save() {
  saveError.value = ''
  saveOk.value = ''
  const prov = provider.value.trim().toLowerCase()
  if (!/^[a-z0-9_]+$/.test(prov)) {
    saveError.value = 'provider id must be lowercase letters/digits/underscores (it becomes the substrate provider id)'
    return
  }
  // Guard the Vertex placeholder: a base_url still containing PROJECT would be
  // stored as-is and shadow any working URL. (Dropping the SA key auto-fills it.)
  if (baseUrl.value.includes('PROJECT')) {
    saveError.value = 'the endpoint still contains “PROJECT” — replace it with your GCP project id (dropping the service-account key fills it in automatically)'
    return
  }
  saving.value = true
  try {
    const resp = await api.credentialSave({
      provider: prov,
      secret: secret.value || undefined,
      base_url: baseUrl.value || undefined,
      kind: kind.value,
      budget_usd_per_day: budget.value ?? undefined,
    })
    if (resp.verified) {
      saveOk.value = `key verified — ${resp.models?.length ?? 0} models listed` +
        (resp.pg_decrypt && resp.pg_decrypt !== 'ok' ? ` · ⚠ pg side: ${resp.pg_decrypt}` : '') +
        (resp.provider_live ? ' · provider live' : '')
      pickProvider.value = prov
      pickModels.value = resp.models ?? []
      prefillKnownPrices(prov, pickModels.value)
      secret.value = ''
    } else if (resp.sa_key) {
      // A Google service-account key: stored & encrypted, but a bearer GET
      // /models can't verify it (only the dispatcher mints the token). Show it
      // as stored + dispatcher-usable, and point at probe / test-chat.
      saveOk.value = 'service-account stored & encrypted' +
        (resp.pg_decrypt === 'ok' ? ' · dispatcher can decrypt ✓' : (resp.pg_decrypt ? ` · ⚠ pg: ${resp.pg_decrypt}` : '')) +
        (resp.provider_live ? ' · provider live' : '') +
        ' — enter a model below and hit “probe”, or use Test chat, to confirm it answers'
      pickProvider.value = prov
      pickModels.value = resp.models ?? []
      secret.value = ''
    } else {
      saveError.value = resp.verify_error || 'verification failed'
      if (resp.stored) saveError.value += ' (the key WAS stored — fix and re-save, or delete it below)'
    }
    await load()
    emit('changed')
  } catch (e) {
    saveError.value = String(e)
  } finally {
    saving.value = false
  }
}

// Pre-fill prices we know (the examples/models.sql snapshot) so sonnet-on-zen
// is priced — an unpriced model spends $0 on paper and slips every budget.
function prefillKnownPrices(prov: string, models: string[]) {
  if (prov !== 'opencode_zen') return
  const known: Record<string, [number, number]> = {
    'claude-haiku-4-5': [1, 5],
    'claude-sonnet-4-6': [3, 15],
    'claude-opus-4-8': [5, 25],
  }
  for (const m of models) {
    const k = known[m]
    if (k && !modelPriced(prov, m)) {
      priceIn.value[m] = String(k[0])
      priceOut.value[m] = String(k[1])
    }
  }
}

async function openModels(prov: string) {
  pickProvider.value = prov
  pickModels.value = []
  pickError.value = ''
  pickNote.value = ''
  pickBusy.value = true
  try {
    const r = await api.credentialModels(prov)
    pickModels.value = r.models
    pickNote.value = r.note ?? ''
    prefillKnownPrices(prov, r.models)
  } catch (e) {
    pickError.value = String(e)
  } finally {
    pickBusy.value = false
  }
}

async function toggleRole(role: string, prov: string, model: string) {
  assignBusy.value = `${role}:${model}`
  try {
    if (modelHasRole(role, prov, model)) {
      await api.aliasDelete({ alias: role, provider: prov, model })
    } else {
      // register capability (+ optional pricing) so dispatch + budget both see it
      const pin = parseFloat(priceIn.value[model] ?? '')
      const pout = parseFloat(priceOut.value[model] ?? '')
      await api.modelRegister({
        provider: prov, model,
        api_format: kindOf(prov),
        ...(isFinite(pin) && isFinite(pout)
          ? { input_micro_per_mtok: Math.round(pin * 1_000_000), output_micro_per_mtok: Math.round(pout * 1_000_000) }
          : {}),
      })
      await api.aliasSet({ alias: role, provider: prov, model, priority: 0 })
    }
    const [a, m] = await Promise.all([api.modelAliases(), api.modelsList()])
    aliases.value = a.aliases
    catalog.value = m.items
    emit('changed')
  } catch (e) {
    pickError.value = String(e)
  } finally {
    assignBusy.value = ''
  }
}

function kindOf(prov: string): string {
  return creds.value.find(c => c.provider === prov)?.kind ?? 'openai'
}

async function probe(prov: string, model: string) {
  pickError.value = ''
  probeState.value = { ...probeState.value, [model]: { phase: 'probing' } }
  try {
    const r = await api.modelProbe({ provider: prov, model })
    // Poll the verdict inline (the terminal-transition trigger writes it into
    // model_capability the moment the probe row lands done/error) so the ✓/✗
    // shows right here, not down in the catalog.
    const deadline = Date.now() + 90_000
    while (Date.now() < deadline) {
      await new Promise(res => setTimeout(res, 1200))
      const s = await api.probeStatus(prov, model, r.work_queue_id)
      if (s.done) {
        const ok = s.usable === true
        probeState.value = {
          ...probeState.value,
          [model]: { phase: ok ? 'ok' : 'fail', detail: s.probe_detail || s.queue_error || '' },
        }
        await load() // keep the catalog row below in sync too
        return
      }
    }
    probeState.value = { ...probeState.value, [model]: { phase: 'fail', detail: 'probe timed out (90s)' } }
  } catch (e) {
    pickError.value = String(e)
    probeState.value = { ...probeState.value, [model]: { phase: 'fail', detail: String(e) } }
  }
}

async function removeCredential(prov: string) {
  if (!confirm(`Remove the stored key AND dials for '${prov}'?`)) return
  try {
    await api.credentialDelete(prov, true)
    await load()
    emit('changed')
  } catch (e) {
    listError.value = String(e)
  }
}

function fmtBudget(c: CredentialRow): string {
  if (c.budget_micro == null) return '—'
  const cap = (c.budget_micro / 1_000_000).toFixed(2)
  const spent = c.budget_spent_micro != null ? (c.budget_spent_micro / 1_000_000).toFixed(2) : '0.00'
  const cadence = c.budget_cadence === 'daily' ? '/day' : ' prepaid'
  return `$${spent} of $${cap}${cadence}`
}

onMounted(load)
</script>

<template>
  <section class="wizard">
    <header class="wiz-header">
      <h2>Providers &amp; models — setup wizard</h2>
      <p class="wiz-sub">
        Add a key, it's <strong>tested on save</strong> (a live <code>GET /models</code>),
        then pick models, assign the role aliases, and set a daily budget.
        Keys are AES-256-GCM encrypted at rest and are <strong>never echoed back</strong>.
      </p>
    </header>

    <div v-if="!masterKeySet" class="wiz-warn">
      The setup wizard needs <code>STEWARDS_MASTER_KEY</code> in <code>.env</code>
      (32 bytes of base64 — <code>openssl rand -base64 32</code>), shared by the
      <code>ui</code> and <code>pg</code> containers. Keyless local providers
      (LM&nbsp;Studio) can still be added below.
      <span v-if="masterKeyError" class="wiz-warn-detail">{{ masterKeyError }}</span>
    </div>

    <!-- role-alias summary: what the four roles resolve to right now -->
    <div class="roles-strip">
      <span v-for="role in roleAliases" :key="role" class="role-chip">
        <span class="role-name">{{ role }}</span>
        <template v-if="rolesFor[role]?.length">
          <code>{{ preferredMember(role)?.provider }}/{{ preferredMember(role)?.model }}</code>
          <span v-if="(rolesFor[role]?.length ?? 0) > 1" class="role-more">+{{ (rolesFor[role]?.length ?? 0) - 1 }}</span>
        </template>
        <span v-else class="role-unset">unassigned</span>
      </span>
    </div>

    <div v-if="listError" class="wiz-error">{{ listError }}</div>

    <!-- existing wizard-managed providers -->
    <table v-if="creds.length" class="cred-table">
      <thead>
        <tr><th>Provider</th><th>Endpoint</th><th>Key</th><th>Verified</th><th>pg</th><th>Budget</th><th></th></tr>
      </thead>
      <tbody>
        <tr v-for="c in creds" :key="c.provider">
          <td class="mono">{{ c.provider }}</td>
          <td class="mono dim">{{ c.base_url || '(env)' }}</td>
          <td>
            <span v-if="c.is_set" class="ok">● set</span>
            <span v-else class="dim">keyless</span>
          </td>
          <td class="dim">{{ c.last_verified_at ? c.last_verified_at.slice(0, 16).replace('T', ' ') : '—' }}</td>
          <td>
            <span v-if="!c.is_set" class="dim">—</span>
            <span v-else-if="c.pg_decrypt === 'ok'" class="ok" title="the Postgres dispatcher can decrypt this key">✓</span>
            <span v-else class="warn" :title="c.pg_decrypt">⚠</span>
          </td>
          <td class="dim">{{ fmtBudget(c) }}</td>
          <td class="actions">
            <button class="btn" @click="openModels(c.provider)">models</button>
            <button class="btn danger" @click="removeCredential(c.provider)">delete</button>
          </td>
        </tr>
      </tbody>
    </table>

    <!-- add / update -->
    <form class="add-form" @submit.prevent="save">
      <div class="row">
        <label>
          <span>Preset</span>
          <select v-model="preset" @change="applyPreset">
            <option v-for="(_, name) in presets" :key="name" :value="name">{{ name }}</option>
          </select>
        </label>
        <label>
          <span>Provider id</span>
          <input v-model="provider" placeholder="opencode_zen" spellcheck="false" />
        </label>
        <label class="grow">
          <span>Base URL</span>
          <input v-model="baseUrl" placeholder="https://…/v1" spellcheck="false" />
        </label>
        <label>
          <span>Kind</span>
          <select v-model="kind">
            <option value="openai">openai</option>
            <option value="anthropic">anthropic</option>
          </select>
        </label>
      </div>
      <div class="row">
        <!-- key providers: paste a string. Vertex (secret_kind=json): drop the SA file. -->
        <label v-if="secretKind === 'key'" class="grow">
          <span>API key <em class="dim">(blank = keyless / keep + re-verify existing)</em></span>
          <input v-model="secret" type="password" autocomplete="off" placeholder="sk-…" />
        </label>
        <label v-else class="grow">
          <span>Service-account JSON <em class="dim">(drop your GCP SA key file)</em></span>
          <input type="file" accept=".json,application/json" @change="onJsonFile" />
          <span v-if="jsonFileName" class="ok">● {{ jsonFileName }} loaded (encrypted on save)</span>
        </label>
        <label>
          <span>Budget $/day <em class="dim">(blank = none)</em></span>
          <input v-model.number="budget" type="number" min="0" step="0.5" style="width: 7rem" />
        </label>
        <button class="btn primary" type="submit" :disabled="saving">
          {{ saving ? 'testing…' : 'Save & test' }}
        </button>
      </div>
      <p v-if="presetHint" class="hint dim">{{ presetHint }}</p>
      <div v-if="saveError" class="wiz-error">{{ saveError }}</div>
      <div v-if="saveOk" class="wiz-ok">{{ saveOk }}</div>
    </form>

    <!-- model picker: assign roles + prices to what the provider actually serves -->
    <div v-if="pickProvider" class="picker">
      <h3>Models on <code>{{ pickProvider }}</code>
        <span v-if="pickBusy" class="dim"> — loading…</span>
      </h3>
      <!-- name a model to probe when /models can't be listed (Vertex SA keys) -->
      <div class="add-model">
        <input v-model="manualModel" placeholder="model id (e.g. google/gemini-3.1-pro-preview)"
               @keydown.enter.prevent="addManualModel" />
        <button class="btn" type="button" :disabled="!manualModel.trim()" @click="addManualModel">+ add model</button>
      </div>
      <p v-if="pickNote" class="hint dim">{{ pickNote }}</p>
      <div v-if="pickError" class="wiz-error">{{ pickError }}</div>
      <table v-if="pickModels.length" class="pick-table">
        <thead>
          <tr><th>Model</th><th>Roles</th><th>$/Mtok in·out</th><th></th></tr>
        </thead>
        <tbody>
          <tr v-for="m in pickModels" :key="m">
            <td class="mono">
              {{ m }}
              <span v-if="!modelPriced(pickProvider, m)" class="warn" title="no pricing row — spend counts $0, budgets can't see this model">unpriced</span>
            </td>
            <td class="roles-cell">
              <button v-for="role in roleAliases" :key="role"
                      class="btn role-btn"
                      :class="{ on: modelHasRole(role, pickProvider, m) }"
                      :disabled="assignBusy === `${role}:${m}`"
                      @click="toggleRole(role, pickProvider, m)">
                {{ role }}
              </button>
            </td>
            <td class="prices">
              <input v-model="priceIn[m]" placeholder="in" title="input $/Mtok (applied when a role is assigned)" />
              <input v-model="priceOut[m]" placeholder="out" title="output $/Mtok (applied when a role is assigned)" />
            </td>
            <td class="probe-cell">
              <button class="btn"
                      title="real-path streaming probe through the actual dispatcher"
                      :disabled="probeState[m]?.phase === 'probing'"
                      @click="probe(pickProvider, m)">
                {{ probeState[m]?.phase === 'probing' ? 'probing…' : 'probe' }}
              </button>
              <span v-if="probeState[m]?.phase === 'ok'" class="probe-chip ok"
                    :title="probeState[m]?.detail || 'model answered the real-path probe'">✓ usable</span>
              <span v-else-if="probeState[m]?.phase === 'fail'" class="probe-chip fail"
                    :title="probeState[m]?.detail || 'probe failed'">✗ {{ probeState[m]?.detail ? 'failed' : 'unusable' }}</span>
            </td>
          </tr>
        </tbody>
      </table>
      <p v-else-if="!pickBusy && !pickError" class="dim">no models listed.</p>
    </div>
  </section>
</template>

<style scoped>
.wizard {
  border: 1px solid var(--border, #444);
  border-radius: 6px;
  padding: 1rem 1.25rem 1.25rem;
  margin-bottom: 2rem;
  background: var(--surface-alt, #161616);
}
.wiz-header h2 { margin: 0 0 0.25rem; font-size: 1.1rem; }
.wiz-sub { color: var(--text-muted, #888); margin: 0 0 0.9rem; font-size: 0.9rem; }
.wiz-sub code, .wiz-warn code { background: var(--surface, #1a1a1a); padding: 1px 4px; border-radius: 3px; font-size: 0.85em; }

.wiz-warn {
  padding: 0.6rem 0.8rem;
  border: 1px solid #b9770e;
  border-radius: 4px;
  color: #e6a23c;
  font-size: 0.9rem;
  margin-bottom: 0.9rem;
}
.wiz-warn-detail { display: block; margin-top: 0.3rem; font-size: 0.85em; }
.wiz-error {
  padding: 0.5rem 0.8rem;
  background: rgba(192, 57, 43, 0.15);
  border: 1px solid #c0392b;
  border-radius: 4px;
  color: #ff6b5b;
  font-size: 0.9rem;
  margin: 0.6rem 0;
  white-space: pre-wrap;
}
.wiz-ok {
  padding: 0.5rem 0.8rem;
  background: rgba(39, 174, 96, 0.12);
  border: 1px solid #27ae60;
  border-radius: 4px;
  color: #2ecc71;
  font-size: 0.9rem;
  margin: 0.6rem 0;
}

.roles-strip { display: flex; flex-wrap: wrap; gap: 0.5rem; margin-bottom: 0.9rem; }
.role-chip {
  display: inline-flex; align-items: baseline; gap: 0.4rem;
  border: 1px solid var(--border-subtle, #2a2a2a);
  border-radius: 4px; padding: 0.25rem 0.55rem; font-size: 0.85rem;
}
.role-name { font-weight: 600; }
.role-chip code { font-family: var(--font-mono, monospace); color: var(--text, #ddd); }
.role-more, .role-unset { color: var(--text-muted, #888); }

.cred-table, .pick-table { width: 100%; border-collapse: collapse; font-size: 0.9rem; margin-bottom: 1rem; }
.cred-table th, .cred-table td, .pick-table th, .pick-table td {
  padding: 0.4rem 0.6rem; text-align: left;
  border-bottom: 1px solid var(--border-subtle, #2a2a2a);
}
.cred-table th, .pick-table th {
  color: var(--text-muted, #888); font-weight: 500; font-size: 0.78rem;
  text-transform: uppercase; letter-spacing: 0.03em;
}
.mono { font-family: var(--font-mono, monospace); }
.dim { color: var(--text-muted, #888); }
.ok { color: #2ecc71; }
.warn { color: #e6a23c; font-size: 0.8em; margin-left: 0.3rem; }
.actions { white-space: nowrap; }

.add-form { margin-top: 0.4rem; }
.add-form .row { display: flex; gap: 0.8rem; align-items: flex-end; margin-bottom: 0.6rem; flex-wrap: wrap; }
.add-form label { display: flex; flex-direction: column; gap: 0.2rem; font-size: 0.8rem; color: var(--text-muted, #888); }
.add-form label.grow { flex: 1; min-width: 14rem; }
.add-form input, .add-form select {
  padding: 0.35rem 0.5rem;
  border: 1px solid var(--border, #444);
  border-radius: 4px;
  background: var(--surface, #1a1a1a);
  color: inherit;
  font-size: 0.9rem;
}
.hint { font-size: 0.82rem; margin: 0.1rem 0 0; }

.btn {
  padding: 0.3rem 0.7rem;
  border: 1px solid var(--border, #444);
  border-radius: 4px;
  background: var(--surface, #1a1a1a);
  color: inherit;
  cursor: pointer;
  font-size: 0.85rem;
}
.btn:hover { background: var(--surface-hover, #2a2a2a); }
.btn.primary { border-color: #2d7dd2; color: #6cb2ff; }
.btn.danger { border-color: #c0392b; color: #ff6b5b; }
.btn:disabled { opacity: 0.5; cursor: default; }

.picker h3 { font-size: 0.95rem; margin: 0.6rem 0; }
.roles-cell { white-space: nowrap; }
.role-btn { margin-right: 0.3rem; font-size: 0.78rem; padding: 0.2rem 0.5rem; }
.role-btn.on { border-color: #27ae60; color: #2ecc71; }
.prices input {
  width: 4.2rem; margin-right: 0.3rem;
  padding: 0.25rem 0.4rem;
  border: 1px solid var(--border, #444);
  border-radius: 4px;
  background: var(--surface, #1a1a1a);
  color: inherit;
  font-size: 0.85rem;
}
.add-model {
  display: flex;
  gap: 0.4rem;
  margin: 0.4rem 0 0.8rem;
}
.add-model input {
  flex: 1;
  max-width: 420px;
  padding: 0.3rem 0.5rem;
  border: 1px solid var(--border, #444);
  border-radius: 4px;
  background: var(--surface, #1a1a1a);
  color: inherit;
  font-family: var(--font-mono, monospace);
  font-size: 0.85rem;
}
.probe-cell { white-space: nowrap; }
.probe-chip {
  margin-left: 0.4rem;
  font-size: 0.8rem;
  font-weight: 600;
  cursor: help;
}
.probe-chip.ok { color: #2ecc71; }
.probe-chip.fail { color: #ff6b5b; }
</style>
