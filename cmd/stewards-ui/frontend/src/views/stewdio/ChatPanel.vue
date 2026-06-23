<script setup lang="ts">
// Stewdio right panel — chat with the selected work item (the deep-dive
// surface). P0: placeholder. P1 wires dispatch_chat_turn + the /api/chat/stream
// SSE relay, grounded in the work item's doc + corpus + building sessions, on a
// local model; it also kicks off new pipelines (P2) with live progress.
defineOptions({ inheritAttrs: false })
</script>

<template>
  <div class="h-full flex flex-col bg-zinc-950">
    <div class="flex-1 overflow-auto p-3 text-sm">
      <div class="text-zinc-200 font-medium mb-1">Chat</div>
      <div class="text-zinc-500 text-xs leading-relaxed">
        Chat with the selected work item — grounded in its doc, source corpus,
        and the sessions that built it; local model, SSE-streamed.
        <span class="text-zinc-600">Wired in P1.</span>
      </div>
    </div>
    <div class="border-t border-zinc-800 p-2">
      <input
        disabled
        placeholder="message… (P1)"
        class="w-full bg-zinc-900 border border-zinc-800 rounded px-3 py-2 text-sm text-zinc-500"
      />
    </div>
  </div>
</template>
