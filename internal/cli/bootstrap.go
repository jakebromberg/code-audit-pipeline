package cli

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"

	"github.com/jakebromberg/code-audit-pipeline/internal/manifest"
)

// ErrUnsupportedPlatform is returned by the lock primitives on platforms
// that do not implement POSIX flock(2). The binary ships only for
// darwin/linux per .goreleaser.yaml; Windows builds compile but every
// call into the bootstrap lock pathway surfaces this error so callers
// degrade gracefully rather than crashing.
var ErrUnsupportedPlatform = errors.New("bootstrap lock unsupported on this platform")

// EnsureExtractorLockTimeout governs how long EnsureExtractor will wait to
// acquire the per-extractor lock before giving up. Tests can override via
// the local hook below.
const EnsureExtractorLockTimeout = 60 * time.Second

// ensureExtractor is the indirection seam used by Extract to call into
// EnsureExtractor. Tests of the tier-gating logic (19, 19a, 19b) install a
// spy here without exercising the real per-extractor flock + state.json
// machinery, which is covered separately by bootstrap_test.go.
var ensureExtractor = EnsureExtractor

// stateLockName is the basename of the audit-home-level state.json mutex.
// Held briefly across load+merge+save so concurrent EnsureExtractor calls
// for DIFFERENT extractors don't clobber each other's state.json entries
// — the per-extractor flock only serialises callers targeting the same
// name. Init() acquires the same lock for the duration of its run.
const stateLockName = "state.lock"

