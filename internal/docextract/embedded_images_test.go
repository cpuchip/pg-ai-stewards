package docextract

import (
	"bytes"
	"image"
	"image/color"
	"image/png"
	"testing"
)

// ---------------------------------------------------------------------
// filterImageCandidates — the metadata-only junk-filter oracle. Rows below
// are a trimmed, faithful replay of `pdfimages -list` against a REAL 94-page
// TTRPG rulebook (the Cosmere RPG beta preview): object 6426 is a full-bleed
// background recurring on nearly every page (90/94 in the real doc; here a
// handful stand in for "more than maxObjectRepeats"), object 779 recurs 3x
// (a section-banner), and each page's smask row is the alpha companion of
// its image row. No pixels are decoded for this filter — it runs on the
// pdfimages -list table alone, so this test needs no poppler binary.
// ---------------------------------------------------------------------

func TestFilterImageCandidates_DropsSmaskAndFurniture(t *testing.T) {
	rows := []imgListRow{
		// page 1: repeated background (6426) + its smask, plus real content (6440)
		{Page: 1, Num: 0, Type: "image", Width: 2593, Height: 3376, Object: "6426"},
		{Page: 1, Num: 1, Type: "smask", Width: 2593, Height: 3376, Object: "6426"},
		{Page: 1, Num: 2, Type: "image", Width: 2503, Height: 3254, Object: "6440"},
		// page 2: same repeated background again + a section banner (779)
		{Page: 2, Num: 0, Type: "image", Width: 2593, Height: 3376, Object: "6426"},
		{Page: 2, Num: 1, Type: "smask", Width: 2593, Height: 3376, Object: "6426"},
		{Page: 2, Num: 2, Type: "image", Width: 950, Height: 625, Object: "779"},
		// page 3: background again (3rd occurrence -> now exceeds maxObjectRepeats=2)
		{Page: 3, Num: 0, Type: "image", Width: 2593, Height: 3376, Object: "6426"},
		// page 3: banner again (2nd occurrence -> still <= maxObjectRepeats, real content)
		{Page: 3, Num: 1, Type: "image", Width: 950, Height: 625, Object: "779"},
		// page 3: banner a 3rd time (now exceeds threshold, on a later page)
		{Page: 4, Num: 0, Type: "image", Width: 950, Height: 625, Object: "779"},
		// page 5: a tiny icon (below minImageDim) with a unique object -> dropped by size
		{Page: 5, Num: 0, Type: "image", Width: 40, Height: 40, Object: "999"},
		// page 6: real, unique, appropriately-sized content -> KEPT
		{Page: 6, Num: 0, Type: "image", Width: 850, Height: 927, Object: "362"},
	}

	got := filterImageCandidates(rows, 0)

	// smask rows never survive regardless of anything else.
	for _, r := range got {
		if r.Type == "smask" {
			t.Errorf("smask row leaked through the filter: %+v", r)
		}
	}
	// the repeated background (object 6426, 3 distinct pages) must be fully dropped.
	for _, r := range got {
		if r.Object == "6426" {
			t.Errorf("repeated-furniture object 6426 leaked through: %+v", r)
		}
	}
	// the banner (object 779, 3 distinct pages: 2,3,4) also exceeds maxObjectRepeats=2 -> dropped.
	for _, r := range got {
		if r.Object == "779" {
			t.Errorf("repeated banner object 779 leaked through: %+v", r)
		}
	}
	// the tiny icon must be dropped by the size filter.
	for _, r := range got {
		if r.Object == "999" {
			t.Errorf("tiny icon (40x40) leaked through the size filter: %+v", r)
		}
	}
	// real, unique content must survive.
	var sawReal bool
	for _, r := range got {
		if r.Object == "6440" || r.Object == "362" {
			sawReal = true
		}
	}
	if !sawReal {
		t.Errorf("real unique content was dropped; got %+v", got)
	}
}

