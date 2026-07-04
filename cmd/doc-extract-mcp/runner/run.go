// Package runner spawns the hardened, no-network doc-extract sandbox and reads
// back the converter's Result. It is the bridge-side half of the doc-extract
// capability: the substrate's coder spine handles long-lived coding sandboxes,
// while this runs a ONE-SHOT extraction container (the cleaner shape for a
// deterministic converter — docker run --rm, bytes on stdin, JSON on stdout).
//
// The untrusted-input hardening delta (proposal §4) lives here: read-only
// rootfs + tmpfs + nofile cap on top of the coder spine's cap-drop / no-new-
// privileges / resource caps, and --network=none is ALWAYS on (the keystone —
// the file is parsed with zero egress). gVisor (--runtime=runsc) is a config
// toggle added later once a local host confirms runsc.
package runner

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"strconv"
	"time"

	"github.com/cpuchip/pg-ai-stewards/internal/docextract"
)

// Runner holds the spawn configuration (image, caps, clamav volume).
type Runner struct {
	Image     string        // DOC_EXTRACT_IMAGE (default doc-extract:latest)
	ClamAVVol string        // DOC_EXTRACT_CLAMAV_VOLUME (default clamav-db; "" = no signature scan)
	MemLimit  string        // --memory (default 2g)
	CPULimit  string        // --cpus (default 2)
	PidsLimit string        // --pids-limit (default 512)
	NoFile    string        // --ulimit nofile (default 4096)
	Timeout   time.Duration // overall container timeout (default 180s)
}

// New returns a Runner with the ratified hardened defaults, overridable by env.
func New() *Runner {
	img := os.Getenv("DOC_EXTRACT_IMAGE")
	if img == "" {
		img = "doc-extract:latest"
	}
	vol, set := os.LookupEnv("DOC_EXTRACT_CLAMAV_VOLUME")
	if !set {
		vol = "clamav-db" // the freshclam-populated volume (compose overlay)
	}
	return &Runner{
		Image: img, ClamAVVol: vol,
		MemLimit: "2g", CPULimit: "2", PidsLimit: "512", NoFile: "4096",
		Timeout: 180 * time.Second,
	}
}

// ExtractArgs mirror the converter's flags for one run.
type ExtractArgs struct {
	Filename      string
	Render        bool // FORCE the pixel overlay (every page up to MaxPages)
	AutoRender    bool // router default: render only a SHORT doc (<= MaxPages)
	MaxPages      int
	DPI           int
	Caps          docextract.ArchiveCaps
	RecurseNested bool
	// TimeoutSecs raises BOTH the converter (-timeout) and the container ctx for
	// this run — the bulk-import / big-archive path legitimately runs minutes
	// (RC-3). 0 = the converter default + r.Timeout. A fast single file finishes
	// early regardless, so a high value here is a ceiling, not a floor.
	TimeoutSecs int

	// MaxImages / ImageBudgetSecs tune the wiki-assets embedded-image pass
	// (0 = the converter's own defaults — 40 images / 60s, tuned for an
	// interactive chat upload). assets-backfill passes a larger budget since
	// it is a deliberate one-shot sweep, not a request the user is waiting on.
	MaxImages       int
	ImageBudgetSecs int
}

