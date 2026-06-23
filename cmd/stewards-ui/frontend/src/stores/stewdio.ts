import { defineStore } from 'pinia'
import { ref } from 'vue'

// Stewdio — the work-item cockpit's shared cross-panel state. This is the first
// view in stewards-ui that genuinely needs reactive state shared across panels
// (the dockview browser, artifact, and chat panels coordinate through it). P0
// scaffolds the shape; P1+ fill the behaviour. See
// .spec/proposals/stewards-studio.md.
export const useStewdioStore = defineStore('stewdio', () => {
  // left browser: filter work items / docs by project (null = all)
  const projectFilter = ref<string | null>(null)
  // the work_item id or doc slug currently in focus (drives the center panel)
  const selectedRef = ref<string | null>(null)
  // the active "chat with a work item" session (P1: dispatch_chat_turn + SSE)
  const chatSessionId = ref<string | null>(null)
  // the chat model — a role alias resolves to the local rig in a work instance
  const chatModel = ref<string>('reason')

  function select(ref_: string | null) {
    selectedRef.value = ref_
  }

  return { projectFilter, selectedRef, chatSessionId, chatModel, select }
})