func TestFilterImageCandidates_CapsToMaxImages(t *testing.T) {
	var rows []imgListRow
	for i := 0; i < 10; i++ {
		rows = append(rows, imgListRow{Page: i + 1, Num: 0, Type: "image", Width: 500, Height: 500, Object: "unique" + string(rune('a'+i))})
	}
	got := filterImageCandidates(rows, 3)
	if len(got) != 3 {
		t.Errorf("got %d candidates, want capped to 3", len(got))
	}
}

func TestFilterImageCandidates_KeepsRepeatAtThreshold(t *testing.T) {
	// an object reused on EXACTLY maxObjectRepeats (2) pages is still real content
	// (e.g. a rules-callout icon used twice), not furniture — must survive.
	rows := []imgListRow{
		{Page: 1, Num: 0, Type: "image", Width: 400, Height: 400, Object: "twice"},
		{Page: 5, Num: 0, Type: "image", Width: 400, Height: 400, Object: "twice"},
	}
	got := filterImageCandidates(rows, 0)
	if len(got) != 2 {
		t.Errorf("an object at exactly maxObjectRepeats should survive both instances, got %d: %+v", len(got), got)
	}
}

// ---------------------------------------------------------------------
// parseImageList / LocalIndex — the poppler global-vs-local numbering bug.
// ---------------------------------------------------------------------
//
// A REAL regression, caught by running the full pipeline against a real
// 94-page PDF (the Cosmere RPG beta preview) before shipping: `pdfimages
// -list` numbers images GLOBALLY across the whole document (page 8's 4th
// image was global num=24), but `pdfimages -png -p -f 8 -l 8` (the per-page
// targeted extraction extractEmbeddedImages actually runs) renumbers its
// output files LOCALLY per page, starting at 0 — so that same image came out
// as "img-008-002.png" (local index 2), never 24. Matching extracted
// filenames against -list's global Num silently dropped every single image.
// This transcript is the REAL `pdfimages -list` output for page 8 of that
// document (trimmed to page 8's 4 rows); it must parse to LocalIndex 0..3.

const realPage8Transcript = `page   num  type   width height color comp bpc  enc interp  object ID x-ppi y-ppi size ratio
--------------------------------------------------------------------------------------------
   8    22 image    2593  3376  icc     3   8  jpeg   no      6426  0   300   300  492K 1.9%
   8    23 smask    2593  3376  gray    1   8  jpeg   no      6426  0   300   300 35.3K 0.4%
   8    24 image    1091  1226  icc     3   8  jpeg   no        64  0   300   300  328K 8.4%
   8    25 smask    1091  1226  gray    1   8  jpeg   no        64  0   300   300 50.7K 3.9%
`

func TestParseImageList_LocalIndexIsPerPagePosition(t *testing.T) {
	rows := parseImageList(realPage8Transcript)
	if len(rows) != 4 {
		t.Fatalf("got %d rows, want 4", len(rows))
	}
	for i, r := range rows {
		if r.Page != 8 {
			t.Errorf("row %d: page = %d, want 8", i, r.Page)
		}
		if r.LocalIndex != i {
			t.Errorf("row %d (global num=%d): LocalIndex = %d, want %d — this is the exact bug that made extraction silently return zero images", i, r.Num, r.LocalIndex, i)
		}
	}
	// the real-content row (global num=24, object 64, the one worth keeping)
	// must be LocalIndex 2 — matching the real "img-008-002.png" poppler wrote.
	real := rows[2]
	if real.Num != 24 || real.Object != "64" || real.LocalIndex != 2 {
		t.Errorf("expected the real-content row at index 2 to be (num=24, object=64, local=2), got %+v", real)
	}
}