// EnsureExtractor lays down the named extractor's source under
// extractorsRoot and runs its [runtime].bootstrap argv, both gated on the
// staleness signals in state.json. Idempotent: if state.json says the
// extractor is current and on-disk content matches, returns nil with no I/O.
//
// Concurrency: two layers.
//   - Per-extractor flock at <extractorsRoot>/<name>/.audit-init/lock
//     serialises callers targeting the same extractor.
//   - Audit-home state.json flock at <auditDest>/.audit-init/state.lock
//     serialises read/modify/write of the shared state.json across
//     callers targeting DIFFERENT extractors AND across concurrent
//     `code-audit init` invocations. Held briefly only — not during the
//     slow bootstrap step.
//
// Failure mode: bootstrap-execution failures persist as
// BootstrapStatus=failed with LastError in state.json — the next call
// sees the failure and retries. ctx cancellation does NOT persist a
// failed status (avoiding bogus "context canceled" entries — mirrors the
// guard in bootstrapTouchedExtractors).
func EnsureExtractor(
	ctx context.Context,
	name string,
	extractorsRoot string,
	auditDest string,
	embeddedExtractorsFS fs.FS,
	stdout io.Writer,
) error {
	if embeddedExtractorsFS == nil {
		return errors.New("EnsureExtractor: nil embeddedExtractorsFS")
	}
	if _, err := fs.Stat(embeddedExtractorsFS, name); err != nil {
		return fmt.Errorf("EnsureExtractor: extractor %q not embedded: %w", name, err)
	}
	extSubFS, err := fs.Sub(embeddedExtractorsFS, name)
	if err != nil {
		return fmt.Errorf("EnsureExtractor: fs.Sub %s: %w", name, err)
	}

	// Parse the embedded manifest BEFORE any on-disk mutation. A
	// malformed embedded manifest is a binary-build error, not a runtime
	// failure to surface as bootstrap_status=failed; bailing here also
	// avoids leaving layDown's state.Files mutations stranded with no
	// corresponding saveState.
	mData, err := fs.ReadFile(extSubFS, "manifest.toml")
	if err != nil {
		return fmt.Errorf("EnsureExtractor: read embedded manifest %s: %w", name, err)
	}
	m, err := manifest.ParseBytes("embedded extractors/"+name+"/manifest.toml", mData)
	if err != nil {
		return fmt.Errorf("EnsureExtractor: parse embedded manifest %s: %w", name, err)
	}

	extractorDir := filepath.Join(extractorsRoot, name)
	lockDir := filepath.Join(extractorDir, ".audit-init")
	if err := os.MkdirAll(lockDir, 0o755); err != nil {
		return fmt.Errorf("EnsureExtractor: mkdir %s: %w", lockDir, err)
	}
	lockPath := filepath.Join(lockDir, "lock")
	lockFD, err := acquireFlock(ctx, lockPath, EnsureExtractorLockTimeout)
	if err != nil {
		return fmt.Errorf("EnsureExtractor %s: %w", name, err)
	}
	defer releaseFlock(lockFD)

	// Initial snapshot read of state.json, briefly under the state lock.
	state, err := readStateLocked(ctx, auditDest)
	if err != nil {
		return fmt.Errorf("EnsureExtractor: read state: %w", err)
	}
	extState := state.Extractors[name]

	embeddedSHA, err := combinedSourceSHA(extSubFS)
	if err != nil {
		return fmt.Errorf("EnsureExtractor: combined sha: %w", err)
	}

	// Fast path: state says we're current and on-disk content agrees.
	if extState.BootstrapStatus == BootstrapOK &&
		extState.SourceSHA == embeddedSHA &&
		onDiskMatchesState(state, name, extractorDir) {
		return nil
	}

	// Slow path: lay down source, optionally bootstrap. layDownExtractor
	// mutates `state.Files` in-memory; we'll merge those mutations into
	// a fresh re-read of state.json before saving.
	changed, currentFiles, err := layDownExtractor(ctx, name, extSubFS, extractorDir, auditDest, state, stdout)
	if err != nil {
		return fmt.Errorf("EnsureExtractor: lay down %s: %w", name, err)
	}

	needsBootstrap := changed || extState.BootstrapStatus != BootstrapOK
	if !needsBootstrap {
		return nil
	}

	now := time.Now().UTC()
	newExtState := ExtractorState{BootstrappedAt: &now}
	var bootstrapErr error
	if len(m.Runtime.Bootstrap) == 0 {
		newExtState.BootstrapStatus = BootstrapNA
		newExtState.SourceSHA = embeddedSHA // safe — no runtime risk to record
	} else if bootstrapErr = runBootstrap(ctx, extractorDir, m, stdout); bootstrapErr == nil {
		newExtState.BootstrapStatus = BootstrapOK
		newExtState.SourceSHA = embeddedSHA // success only — see ExtractorState doc
	} else {
		newExtState.BootstrapStatus = BootstrapFailed
		newExtState.LastError = bootstrapErr.Error()
		fmt.Fprintf(stdout, "code-audit: bootstrap %s: %v\n", name, bootstrapErr)
		if hint := strings.TrimSpace(m.Runtime.SetupHint); hint != "" {
			fmt.Fprintf(stdout, "code-audit: bootstrap %s hint: %s\n", name, hint)
		}
	}

	// Don't persist a context-canceled failure (mirrors bootstrapTouchedExtractors).
	if bootstrapErr != nil && (errors.Is(bootstrapErr, context.Canceled) ||
		errors.Is(bootstrapErr, context.DeadlineExceeded) || ctx.Err() != nil) {
		return bootstrapErr
	}

	// Re-acquire the state.json lock briefly to merge & save. Re-reading
	// state.json inside the lock prevents the slow-path window between
	// our initial snapshot read and this save from clobbering a
	// concurrent extractor's state.Extractors entry.
	if err := writeStateLocked(ctx, auditDest, name, newExtState, state.Files, currentFiles); err != nil {
		return fmt.Errorf("EnsureExtractor: save state: %w", err)
	}
	return bootstrapErr
}

