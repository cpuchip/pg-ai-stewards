// A tiny module-level signal so App.vue's global "/" keydown listener can
// ask whichever Search.vue instance is mounted to (re)focus its input — the
// app has no Pinia store for view-local UI signals, and this is exactly
// that: ephemeral, single-consumer state. Bumped by requestSearchFocus();
// Search.vue watches searchFocusRequest and calls its input ref's .focus().
import { ref } from 'vue'

export const searchFocusRequest = ref(0)

export function requestSearchFocus() {
  searchFocusRequest.value++
}
