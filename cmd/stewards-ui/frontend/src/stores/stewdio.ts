import { defineStore } from 'pinia'
import { ref } from 'vue'

// Stewdio — the work-item cockpit's shared cross-panel state. The dockview
// browser, artifact, and chat panels are mounted independently, so they
// coordinate through this Pinia store. See .spec/proposals/stewards-studio.md.
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

  function select(ref_: string, kind: SelectedKind, title = '') {
    selectedRef.value = ref_
    selectedKind.value = kind
    selectedTitle.value = title || ref_
  }

  return { projectFilter, selectedRef, selectedKind, selectedTitle, chatModel, select }
})
