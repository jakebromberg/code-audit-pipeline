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
	"syscall"
	"time"

	"github.com/jakebromberg/code-audit-pipeline/internal/manifest"
)

// EnsureExtractorLockTimeout governs how long EnsureExtractor will wait to
// acquire the per-extractor lock before giving up. Tests can override via
// the local hook below.
const EnsureExtractorLockTimeout = 60 * time.Second

// ensureExtractor is the indirection seam used by Extract to call into
// EnsureExtractor. Tests of the tier-gating logic (19, 19a, 19b) install a
// spy here without exercising the real per-extractor flock + state.json
// machinery, which is covered separately by bootstrap_test.go.
var ensureExtractor = EnsureExtractor

// EnsureExtractor lays down the named extractor's source under
// extractorsRoot and runs its [runtime].bootstrap argv, both gated on the
// staleness signals in state.json. Idempotent: if state.json says the
// extractor is current and on-disk content matches, returns nil with no I/O.
//
// Concurrency: a per-extractor flock at <extractorsRoot>/<name>/.audit-init/
// serialises callers; the second caller re-reads state.json inside the
// lock and observes the first caller's outcome (ok | failed).
//
// Failure mode: bootstrap-execution failures persist as
// BootstrapStatus=failed with LastError in state.json *before* releasing
// the lock — the next call sees the failure and retries.
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

	state, err := loadState(auditDest)
	if err != nil {
		return fmt.Errorf("EnsureExtractor: load state: %w", err)
	}
	if state == nil {
		state = &InitState{
			AuditVersion:   Version,
			SourceRepoRoot: "<embedded>",
			AppliedAt:      time.Now().UTC().Format(time.RFC3339),
			Files:          map[string]InitStateFile{},
		}
	}
	extState := state.Extractors[name]

	embeddedSHA, err := combinedSourceSHA(extSubFS)
	if err != nil {
		return fmt.Errorf("EnsureExtractor: combined sha: %w", err)
	}

	if extState.BootstrapStatus == BootstrapOK &&
		extState.SourceSHA == embeddedSHA &&
		onDiskMatchesState(state, name, extractorDir) {
		return nil
	}

	changed, err := layDownExtractor(ctx, name, extSubFS, extractorDir, auditDest, state, stdout)
	if err != nil {
		return fmt.Errorf("EnsureExtractor: lay down %s: %w", name, err)
	}

	manifestPath := filepath.Join(extractorDir, "manifest.toml")
	m, err := manifest.Parse(manifestPath)
	if err != nil {
		return fmt.Errorf("EnsureExtractor: parse manifest %s: %w", name, err)
	}

	needsBootstrap := changed || extState.BootstrapStatus != BootstrapOK
	if !needsBootstrap {
		return nil
	}

	now := time.Now().UTC()
	newExtState := ExtractorState{
		BootstrappedAt: &now,
		SourceSHA:      embeddedSHA,
	}
	var bootstrapErr error
	if len(m.Runtime.Bootstrap) == 0 {
		newExtState.BootstrapStatus = BootstrapNA
	} else if bootstrapErr = runBootstrap(ctx, extractorDir, m, stdout); bootstrapErr == nil {
		newExtState.BootstrapStatus = BootstrapOK
	} else {
		newExtState.BootstrapStatus = BootstrapFailed
		newExtState.LastError = bootstrapErr.Error()
		fmt.Fprintf(stdout, "code-audit: bootstrap %s: %v\n", name, bootstrapErr)
		if hint := strings.TrimSpace(m.Runtime.SetupHint); hint != "" {
			fmt.Fprintf(stdout, "code-audit: bootstrap %s hint: %s\n", name, hint)
		}
	}

	state.EnsureExtractorsMap()[name] = newExtState
	if err := saveState(auditDest, state); err != nil {
		return fmt.Errorf("EnsureExtractor: save state: %w", err)
	}
	return bootstrapErr
}

// layDownExtractor lays down the embedded extractor source under
// extractorDir, applying NEW/CLEAN/DIRTY semantics:
//   - NEW: copy in, record pristine SHA.
//   - CLEAN-and-current (dst == pristine == src): no-op.
//   - CLEAN-and-stale (dst == pristine != src): auto-upgrade silently.
//   - DIRTY (dst != pristine): warn on stderr; preserve the on-disk version.
//
// Returns changed=true if any file was written.
func layDownExtractor(
	ctx context.Context,
	name string,
	extSubFS fs.FS,
	extractorDir string,
	auditDest string,
	state *InitState,
	stdout io.Writer,
) (bool, error) {
	subtrees := []SubtreeSrc{
		{RelPath: "extractors/" + name, FS: extSubFS, Embedded: true},
	}
	plan, err := buildCopyPlan(ctx, subtrees, auditDest)
	if err != nil {
		return false, err
	}
	classified, err := classifyFiles(ctx, plan, auditDest, state)
	if err != nil {
		return false, err
	}

	changed := false
	for _, c := range classified {
		if err := ctx.Err(); err != nil {
			return changed, err
		}
		switch c.state {
		case stateNew:
			if err := copyFile(c.srcFS, c.srcRel, c.dstAbs, c.mode); err != nil {
				return changed, err
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
				return changed, err
			}
			state.Files[c.relDest] = InitStateFile{SHA256: c.srcSHA}
			changed = true
		case stateDirty:
			fmt.Fprintf(stdout, "code-audit: warning: %s locally modified; preserving on-disk version\n", c.relDest)
		}
	}
	return changed, nil
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
func acquireFlock(ctx context.Context, path string, timeout time.Duration) (*os.File, error) {
	fd, err := os.OpenFile(path, os.O_CREATE|os.O_RDWR, 0o600)
	if err != nil {
		return nil, fmt.Errorf("open lock %s: %w", path, err)
	}
	deadline := time.Now().Add(timeout)
	for {
		if err := syscall.Flock(int(fd.Fd()), syscall.LOCK_EX|syscall.LOCK_NB); err == nil {
			return fd, nil
		} else if !errors.Is(err, syscall.EWOULDBLOCK) {
			fd.Close()
			return nil, fmt.Errorf("flock %s: %w", path, err)
		}
		if ctx.Err() != nil {
			fd.Close()
			return nil, ctx.Err()
		}
		if time.Now().After(deadline) {
			fd.Close()
			return nil, fmt.Errorf("timeout waiting for lock %s after %v", path, timeout)
		}
		select {
		case <-ctx.Done():
			fd.Close()
			return nil, ctx.Err()
		case <-time.After(50 * time.Millisecond):
		}
	}
}

// releaseFlock unlocks and closes the lock file. Errors are best-effort:
// the file is being closed anyway, and the kernel releases the lock on
// process exit.
func releaseFlock(fd *os.File) {
	if fd == nil {
		return
	}
	_ = syscall.Flock(int(fd.Fd()), syscall.LOCK_UN)
	_ = fd.Close()
}