// Extract spawns the hardened container, pipes data to its stdin, and decodes
// the converter's Result from stdout. The original bytes never leave this
// process except into the sealed, no-network container. Returns the Result and
// the container's stderr (diagnostics) — a non-empty stderr is normal (logs).
func (r *Runner) Extract(ctx context.Context, data []byte, a ExtractArgs) (docextract.Result, string, error) {
	// Container ctx: the default r.Timeout, or — for a long bulk run — a window a
	// little larger than the converter's own deadline (so the converter reports
	// its timeout cleanly instead of being SIGKILL'd by docker).
	containerTimeout := r.Timeout
	if a.TimeoutSecs > 0 {
		if d := time.Duration(a.TimeoutSecs+30) * time.Second; d > containerTimeout {
			containerTimeout = d
		}
	}
	if containerTimeout > 0 {
		var cancel context.CancelFunc
		ctx, cancel = context.WithTimeout(ctx, containerTimeout)
		defer cancel()
	}

	args := []string{
		"run", "--rm", "-i",
		// --- the untrusted-input hardening (proposal §4) ---
		"--network=none", // the keystone: parse with zero egress
		"--cap-drop=ALL",
		"--security-opt=no-new-privileges",
		"--read-only",      // read-only rootfs
		"--tmpfs", "/work", // writable scratch (tabula/poppler temp files)
		"--tmpfs", "/tmp",
		"--pids-limit=" + r.PidsLimit,
		"--memory=" + r.MemLimit,
		"--cpus=" + r.CPULimit,
		"--ulimit", "nofile=" + r.NoFile,
		"--label=stewards.doc_extract=1",
	}
	// Mount the freshclam-populated signature DB read-only and point the
	// converter at it. An empty/absent volume just degrades to structural-only.
	if r.ClamAVVol != "" {
		args = append(args,
			"-v", r.ClamAVVol+":/clamav:ro",
			"-e", "DOC_EXTRACT_CLAMAV_DB=/clamav")
	}
	args = append(args, r.Image)

	// Converter flags (the image ENTRYPOINT is the doc-extract binary).
	args = append(args, "-filename", a.Filename)
	if a.Render {
		args = append(args, "-render") // force every page
	}
	// -auto-render defaults true in the converter; pass it explicitly so the
	// caller controls the router behavior deterministically.
	args = append(args, "-auto-render="+strconv.FormatBool(a.AutoRender))
	if a.TimeoutSecs > 0 {
		args = append(args, "-timeout", strconv.Itoa(a.TimeoutSecs)) // RC-3: raise the converter's own deadline for a bulk run
	}
	if a.MaxPages > 0 {
		args = append(args, "-max-pages", strconv.Itoa(a.MaxPages))
	}
	if a.DPI > 0 {
		args = append(args, "-dpi", strconv.Itoa(a.DPI))
	}
	if r.ClamAVVol != "" {
		args = append(args, "-clamav-db", "/clamav")
	}
	if a.Caps.MaxTotalUncompressed > 0 {
		args = append(args, "-max-total", strconv.FormatInt(a.Caps.MaxTotalUncompressed, 10))
	}
	if a.Caps.MaxEntrySize > 0 {
		args = append(args, "-max-entry", strconv.FormatInt(a.Caps.MaxEntrySize, 10))
	}
	if a.Caps.MaxEntries > 0 {
		args = append(args, "-max-entries", strconv.Itoa(a.Caps.MaxEntries))
	}
	if a.Caps.MaxRatio > 0 {
		args = append(args, "-max-ratio", strconv.Itoa(a.Caps.MaxRatio))
	}
	if a.RecurseNested {
		args = append(args, "-recurse-nested")
	}
	if a.MaxImages > 0 {
		args = append(args, "-max-images", strconv.Itoa(a.MaxImages))
	}
	if a.ImageBudgetSecs > 0 {
		args = append(args, "-image-budget-secs", strconv.Itoa(a.ImageBudgetSecs))
	}

	cmd := exec.CommandContext(ctx, "docker", args...)
	cmd.Stdin = bytes.NewReader(data)
	var stdout, stderr bytes.Buffer
	cmd.Stdout = &stdout
	cmd.Stderr = &stderr
	runErr := cmd.Run()
	if runErr != nil {
		return docextract.Result{}, stderr.String(),
			fmt.Errorf("doc-extract container: %w\nstderr: %s", runErr, stderr.String())
	}

	var res docextract.Result
	if err := json.Unmarshal(stdout.Bytes(), &res); err != nil {
		return docextract.Result{}, stderr.String(),
			fmt.Errorf("decode converter result: %w\nstdout(%d bytes): %.500s",
				err, stdout.Len(), stdout.String())
	}
	return res, stderr.String(), nil
}