// readStateLocked acquires the audit-home state.json lock briefly, reads
// state.json, and returns the loaded state. Caller looks up its own
// per-extractor entry via state.Extractors[name]. Releases the lock
// before returning so callers don't hold it across slow lay-down /
// bootstrap phases.
func readStateLocked(ctx context.Context, auditDest string) (*InitState, error) {
	stateLockDir := filepath.Join(auditDest, ".audit-init")
	if err := os.MkdirAll(stateLockDir, 0o755); err != nil {
		return nil, fmt.Errorf("mkdir state lock dir: %w", err)
	}
	fd, err := acquireFlock(ctx, filepath.Join(stateLockDir, stateLockName), EnsureExtractorLockTimeout)
	if err != nil {
		return nil, fmt.Errorf("acquire state lock: %w", err)
	}
	defer releaseFlock(fd)

	state, err := loadState(auditDest)
	if err != nil {
		return nil, err
	}
	if state == nil {
		state = &InitState{
			AuditVersion:   Version,
			SourceRepoRoot: "<embedded>",
			AppliedAt:      time.Now().UTC().Format(time.RFC3339),
			Files:          map[string]InitStateFile{},
		}
	}
	return state, nil
}

// writeStateLocked acquires the audit-home state.json lock, re-reads
// state.json fresh inside the lock, merges OUR per-extractor entry
// (extState) and OUR state.Files mutations (the entries in `localFiles`
// whose keys appear in `currentPlan`), prunes any state.Files entries
// under `extractors/<name>/` that fall outside `currentPlan` (handles
// files deleted from the embedded source between binary versions), and
// writes the merged state. Held only for the duration of the I/O.
func writeStateLocked(
	ctx context.Context,
	auditDest string,
	name string,
	extState ExtractorState,
	localFiles map[string]InitStateFile,
	currentPlan map[string]bool,
) error {
	stateLockDir := filepath.Join(auditDest, ".audit-init")
	if err := os.MkdirAll(stateLockDir, 0o755); err != nil {
		return fmt.Errorf("mkdir state lock dir: %w", err)
	}
	fd, err := acquireFlock(ctx, filepath.Join(stateLockDir, stateLockName), EnsureExtractorLockTimeout)
	if err != nil {
		return fmt.Errorf("acquire state lock: %w", err)
	}
	defer releaseFlock(fd)

	fresh, err := loadState(auditDest)
	if err != nil {
		return err
	}
	if fresh == nil {
		fresh = &InitState{
			AuditVersion:   Version,
			SourceRepoRoot: "<embedded>",
			AppliedAt:      time.Now().UTC().Format(time.RFC3339),
			Files:          map[string]InitStateFile{},
		}
	}
	if fresh.Files == nil {
		fresh.Files = map[string]InitStateFile{}
	}

	prefix := "extractors/" + name + "/"
	// Prune fresh.Files entries under our prefix that aren't in the
	// current plan (file was removed from the source).
	for k := range fresh.Files {
		if strings.HasPrefix(k, prefix) && !currentPlan[k] {
			delete(fresh.Files, k)
		}
	}
	// Copy our localFiles entries (only those under our prefix; we don't
	// touch other extractors' Files entries even if localFiles somehow
	// contained them).
	for k, v := range localFiles {
		if strings.HasPrefix(k, prefix) {
			fresh.Files[k] = v
		}
	}
	fresh.EnsureExtractorsMap()[name] = extState
	return saveState(auditDest, fresh)
}