func TestExtractEmbeddedImages_KeyIsLocalIndexNotGlobalNum(t *testing.T) {
	// Simulates exactly what extractEmbeddedImages does: filter -list rows to
	// candidates, then build the (page, key) lookup a filename match uses.
	// Asserts the map is keyed on LocalIndex (what a real extracted filename
	// carries) and NOT on Num (what -list reports) — regression coverage for
	// the bug fixed above, independent of poppler/Docker.
	rows := parseImageList(realPage8Transcript)
	// This transcript is trimmed to ONE page, so the cross-page repeat-dedup
	// can't fire on object 6426 here (that requires seeing it recur on OTHER
	// pages too, exercised separately in TestFilterImageCandidates_*); both
	// "image"-typed rows on this page survive the (isolated) filter, and the
	// smasks are dropped by type regardless of page context.
	candidates := filterImageCandidates(rows, 0)
	if len(candidates) != 2 {
		t.Fatalf("expected 2 surviving image-typed rows (both smasks dropped by type), got %d: %+v", len(candidates), candidates)
	}
	// Find the real-content candidate (object 64) and confirm ITS key.
	var real *imgListRow
	for i := range candidates {
		if candidates[i].Object == "64" {
			real = &candidates[i]
		}
	}
	if real == nil {
		t.Fatalf("object 64 (the real content) missing from candidates: %+v", candidates)
	}
	// A real extracted filename for this image would be "img-008-002.png" —
	// i.e. the file-matching key must be (page=8, local=2), NOT (page=8, num=24).
	wantKey := [2]int{8, 2}
	gotKey := [2]int{real.Page, real.LocalIndex}
	if gotKey != wantKey {
		t.Errorf("candidate key = %v, want %v (LocalIndex, not the -list global Num=%d)", gotKey, wantKey, real.Num)
	}
}

// ---------------------------------------------------------------------
// isFlatOrBlank — the pixel-level blank/decoration safety net.
// ---------------------------------------------------------------------

func TestIsFlatOrBlank_WhiteAndFlatDropped(t *testing.T) {
	white := solidImage(200, 200, color.RGBA{255, 255, 255, 255})
	if !isFlatOrBlank(white) {
		t.Error("a pure-white image should be flagged blank")
	}
	navy := solidImage(200, 200, color.RGBA{20, 30, 90, 255}) // a solid divider-bar color, not white
	if !isFlatOrBlank(navy) {
		t.Error("a single flat non-white color should also be flagged blank (decoration)")
	}
}

func TestIsFlatOrBlank_RealArtKept(t *testing.T) {
	checker := checkerImage(200, 200)
	if isFlatOrBlank(checker) {
		t.Error("a high-variance (checkerboard) image should NOT be flagged blank")
	}
}

func TestDecodedImageStats_RoundTrip(t *testing.T) {
	img := checkerImage(300, 150)
	var buf bytes.Buffer
	if err := png.Encode(&buf, img); err != nil {
		t.Fatalf("encode: %v", err)
	}
	w, h, blank := decodedImageStats(buf.Bytes())
	if w != 300 || h != 150 {
		t.Errorf("decoded dims = %dx%d, want 300x150", w, h)
	}
	if blank {
		t.Error("checkerboard content should not be flagged blank")
	}
}

// ---------------------------------------------------------------------
// helpers
// ---------------------------------------------------------------------

func solidImage(w, h int, c color.RGBA) image.Image {
	img := image.NewRGBA(image.Rect(0, 0, w, h))
	for y := 0; y < h; y++ {
		for x := 0; x < w; x++ {
			img.Set(x, y, c)
		}
	}
	return img
}

func checkerImage(w, h int) image.Image {
	img := image.NewRGBA(image.Rect(0, 0, w, h))
	for y := 0; y < h; y++ {
		for x := 0; x < w; x++ {
			if (x/10+y/10)%2 == 0 {
				img.Set(x, y, color.RGBA{10, 10, 10, 255})
			} else {
				img.Set(x, y, color.RGBA{240, 200, 30, 255})
			}
		}
	}
	return img
}
