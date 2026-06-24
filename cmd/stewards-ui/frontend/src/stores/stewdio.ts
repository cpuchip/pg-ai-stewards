import { defineStore } from 'pinia'
import { ref, watch } from 'vue'

// a ref backed by localStorage so a preference survives reload.
function persisted<T>(key: string, initial: T) {
  let start = initial
  const raw = localStorage.getItem(key)
  if (raw !== null) {
    try { const p = JSON.parse(raw); if (typeof p === typeof initial) start = p as T } // ignore wrong-typed stale values
    catch { /* malformed — use initial */ }
  }
  const r = ref<T>(start)
  watch(r, (v) => { try { localStorage.setItem(key, JSON.stringify(v)) } catch { /* quota */ } })
  return r
}

// Stewdio — the work-item cockpit's shared cross-panel state. The dockview
// browser, artifact, chat, sessions, and models panels are mounted
// independently, so they coordinate through this Pinia store.
// See .spec/proposals/stewards-studio.md.
export type SelectedKind = 'doc' | 'work_item'

export const useStewdioStore = defineStore('stewdio', () => {
  // left browser: filter work items / docs by project (null = all)
  const projectFilter = ref<string | null>(null)
  // the doc slug or work_item id currently in focus (drives the center + chat)
  const selectedRef = ref<string | null>(null)
  const selectedKind = ref<SelectedKind | null>(null)
  const selectedTitle = ref<string>('')
  // the chat model role — a power-user knob, session-only (NOT persisted): the
  // select that changes it is Developer-gated, so persisting a non-default role
  // would silently strand an everyday user on a role they can't see or reset.
  const chatModel = ref<string>('reason')

  // Developer mode (streamline S4). OFF by default → the everyday surface hides
  // power/ops introspection: the model-role select, provenance chips + the
  // "🔧 retrieving" tool-call rows (ChatPanel), the raw input-JSON dump + the
  // per-stage model column (ArtifactPanel), and the Models pane. ON brings the
  // full power surface back. One flag, zero capability loss, persisted.
  const dev = persisted<boolean>('stewdio.dev', false)

  // Sessions panel → chat coordination. requestedLens drives the empty-chat
  // lens (''/'__all__'/project name); requestedSession opens an exact chat. The
  // ChatPanel watches both and clears them after honoring (one-shot signals).
  const requestedLens = ref<string | null>(null)
  const requestedSession = ref<string | null>(null)

  function select(ref_: string, kind: SelectedKind, title = '') {
    selectedRef.value = ref_
    selectedKind.value = kind
    selectedTitle.value = title || ref_
  }

  // openChat — from the Sessions panel: focus a chat's target and open the exact
  // session, whatever it's grounded in (a work item / doc / project corpus / the
  // whole pool). The ChatPanel reacts to selectedRef / requestedLens / requestedSession.
  function openChat(targetRef: string, kind: string, title: string, sessionId: string) {
    if (kind === 'work_item' || kind === 'doc') {
      requestedLens.value = '' // clear the lens; a selected work item/doc wins
      select(targetRef, kind as SelectedKind, title)
    } else {
      // project / all / unknown → ground via the lens, not a selected item
      selectedRef.value = null
      selectedKind.value = null
      selectedTitle.value = ''
      requestedLens.value = kind === 'all' ? '__all__' : kind === 'project' ? title : ''
    }
    requestedSession.value = sessionId
  }

  return {
    projectFilter, selectedRef, selectedKind, selectedTitle, chatModel, dev,
    requestedLens, requestedSession, select, openChat,
  }
})