// layDownExtractor lays down the embedded extractor source under
// extractorDir, applying NEW/CLEAN/DIRTY semantics:
//   - NEW: copy in, record pristine SHA.
//   - CLEAN-and-current (dst == pristine == src): no-op.
//   - CLEAN-and-stale (dst == pristine != src): auto-upgrade silently.
//   - DIRTY (dst != pristine): warn on stderr; preserve the on-disk version.
//
// Returns changed=true if any file was written, plus the set of relDest
// keys in the current plan (used by writeStateLocked to prune stale
// state.Files entries for files removed from the embedded source).
func layDownExtractor(
	ctx context.Context,
	name string,
	extSubFS fs.FS,
	extractorDir string,
	auditDest string,
	state *InitState,
	stdout io.Writer,
) (bool, map[string]bool, error) {
	subtrees := []SubtreeSrc{
		{RelPath: "extractors/" + name, FS: extSubFS, Embedded: true},
	}
	plan, err := buildCopyPlan(ctx, subtrees, auditDest)
	if err != nil {
		return false, nil, err
	}
	classified, err := classifyFiles(ctx, plan, auditDest, state)
	if err != nil {
		return false, nil, err
	}

	currentPlan := make(map[string]bool, len(classified))
	changed := false
	for _, c := range classified {
		if err := ctx.Err(); err != nil {
			return changed, currentPlan, err
		}
		currentPlan[c.relDest] = true
		switch c.state {
		case stateNew:
			if err := copyFile(c.srcFS, c.srcRel, c.dstAbs, c.mode); err != nil {
				return changed, currentPlan, err
			}
			state.Files[c.relDest] = InitStateFile{SHA256: c.srcSHA}
			changed = true
		case stateClean:
			pristine, ok := state.Files[c.relDest]
			if ok && pristine.SHA256 == c.srcSHA {
				// dst == pristine == src — nothing to do.
				continue
			}
			// CLEAN-and-stale: auto-upgrade silently.
			if err := copyFile(c.srcFS, c.srcRel, c.dstAbs, c.mode); err != nil {
				return changed, currentPlan, err
			}
			state.Files[c.relDest] = InitStateFile{SHA256: c.srcSHA}
			changed = true
		case stateDirty:
			fmt.Fprintf(stdout, "code-audit: warning: %s locally modified; preserving on-disk version\n", c.relDest)
		}
	}
	return changed, currentPlan, nil
}

// combinedSourceSHA returns a deterministic hash over every regular file in
// srcFS: the SHA combines forward-slash path + content SHA, sorted by path.
// Used as the "did the embedded source move?" signal in EnsureExtractor.
func combinedSourceSHA(srcFS fs.FS) (string, error) {
	type entry struct {
		path string
		sha  string
	}
	var entries []entry
	err := fs.WalkDir(srcFS, ".", func(rel string, d fs.DirEntry, walkErr error) error {
		if walkErr != nil {
			return walkErr
		}
		if rel == "." || d.IsDir() {
			return nil
		}
		if d.Type()&fs.ModeSymlink != 0 {
			return nil
		}
		sha, err := sha256FS(srcFS, rel)
		if err != nil {
			return err
		}
		entries = append(entries, entry{rel, sha})
		return nil
	})
	if err != nil {
		return "", err
	}
	sort.Slice(entries, func(i, j int) bool { return entries[i].path < entries[j].path })
	h := sha256.New()
	for _, e := range entries {
		io.WriteString(h, e.path)
		io.WriteString(h, ":")
		io.WriteString(h, e.sha)
		io.WriteString(h, "\n")
	}
	return hex.EncodeToString(h.Sum(nil)), nil
}

// onDiskMatchesState reports whether every state-tracked file under
// extractors/<name>/ on disk hashes to its recorded pristine SHA. A single
// mismatch (or read error) is enough to return false — EnsureExtractor
// then re-lays the extractor source.
func onDiskMatchesState(state *InitState, name, extractorDir string) bool {
	prefix := "extractors/" + name + "/"
	for rel, st := range state.Files {
		if !strings.HasPrefix(rel, prefix) {
			continue
		}
		relSub := strings.TrimPrefix(rel, prefix)
		diskPath := filepath.Join(extractorDir, filepath.FromSlash(relSub))
		sha, err := sha256File(diskPath)
		if err != nil {
			return false
		}
		if sha != st.SHA256 {
			return false
		}
	}
	return true
}

// acquireFlock takes an exclusive POSIX advisory lock on path. The caller
// owns the returned *os.File and must releaseFlock it when done. The
// context aborts the wait via ctx.Done(); a timeout shorter than the
// context's deadline still applies.
//
// Concrete implementations live in bootstrap_lock_unix.go (real flock)
// and bootstrap_lock_windows.go (stub returning ErrUnsupportedPlatform)
// so the package compiles on Windows even though the binary only ships
// on darwin/linux.

// releaseFlock unlocks and closes the lock file. Errors are best-effort:
// the file is being closed anyway, and the kernel releases the lock on
// process exit. See bootstrap_lock_{unix,windows}.go for the concrete
// implementations.
