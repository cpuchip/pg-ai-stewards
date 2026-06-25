package main

import (
	"testing"
	"time"
)

// RC-3: the bridge daemon gives inherently-slow BULK tools (multi-file extract /
// corpus import) the longer per-call timeout, while fast tools stay snappy — so
// a big-archive import no longer dies at the old uniform ~120s cliff.
func TestCallTimeoutFor(t *testing.T) {
	base := 120 * time.Second
	slow := 600 * time.Second

	slowOnes := []string{"doc_extract", "doc_import_corpus"}
	for _, tool := range slowOnes {
		if got := callTimeoutFor(tool, base, slow); got != slow {
			t.Errorf("callTimeoutFor(%q) = %v, want the SLOW timeout %v", tool, got, slow)
		}
	}
	fastOnes := []string{"doc_search", "fs_search", "coder_grep", "web_search", ""}
	for _, tool := range fastOnes {
		if got := callTimeoutFor(tool, base, slow); got != base {
			t.Errorf("callTimeoutFor(%q) = %v, want the BASE timeout %v", tool, got, base)
		}
	}
}
