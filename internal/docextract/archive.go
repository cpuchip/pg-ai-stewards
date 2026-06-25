package docextract

import (
	"bytes"
	"context"
	"fmt"
	"io"
	"path"
	"strings"

	"github.com/mholt/archives"
)

// member is one unpacked archive entry held in memory (capped). The bytes feed
// straight into the per-file pipeline — nothing is written to disk, so a
// decompression bomb is bounded by the in-memory caps, not the filesystem.
type member struct {
	name string
	data []byte
}

// Member is the exported view of an unpacked archive entry, for callers that
// WRITE the vetted members to disk (the coder "explore a dropped archive" path,
// RC-2). Name is already cleaned + zip-slip-vetted by safeArchiveName.
type Member struct {
	Name string
	Data []byte
}

// Unpack safely unpacks an archive into memory under the caps — the exported
// wrapper over unpackArchive (same hardened zip-slip / bomb / symlink guards).
// Callers writing the result to disk MUST still re-verify containment per write.
func Unpack(ctx context.Context, data []byte, filename string, caps ArchiveCaps) ([]Member, []string, error) {
	ms, warnings, err := unpackArchive(ctx, data, filename, caps)
	out := make([]Member, 0, len(ms))
	for _, m := range ms {
		out = append(out, Member{Name: m.name, Data: m.data})
	}
	return out, warnings, err
}

// IsArchive reports whether data looks like an archive or a compressed file we
// can unpack (zip / 7z / tar / rar / gz / bz2 / xz / …). Used by the router to
// decide between the single-file pipeline and the archive pipeline.
func IsArchive(ctx context.Context, data []byte, filename string) bool {
	format, _, err := archives.Identify(ctx, filename, bytes.NewReader(data))
	if err != nil {
		return false
	}
	_, isExtractor := format.(archives.Extractor)
	_, isDecomp := format.(archives.Decompressor)
	return isExtractor || isDecomp
}

// unpackArchive safely unpacks an archive's members into memory under the caps.
// It enforces, per the proposal §3.5 threat table:
//   - zip-slip / path traversal: reject ".." and absolute paths (safeArchiveName)
//   - symlink escape: reject symlink / non-regular entries
//   - decompression bomb: per-entry size cap + total-uncompressed cap +
//     compression-ratio ceiling (uncompressed/compressed)
//   - inode flood: entry-count cap
//
// Returns the members plus any warnings (caps hit, skipped entries). A hard
// bomb (ratio/total breach) returns an error so the caller aborts the whole run.
func unpackArchive(ctx context.Context, data []byte, filename string, caps ArchiveCaps) ([]member, []string, error) {
	if caps.MaxTotalUncompressed == 0 {
		caps = DefaultArchiveCaps()
	}
	format, reader, err := archives.Identify(ctx, filename, bytes.NewReader(data))
	if err != nil {
		return nil, nil, fmt.Errorf("identify archive: %w", err)
	}

	compressedSize := int64(len(data))
	var (
		members  []member
		warnings []string
		total    int64
	)

	// checkRatio enforces the compression-ratio ceiling as uncompressed grows.
	checkRatio := func() error {
		if caps.MaxRatio > 0 && total > compressedSize*int64(caps.MaxRatio) {
			return fmt.Errorf("decompression-bomb guard: uncompressed %d exceeds %dx the compressed %d",
				total, caps.MaxRatio, compressedSize)
		}
		return nil
	}

	// addMember applies the per-entry + total caps and stores the bytes.
	addMember := func(name string, r io.Reader) error {
		clean, ok := safeArchiveName(name)
		if !ok {
			warnings = append(warnings, "skipped unsafe entry path: "+name)
			return nil
		}
		if len(members) >= caps.MaxEntries {
			return fmt.Errorf("entry-count cap reached (%d) — refusing to process more", caps.MaxEntries)
		}
		// Read at most MaxEntrySize+1 so an oversize entry trips the cap without
		// loading the whole bomb into memory.
		buf, rerr := io.ReadAll(io.LimitReader(r, caps.MaxEntrySize+1))
		if rerr != nil {
			warnings = append(warnings, fmt.Sprintf("read entry %q: %v", clean, rerr))
			return nil
		}
		if int64(len(buf)) > caps.MaxEntrySize {
			warnings = append(warnings, fmt.Sprintf("skipped oversize entry %q (> %d bytes)", clean, caps.MaxEntrySize))
			return nil
		}
		total += int64(len(buf))
		if caps.MaxTotalUncompressed > 0 && total > caps.MaxTotalUncompressed {
			return fmt.Errorf("total-uncompressed cap reached (%d bytes) — refusing to process more", caps.MaxTotalUncompressed)
		}
		if err := checkRatio(); err != nil {
			return err
		}
		members = append(members, member{name: clean, data: buf})
		return nil
	}

	switch f := format.(type) {
	case archives.Extractor:
		// A walkable archive (tar/zip/7z/rar and the tar.* combos).
		walkErr := f.Extract(ctx, reader, func(ctx context.Context, info archives.FileInfo) error {
			if info.IsDir() {
				return nil
			}
			// Symlink / non-regular escape guard: refuse anything that isn't a
			// plain file. (A symlink entry could point at / outside the box.)
			if info.LinkTarget != "" || !info.Mode().IsRegular() {
				warnings = append(warnings, "skipped non-regular entry: "+info.NameInArchive)
				return nil
			}
			rc, oerr := info.Open()
			if oerr != nil {
				warnings = append(warnings, fmt.Sprintf("open entry %q: %v", info.NameInArchive, oerr))
				return nil
			}
			defer rc.Close()
			return addMember(info.NameInArchive, rc)
		})
		if walkErr != nil {
			// A caps breach mid-walk is a hard stop (bomb defense); surface it.
			return members, warnings, walkErr
		}
	case archives.Decompressor:
		// A bare compressed single file (report.pdf.gz): one decompressed stream.
		rc, derr := f.OpenReader(reader)
		if derr != nil {
			return nil, nil, fmt.Errorf("open decompressor: %w", derr)
		}
		defer rc.Close()
		if err := addMember(decompressedName(filename), rc); err != nil {
			return members, warnings, err
		}
	default:
		return nil, nil, fmt.Errorf("identified format %q is neither extractable nor decompressible", format.Extension())
	}

	return members, warnings, nil
}

