import { defineStore } from 'pinia'
import { ref } from 'vue'

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
  // the chat model — a role alias resolves to the local rig in a work instance
  const chatModel = ref<string>('reason')

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
    projectFilter, selectedRef, selectedKind, selectedTitle, chatModel,
    requestedLens, requestedSession, select, openChat,
  }
})
