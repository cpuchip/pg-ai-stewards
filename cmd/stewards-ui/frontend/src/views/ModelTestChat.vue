<script setup lang="ts">
// Raw model test-chat — pick any (provider, model), send a prompt, see the
// reply. No tools, no skills, no agent loop (the backend enqueues a raw
// completion with tools_disabled=true). Just enough confidence that a model —
// a freshly wizard-added one especially — actually answers. Local page history
// per conversation; "New chat" starts a fresh session.
import { ref, computed } from 'vue'
import { api, type ModelRow } from '@/api'

const props = defineProps<{ models: ModelRow[] }>()

type Turn = { role: 'user' | 'assistant'; content: string; pending?: boolean }
type Opt = { provider: string; model: string; label: string }

const options = computed<Opt[]>(() =>
  props.models.map(m => ({ provider: m.provider, model: m.model, label: `${m.provider} / ${m.model}` })))

const selected = ref<Opt | null>(null)
const prompt = ref('')
const turns = ref<Turn[]>([])
const sessionId = ref('')
const sending = ref(false)
const error = ref('')

function newChat() {
  turns.value = []
  sessionId.value = ''
  error.value = ''
}

async function send() {
  const opt = selected.value
  const text = prompt.value.trim()
  if (!opt || !text || sending.value) return
  error.value = ''
  sending.value = true
  turns.value.push({ role: 'user', content: text })
  const reply: Turn = { role: 'assistant', content: '', pending: true }
  turns.value.push(reply)
  prompt.value = ''

  try {
    const r = await api.modelTestChatSend({
      provider: opt.provider,
      model: opt.model,
      session_id: sessionId.value || undefined,
      prompt: text,
    })
    sessionId.value = r.session_id

    // Poll stewards.messages for the assistant turn (id > the user turn we just
    // wrote). Bounded so a wedged provider surfaces as a timeout, not a hang.
    const deadline = Date.now() + 120_000
    while (Date.now() < deadline) {
      await new Promise(res => setTimeout(res, 1200))
      const p = await api.modelTestChatPoll(r.session_id, r.user_message_id, r.work_queue_id)
      const asst = p.messages.find(m => m.role === 'assistant')
      if (asst) {
        reply.content = asst.content
        reply.pending = false
        break
      }
      if (p.done) {
        // Terminal with no assistant message → a dispatch failure.
        reply.pending = false
        error.value = p.error || `dispatch ended '${p.status}' with no reply`
        break
      }
    }
    if (reply.pending) {
      reply.pending = false
      error.value = 'timed out waiting for a reply (120s)'
    }
  } catch (e) {
    reply.pending = false
    error.value = String(e)
  } finally {
    sending.value = false
  }
}
</script>

<template>
  <section class="test-chat">
    <header class="tc-header">
      <h2>Test chat</h2>
      <span class="tc-sub">Raw send/receive — no tools, no skills. Confirm a model answers.</span>
    </header>

    <div class="tc-controls">
      <select v-model="selected" class="tc-model">
        <option :value="null" disabled>pick a model…</option>
        <option v-for="o in options" :key="o.label" :value="o">{{ o.label }}</option>
      </select>
      <button class="btn" :disabled="!turns.length" @click="newChat">New chat</button>
    </div>

    <div v-if="turns.length" class="tc-log">
      <div v-for="(t, i) in turns" :key="i" class="tc-turn" :class="t.role">
        <span class="tc-role">{{ t.role }}</span>
        <div class="tc-content">
          <span v-if="t.pending" class="tc-thinking">…thinking</span>
          <span v-else>{{ t.content }}</span>
        </div>
      </div>
    </div>

    <div v-if="error" class="tc-error">{{ error }}</div>

    <form class="tc-input" @submit.prevent="send">
      <textarea
        v-model="prompt"
        placeholder="Type a message… (Enter to send, Shift+Enter for newline)"
        rows="2"
        :disabled="!selected || sending"
        @keydown.enter.exact.prevent="send"
      ></textarea>
      <button class="btn send" type="submit" :disabled="!selected || !prompt.trim() || sending">
        {{ sending ? 'sending…' : 'Send' }}
      </button>
    </form>
  </section>
</template>

<style scoped>
.test-chat {
  border: 1px solid var(--border, #444);
  border-radius: 6px;
  padding: 1rem 1.2rem 1.2rem;
  margin-bottom: 2rem;
}
.tc-header {
  display: flex;
  align-items: baseline;
  gap: 0.8rem;
  margin-bottom: 0.8rem;
}
.tc-header h2 { margin: 0; font-size: 1.05rem; }
.tc-sub { font-size: 0.82rem; color: var(--text-muted, #888); }

.tc-controls {
  display: flex;
  gap: 0.6rem;
  align-items: center;
  margin-bottom: 0.8rem;
}
.tc-model {
  flex: 1;
  max-width: 460px;
  padding: 0.4rem 0.6rem;
  border: 1px solid var(--border, #444);
  border-radius: 4px;
  background: var(--surface, #1a1a1a);
  color: inherit;
  font-family: var(--font-mono, monospace);
  font-size: 0.9rem;
}

.tc-log {
  display: flex;
  flex-direction: column;
  gap: 0.6rem;
  max-height: 360px;
  overflow-y: auto;
  padding: 0.6rem;
  border: 1px solid var(--border-subtle, #2a2a2a);
  border-radius: 4px;
  background: var(--surface-alt, #161616);
  margin-bottom: 0.8rem;
}
.tc-turn {
  display: flex;
  flex-direction: column;
  gap: 0.15rem;
}
.tc-role {
  font-size: 0.7rem;
  text-transform: uppercase;
  letter-spacing: 0.04em;
  color: var(--text-muted, #888);
}
.tc-turn.user .tc-role { color: #4a9eff; }
.tc-turn.assistant .tc-role { color: #2ecc71; }
.tc-content {
  white-space: pre-wrap;
  word-break: break-word;
  font-size: 0.9rem;
  line-height: 1.45;
}
.tc-thinking { color: var(--text-muted, #888); font-style: italic; }

.tc-input {
  display: flex;
  gap: 0.6rem;
  align-items: flex-end;
}
.tc-input textarea {
  flex: 1;
  padding: 0.5rem 0.6rem;
  border: 1px solid var(--border, #444);
  border-radius: 4px;
  background: var(--surface, #1a1a1a);
  color: inherit;
  font-family: inherit;
  font-size: 0.9rem;
  resize: vertical;
}
.btn {
  padding: 0.45rem 0.9rem;
  border: 1px solid var(--border, #444);
  border-radius: 4px;
  background: var(--surface, #1a1a1a);
  color: inherit;
  cursor: pointer;
  font-size: 0.85rem;
}
.btn:disabled { opacity: 0.5; cursor: not-allowed; }
.btn.send { background: #1e6b3a; border-color: #2ecc71; }

.tc-error {
  padding: 0.55rem 0.8rem;
  margin-bottom: 0.8rem;
  background: rgba(192, 57, 43, 0.15);
  border: 1px solid #c0392b;
  border-radius: 4px;
  color: #ff6b5b;
  font-size: 0.85rem;
}
</style>