// safeArchiveName cleans an archive entry name and rejects path traversal.
// Returns the cleaned, slash-separated relative path and ok=false for any
// absolute path, any "../" escape, or an empty result. This is the zip-slip
// guard (the coder sandbox's resolvePath sibling) — unit-tested directly.
func safeArchiveName(name string) (string, bool) {
	// Normalize separators; archives may carry either.
	n := strings.ReplaceAll(name, "\\", "/")
	n = strings.TrimPrefix(n, "./")
	if n == "" {
		return "", false
	}
	// Absolute paths (unix "/..." or windows "C:...") are never allowed.
	if strings.HasPrefix(n, "/") || hasDriveLetter(n) {
		return "", false
	}
	clean := path.Clean(n)
	// After cleaning, any leading ".." means the entry escapes the extract root.
	if clean == ".." || strings.HasPrefix(clean, "../") || clean == "." {
		return "", false
	}
	// A defensive second check: no interior ".." component survived.
	for _, part := range strings.Split(clean, "/") {
		if part == ".." {
			return "", false
		}
	}
	return clean, true
}

// hasDriveLetter detects a Windows drive-absolute path (e.g. "C:\\evil").
func hasDriveLetter(n string) bool {
	return len(n) >= 2 && n[1] == ':' &&
		((n[0] >= 'A' && n[0] <= 'Z') || (n[0] >= 'a' && n[0] <= 'z'))
}

// decompressedName strips a single compression extension from a bare
// compressed filename (report.pdf.gz -> report.pdf). Falls back to a generic
// name when the input has no recognizable compression suffix.
func decompressedName(filename string) string {
	base := path.Base(strings.ReplaceAll(filename, "\\", "/"))
	for _, ext := range []string{".gz", ".bz2", ".xz", ".zst", ".lz4", ".br", ".lz", ".sz"} {
		if strings.HasSuffix(strings.ToLower(base), ext) {
			return base[:len(base)-len(ext)]
		}
	}
	if base == "" || base == "." || base == "/" {
		return "decompressed"
	}
	return base
}
