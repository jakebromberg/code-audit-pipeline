package cli

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"io/fs"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"time"

	"github.com/jakebromberg/code-audit-pipeline/internal/initstate"
	"github.com/jakebromberg/code-audit-pipeline/internal/manifest"
)

// initSubdirs is the list of source subdirectories `code-audit init` copies
// into the destination. Per ADR-0006, queries get bundled into the binary
// too, but init still lays them down on disk so contributors can edit and
// re-run without rebuilding. The same set is used for both filesystem
// (--from <checkout>) and embedded sources.
var initSubdirs = []string{"extractors", "pipeline/queries"}

// SubtreeSrc names one of the initSubdirs and the fs.FS rooted at that
// subtree. Init() composes a slice of these — one per initSubdir — from
// either os.DirFS(--from/<sub>) or the binary's embedded source.
type SubtreeSrc struct {
	// RelPath is the destination-relative subdirectory the subtree maps to
	// (e.g. "extractors" or "pipeline/queries"). Matches initSubdirs.
	RelPath string
	// FS is the fs.FS rooted at the subtree. fs.WalkDir(FS, ".", ...) yields
	// the entries to consider for copying. For --from, this is
	// os.DirFS(filepath.Join(src, RelPath)); for the brew flow, this is
	// embeddedExtractors() or embeddedQueries() (or equivalent).
	FS fs.FS
	// Embedded is true when FS is backed by //go:embed (mode bits are
	// 0o444 across the board, so the executable bit is inferred from a
	// `#!` shebang in the file's first two bytes).
	Embedded bool
}

// initSkipDirs holds a fresh per-package copy of the canonical skip set so
// mutations cannot bleed back into the initstate-shared source. A drift
// guard test in internal/genembed asserts the //go:generate -skip CSV
// matches initstate.SkipDirs().
var initSkipDirs = initstate.SkipDirs()

// stateFile records each copied file's pristine sha256 so subsequent
// invocations can distinguish locally-modified files from clean upgrades.
const stateFile = ".audit-init/state.json"

// InitState is the on-disk shape of stateFile.
type InitState struct {
	AuditVersion    string                   `json:"audit_version"`
	SourceRepoRoot  string                   `json:"source_repo_root"`
	SourceCommitSHA string                   `json:"source_commit_sha,omitempty"`
	AppliedAt       string                   `json:"applied_at"`
	Files           map[string]InitStateFile `json:"files"`
	// Extractors is the per-extractor bootstrap-tracking map. May be nil
	// when state.json was written by a binary older than the per-extractor
	// tracking change; use EnsureExtractorsMap on any write path.
	Extractors map[string]ExtractorState `json:"extractors,omitempty"`
}

type InitStateFile struct {
	SHA256 string `json:"sha256"`
}

// ExtractorState is the per-extractor record in state.json. BootstrapStatus
// transitions: pending → ok | failed | n-a. The Extract command treats nil
// or absent entries as pending.
//
// BootstrappedAt is a pointer so json `omitempty` correctly omits unset
// entries — Go's encoding/json never elides a zero struct value, and
// time.Time is a struct, so the value form would persist "0001-01-01T00..."
// for every entry that never ran bootstrap.
//
// SourceSHA is reserved for a future change that records a combined hash
// of the extractor source at last successful bootstrap; it is unpopulated
// in this PR and consulted only by code that lands later. The field is
// declared now to commit the schema shape so backward-compat tests can
// pin it.
type ExtractorState struct {
	BootstrapStatus string     `json:"bootstrap_status"` // ok|failed|pending|n-a
	BootstrappedAt  *time.Time `json:"bootstrapped_at,omitempty"`
	SourceSHA       string     `json:"source_sha,omitempty"`
	LastError       string     `json:"last_error,omitempty"`
}

// EnsureExtractorsMap returns the Extractors map, initialising it if nil.
// All write paths must go through this helper to avoid nil-map panics on
// state loaded from older binaries that omitted the field.
func (s *InitState) EnsureExtractorsMap() map[string]ExtractorState {
	if s.Extractors == nil {
		s.Extractors = map[string]ExtractorState{}
	}
	return s.Extractors
}

// Bootstrap status constants. Values stored in state.json; do not change
// without a migration plan.
//
// BootstrapPending is a *render-time* concept rather than a written
// state: no production code path persists "pending" to disk. An entry
// that has never been seen by EnsureExtractor has the zero-value empty
// string for BootstrapStatus, and the status renderer treats that as
// pending. The constant is kept so tests and explicit constructions can
// reference the canonical label without hard-coding the literal, and so
// a future change that wants to record an in-flight bootstrap before
// blocking on a long install can write it without minting a new value.
const (
	BootstrapPending = "pending"
	BootstrapOK      = "ok"
	BootstrapFailed  = "failed"
	BootstrapNA      = "n-a"
)

// Init implements `code-audit init`. The embedded slice supplies the brew
// flow's source (one SubtreeSrc per initSubdir). When --from is given, the
// filesystem source supersedes embedded; pass nil for embedded in test
// contexts where --from is always provided.
func Init(ctx context.Context, argv []string, stdout io.Writer, embedded []SubtreeSrc) int {
	fset := flag.NewFlagSet("init", flag.ContinueOnError)
	destFlag := fset.String("dest", "", "destination (default: $XDG_CONFIG_HOME/audit or ~/.config/audit)")
	fromFlag := fset.String("from", "", "source: a local checked-out code-audit-pipeline repo (defaults to embedded)")
	upgrade := fset.Bool("upgrade", false, "refresh dest from source even when files exist; warns about local mods")
	force := fset.Bool("force", false, "overwrite locally-modified files without prompting (implies --upgrade)")
	dryRun := fset.Bool("dry-run", false, "print what would copy without writing")
	if err := fset.Parse(argv); err != nil {
		return 2
	}
	if *force {
		*upgrade = true
	}

	var (
		subtrees []SubtreeSrc
		src      string // filesystem absolute path; "" for embedded source
	)
	if *fromFlag != "" {
		abs, err := filepath.Abs(*fromFlag)
		if err != nil {
			fmt.Fprintf(stdout, "code-audit init: --from path: %v\n", err)
			return 2
		}
		src = abs
		if err := validateSource(src); err != nil {
			fmt.Fprintf(stdout, "code-audit init: %v\n", err)
			return 2
		}
		for _, sub := range initSubdirs {
			subtrees = append(subtrees, SubtreeSrc{
				RelPath: sub,
				FS:      os.DirFS(filepath.Join(src, sub)),
			})
		}
	} else {
		if len(embedded) == 0 {
			fmt.Fprintln(stdout, "code-audit init: no embedded source available; pass --from <checkout>")
			return 2
		}
		subtrees = embedded
	}

	dest := *destFlag
	if dest == "" {
		dest = defaultDest()
		if dest == "" {
			fmt.Fprintln(stdout, "code-audit init: cannot resolve default destination; pass --dest")
			return 2
		}
	}
	destAbs, err := filepath.Abs(dest)
	if err != nil {
		fmt.Fprintf(stdout, "code-audit init: dest path: %v\n", err)
		return 2
	}
	if src != "" {
		if err := refuseSymlinkLoop(src, destAbs); err != nil {
			fmt.Fprintf(stdout, "code-audit init: %v\n", err)
			return 2
		}
	}

	// Acquire the audit-home state.json lock for the full Init run so we
	// serialise against concurrent `code-audit extract` (which holds the
	// same lock briefly around its read/modify/write). Init holds the
	// lock for longer because the full lay-down + bootstrap pass mutates
	// state in-place; concurrent extract callers wait. For the brew
	// one-shot flow this is acceptable. Skipped in --dry-run since no
	// state.json write happens.
	if !*dryRun {
		stateLockDir := filepath.Join(destAbs, ".audit-init")
		if err := os.MkdirAll(stateLockDir, 0o755); err != nil {
			fmt.Fprintf(stdout, "code-audit init: mkdir state lock dir: %v\n", err)
			return 1
		}
		stateFD, err := acquireFlock(ctx, filepath.Join(stateLockDir, stateLockName), EnsureExtractorLockTimeout)
		if err != nil {
			fmt.Fprintf(stdout, "code-audit init: acquire state lock: %v\n", err)
			return 1
		}
		defer releaseFlock(stateFD)
	}

	prior, _ := loadState(destAbs) // missing-OK: every file then classifies NEW

	plan, err := buildCopyPlan(ctx, subtrees, destAbs)
	if err != nil {
		if errors.Is(err, context.Canceled) || errors.Is(err, context.DeadlineExceeded) {
			fmt.Fprintln(stdout, "code-audit init: cancelled")
			return 130
		}
		fmt.Fprintf(stdout, "code-audit init: build plan: %v\n", err)
		return 2
	}
	// An empty plan from embedded source signals a misbuilt binary (e.g.
	// `//go:embed extractors` matched a renamed or empty subdir). Old
	// --from path was protected by validateSource; the embedded path
	// lacks an analog, so detect it here. For filesystem source we keep
	// the lenient behaviour — an empty --from tree could be a legitimate
	// edge case during testing.
	if len(plan) == 0 && src == "" {
		fmt.Fprintln(stdout, "code-audit init: embedded source is empty (binary may be misbuilt — check //go:embed directives)")
		return 1
	}

	classified, err := classifyFiles(ctx, plan, destAbs, prior)
	if err != nil {
		if errors.Is(err, context.Canceled) || errors.Is(err, context.DeadlineExceeded) {
			fmt.Fprintln(stdout, "code-audit init: cancelled")
			return 130
		}
		fmt.Fprintf(stdout, "code-audit init: classify: %v\n", err)
		return 2
	}

	var (
		copiedNew    int
		upgraded     int
		skippedDirty int
		newState     = InitState{
			AuditVersion:    Version,
			SourceRepoRoot:  sourceRepoRootLabel(src),
			SourceCommitSHA: gitHeadSHA(src),
			AppliedAt:       time.Now().UTC().Format(time.RFC3339),
			Files:           map[string]InitStateFile{},
		}
		dirtyExit              bool
		extractorTouched       = map[string]bool{}
		extractorsInSource     = map[string]bool{}
		extractorDirtyManifest = map[string]bool{}
	)

	for _, c := range classified {
		if err := ctx.Err(); err != nil {
			fmt.Fprintln(stdout, "code-audit init: cancelled")
			return 130
		}
		noteExtractorName(c.relDest, extractorsInSource)
		switch c.state {
		case stateNew:
			if !*dryRun {
				if err := copyFile(c.srcFS, c.srcRel, c.dstAbs, c.mode); err != nil {
					fmt.Fprintf(stdout, "code-audit init: copy %s: %v\n", c.relDest, err)
					return 1
				}
			}
			newState.Files[c.relDest] = InitStateFile{SHA256: c.srcSHA}
			copiedNew++
			noteExtractorTouched(c.relDest, extractorTouched)
			if *dryRun {
				fmt.Fprintf(stdout, "would copy NEW %s\n", c.relDest)
			}
		case stateClean:
			if *upgrade {
				if !*dryRun {
					if err := copyFile(c.srcFS, c.srcRel, c.dstAbs, c.mode); err != nil {
						fmt.Fprintf(stdout, "code-audit init: copy %s: %v\n", c.relDest, err)
						return 1
					}
				}
				upgraded++
				noteExtractorTouched(c.relDest, extractorTouched)
				if *dryRun {
					fmt.Fprintf(stdout, "would upgrade CLEAN %s\n", c.relDest)
				}
			}
			newState.Files[c.relDest] = InitStateFile{SHA256: c.srcSHA}
		case stateDirty:
			if *force {
				if !*dryRun {
					if err := copyFile(c.srcFS, c.srcRel, c.dstAbs, c.mode); err != nil {
						fmt.Fprintf(stdout, "code-audit init: copy %s: %v\n", c.relDest, err)
						return 1
					}
				}
				upgraded++
				noteExtractorTouched(c.relDest, extractorTouched)
				if *dryRun {
					fmt.Fprintf(stdout, "would overwrite DIRTY %s\n", c.relDest)
				}
				newState.Files[c.relDest] = InitStateFile{SHA256: c.srcSHA}
			} else {
				skippedDirty++
				dirtyExit = true
				fmt.Fprintf(stdout, "skip DIRTY %s (locally modified; use --force to overwrite)\n", c.relDest)
				// A DIRTY extractor manifest.toml (i.e. the file at
				// extractors/<name>/manifest.toml exactly — NOT a nested
				// fixture like extractors/<name>/fixtures/.../manifest.toml)
				// means the on-disk extractor declaration is user-edited.
				// Running bootstrap against it would honor argv the user
				// didn't authorise; flag the extractor so the bootstrap
				// pass skips it.
				if name, ok := extractorManifestName(c.relDest); ok {
					extractorDirtyManifest[name] = true
				}
				// Keep the prior state entry so subsequent re-runs still
				// classify this file as DIRTY against its original
				// pristine sha. Re-recording the destination's current sha
				// would mask the local modification on the next pass.
				if prior != nil {
					if e, ok := prior.Files[c.relDest]; ok {
						newState.Files[c.relDest] = e
					}
				}
			}
		}
	}

	// Carry over prior per-extractor state for extractors whose source
	// files still exist in this run. Pruning here keeps state.Extractors
	// from accumulating stale BootstrapOK entries for extractors that
	// were deleted from --from since the last init.
	if prior != nil && prior.Extractors != nil {
		for name, st := range prior.Extractors {
			if extractorsInSource[name] {
				newState.EnsureExtractorsMap()[name] = st
			}
		}
	}

	// Compute the set of extractors that need a bootstrap pass:
	//   touched     ∪  (prior failed && still in source)
	//   minus       dirty-manifest (cannot trust on-disk argv)
	// A prior failure deserves an automatic retry — without this, a
	// transient network failure during npm install would stick as
	// BootstrapFailed indefinitely until the user knew to pass --upgrade.
	extractorsToBootstrap := map[string]bool{}
	for n := range extractorTouched {
		extractorsToBootstrap[n] = true
	}
	if prior != nil {
		for n, st := range prior.Extractors {
			if extractorsInSource[n] && st.BootstrapStatus == BootstrapFailed {
				extractorsToBootstrap[n] = true
			}
		}
	}
	for n := range extractorDirtyManifest {
		if extractorsToBootstrap[n] {
			fmt.Fprintf(stdout, "init: bootstrap %s: SKIPPED — manifest.toml is locally modified (use --force to overwrite and re-bootstrap)\n", n)
			delete(extractorsToBootstrap, n)
		}
	}

	if !*dryRun {
		if err := bootstrapTouchedExtractors(ctx, destAbs, extractorsToBootstrap, &newState, stdout); err != nil {
			// ctx canceled — do NOT persist a partially-applied bootstrap
			// pass (would record bogus 'context canceled' failures for
			// every remaining extractor on subsequent reads).
			fmt.Fprintln(stdout, "code-audit init: cancelled during bootstrap")
			return 130
		}
		if err := saveState(destAbs, &newState); err != nil {
			fmt.Fprintf(stdout, "code-audit init: save state: %v\n", err)
			return 1
		}
	}

	fmt.Fprintf(stdout, "init: %d new, %d upgraded, %d skipped (dirty)\n", copiedNew, upgraded, skippedDirty)
	if dirtyExit {
		return 1
	}
	return 0
}

// fileState is the per-file classification result.
type fileState int

const (
	stateNew fileState = iota
	stateClean
	stateDirty
)

type fileClassification struct {
	srcFS    fs.FS  // fs rooted at the subtree containing this file
	srcRel   string // forward-slash path within srcFS, e.g. "typescript/manifest.toml"
	embedded bool   // true when srcFS is //go:embed-backed (mode bits non-authoritative)
	dstAbs   string
	relDest  string // forward-slash, joins-as-state-file-key (e.g. "extractors/typescript/manifest.toml")
	srcSHA   string
	state    fileState
	mode     os.FileMode // exec bit honored from src (filesystem) or shebang (embedded)
}

// validateSource confirms --from points at something that looks like a
// code-audit-pipeline checkout.
func validateSource(src string) error {
	info, err := os.Stat(src)
	if err != nil {
		return fmt.Errorf("--from %s: %w", src, err)
	}
	if !info.IsDir() {
		return fmt.Errorf("--from %s: not a directory", src)
	}
	for _, sub := range initSubdirs {
		p := filepath.Join(src, sub)
		if _, err := os.Stat(p); err != nil {
			return fmt.Errorf("--from %s: missing %s/", src, sub)
		}
	}
	return nil
}

// defaultDest returns $XDG_CONFIG_HOME/audit, falling back to
// ~/.config/audit. Returns "" only when HOME is unset.
func defaultDest() string {
	if x := os.Getenv("XDG_CONFIG_HOME"); x != "" {
		return filepath.Join(x, "audit")
	}
	home, err := os.UserHomeDir()
	if err != nil || home == "" {
		return ""
	}
	return filepath.Join(home, ".config", "audit")
}

// refuseSymlinkLoop guards two shapes of "copy into self":
//
//  1. dest is a symlink whose target is (or resolves into) src — the
//     developer setup where ~/.config/audit already points at a checkout.
//  2. src and dest, after symlink resolution, share a containment
//     relationship — either resolves inside the other. In that case walking
//     src and writing under dest will either produce file-onto-itself races
//     or pollute the source tree.
//
// Returns nil when neither condition holds, including when dest doesn't
// exist yet (the common fresh-install case).
func refuseSymlinkLoop(src, dst string) error {
	// (1) Direct symlink-loop: dest is a symlink at src.
	info, err := os.Lstat(dst)
	if err == nil && info.Mode()&os.ModeSymlink != 0 {
		target, readErr := os.Readlink(dst)
		if readErr == nil {
			abs := target
			if !filepath.IsAbs(abs) {
				abs = filepath.Join(filepath.Dir(dst), target)
			}
			if absClean, err := filepath.Abs(abs); err == nil && absClean == src {
				return fmt.Errorf("dest %s symlinks to source %s; refusing to copy into self", dst, src)
			}
		}
	}

	// (2) Containment after symlink eval. EvalSymlinks fails on missing
	// paths, so silently skip when dest doesn't exist yet.
	srcReal, err := filepath.EvalSymlinks(src)
	if err != nil {
		return nil
	}
	dstReal, err := filepath.EvalSymlinks(dst)
	if err != nil {
		// dest missing (or partly missing): nothing to compare against.
		return nil
	}
	if srcReal == dstReal {
		return fmt.Errorf("dest %s and source %s resolve to the same path; refusing to copy into self", dst, src)
	}
	if pathContains(srcReal, dstReal) {
		return fmt.Errorf("dest %s resolves inside source %s; refusing to copy into self", dst, src)
	}
	if pathContains(dstReal, srcReal) {
		return fmt.Errorf("source %s resolves inside dest %s; refusing to copy into self", src, dst)
	}
	return nil
}

// pathContains reports whether child is the same path as parent or sits
// strictly inside it, after both have been cleaned. Uses filepath.Separator
// so it works on every platform.
func pathContains(parent, child string) bool {
	if parent == child {
		return false
	}
	p := filepath.Clean(parent) + string(filepath.Separator)
	return strings.HasPrefix(filepath.Clean(child)+string(filepath.Separator), p)
}

// buildCopyPlan walks each SubtreeSrc and produces the list of files to
// consider. Skip patterns mirror initSkipDirs. Honors ctx cancellation so
// Ctrl-C breaks out of a deep walk on a slow filesystem.
//
// Symlinks (file or directory) are never followed: fs.WalkDir doesn't
// recurse into symlinked directories, and the entry-level filter below
// drops symlink files outright. This is a behaviour change from the prior
// filepath.WalkDir-based code; the symmetry between --from and embedded
// sources is worth the divergence.
func buildCopyPlan(ctx context.Context, subtrees []SubtreeSrc, dst string) ([]fileClassification, error) {
	var plan []fileClassification
	for _, st := range subtrees {
		if st.FS == nil {
			return nil, fmt.Errorf("buildCopyPlan: nil FS for subtree %q", st.RelPath)
		}
		err := fs.WalkDir(st.FS, ".", func(rel string, d fs.DirEntry, walkErr error) error {
			if err := ctx.Err(); err != nil {
				return err
			}
			if walkErr != nil {
				return walkErr
			}
			if rel == "." {
				return nil
			}
			base := d.Name()
			if d.IsDir() {
				if initSkipDirs[base] || strings.HasPrefix(base, ".") {
					return fs.SkipDir
				}
				return nil
			}
			// Symlinks not followed: drop the entry.
			if d.Type()&fs.ModeSymlink != 0 {
				return nil
			}
			relDest := st.RelPath + "/" + rel
			mode, modeErr := planFileMode(st.FS, rel, st.Embedded)
			if modeErr != nil {
				return modeErr
			}
			plan = append(plan, fileClassification{
				srcFS:    st.FS,
				srcRel:   rel,
				embedded: st.Embedded,
				dstAbs:   filepath.Join(dst, filepath.FromSlash(relDest)),
				relDest:  relDest,
				mode:     mode,
			})
			return nil
		})
		if err != nil {
			return nil, err
		}
	}
	sort.Slice(plan, func(i, j int) bool { return plan[i].relDest < plan[j].relDest })
	return plan, nil
}

// planFileMode returns the destination mode for a source file. For
// filesystem sources, the source's stat mode is used (clamped to 0o644
// minimum). For embedded sources, //go:embed strips mode bits to 0o444 —
// we sniff the first two bytes; a `#!` shebang promotes the file to 0o755.
//
// Errors are propagated rather than silently fallen back to 0o644: a stat
// or open failure on a source file is a real problem (transient EIO, a
// file deleted between walk and stat, a permission glitch) and the
// pipeline must surface it instead of writing an unexpected mode.
func planFileMode(srcFS fs.FS, srcRel string, embedded bool) (os.FileMode, error) {
	if !embedded {
		info, err := fs.Stat(srcFS, srcRel)
		if err != nil {
			return 0, fmt.Errorf("stat %s: %w", srcRel, err)
		}
		return info.Mode().Perm() | 0o644, nil
	}
	f, err := srcFS.Open(srcRel)
	if err != nil {
		return 0, fmt.Errorf("open %s: %w", srcRel, err)
	}
	defer f.Close()
	var head [2]byte
	n, _ := f.Read(head[:])
	if n == 2 && head[0] == '#' && head[1] == '!' {
		return 0o755, nil
	}
	return 0o644, nil
}

// classifyFiles pre-computes each plan entry's state + source sha. Honors
// ctx cancellation so a SHA pass over many files can be aborted promptly.
func classifyFiles(ctx context.Context, plan []fileClassification, dst string, prior *InitState) ([]fileClassification, error) {
	out := make([]fileClassification, 0, len(plan))
	for _, c := range plan {
		if err := ctx.Err(); err != nil {
			return nil, err
		}
		srcSHA, err := sha256FS(c.srcFS, c.srcRel)
		if err != nil {
			return nil, fmt.Errorf("sha %s: %w", c.relDest, err)
		}
		c.srcSHA = srcSHA
		dstInfo, err := os.Stat(c.dstAbs)
		switch {
		case errors.Is(err, fs.ErrNotExist):
			c.state = stateNew
		case err != nil:
			return nil, fmt.Errorf("stat %s: %w", c.dstAbs, err)
		case dstInfo.IsDir():
			return nil, fmt.Errorf("destination %s is a directory; expected file", c.dstAbs)
		default:
			// dest exists; look up the pristine sha in the state file.
			if prior == nil {
				c.state = stateNew
				break
			}
			pristine, ok := prior.Files[c.relDest]
			if !ok {
				c.state = stateNew
				break
			}
			dstSHA, err := sha256File(c.dstAbs)
			if err != nil {
				return nil, fmt.Errorf("sha %s: %w", c.dstAbs, err)
			}
			if dstSHA == pristine.SHA256 {
				c.state = stateClean
			} else {
				c.state = stateDirty
			}
		}
		out = append(out, c)
	}
	return out, nil
}

// sha256File computes the hex sha256 of a file's contents.
func sha256File(path string) (string, error) {
	f, err := os.Open(path)
	if err != nil {
		return "", err
	}
	defer f.Close()
	h := sha256.New()
	if _, err := io.Copy(h, f); err != nil {
		return "", err
	}
	return hex.EncodeToString(h.Sum(nil)), nil
}

// sha256FS is the fs.FS-rooted sibling of sha256File. Works for both
// os.DirFS-backed and embed.FS-backed sources.
func sha256FS(srcFS fs.FS, srcRel string) (string, error) {
	f, err := srcFS.Open(srcRel)
	if err != nil {
		return "", err
	}
	defer f.Close()
	h := sha256.New()
	if _, err := io.Copy(h, f); err != nil {
		return "", err
	}
	return hex.EncodeToString(h.Sum(nil)), nil
}

// copyFile writes via tmp-then-rename. Creates the parent directory. The
// caller supplies the mode (computed by planFileMode); copyFile applies it
// via O_CREATE + an explicit Chmod since a typical 0o022 umask would strip
// the executable bit from O_CREATE alone.
func copyFile(srcFS fs.FS, srcRel, dst string, mode os.FileMode) error {
	if err := os.MkdirAll(filepath.Dir(dst), 0o755); err != nil {
		return err
	}
	in, err := srcFS.Open(srcRel)
	if err != nil {
		return err
	}
	defer in.Close()
	tmp := dst + ".tmp"
	out, err := os.OpenFile(tmp, os.O_CREATE|os.O_WRONLY|os.O_TRUNC, mode)
	if err != nil {
		return err
	}
	if _, err := io.Copy(out, in); err != nil {
		out.Close()
		os.Remove(tmp)
		return err
	}
	if err := out.Close(); err != nil {
		os.Remove(tmp)
		return err
	}
	if err := os.Chmod(tmp, mode); err != nil {
		os.Remove(tmp)
		return err
	}
	return os.Rename(tmp, dst)
}

// sourceRepoRootLabel renders a state.json-friendly identifier for the
// source. Filesystem paths pass through; the embedded source is recorded
// as the sentinel "<embedded>".
func sourceRepoRootLabel(src string) string {
	if src == "" {
		return "<embedded>"
	}
	return src
}

// loadState reads the state file at <dest>/.audit-init/state.json. Returns
// nil with no error when the file is absent — every file then classifies as
// NEW, which is the documented state-absent reconciliation path.
func loadState(dest string) (*InitState, error) {
	p := filepath.Join(dest, stateFile)
	data, err := os.ReadFile(p)
	if errors.Is(err, fs.ErrNotExist) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	var s InitState
	if err := json.Unmarshal(data, &s); err != nil {
		return nil, err
	}
	if s.Files == nil {
		s.Files = map[string]InitStateFile{}
	}
	return &s, nil
}

func saveState(dest string, s *InitState) error {
	p := filepath.Join(dest, stateFile)
	if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
		return err
	}
	data, err := json.MarshalIndent(s, "", "  ")
	if err != nil {
		return err
	}
	data = append(data, '\n')
	tmp := p + ".tmp"
	if err := os.WriteFile(tmp, data, 0o644); err != nil {
		return err
	}
	return os.Rename(tmp, p)
}

// gitHeadSHA returns the source's git HEAD commit (short-circuit to empty if
// the source isn't a git checkout, or git isn't installed, or src is "" —
// the embedded-source case). Recorded in state.json for forensic value
// only — never load-bearing.
func gitHeadSHA(src string) string {
	if src == "" {
		return ""
	}
	headPath := filepath.Join(src, ".git", "HEAD")
	data, err := os.ReadFile(headPath)
	if err != nil {
		return ""
	}
	headRef := strings.TrimSpace(string(data))
	if strings.HasPrefix(headRef, "ref: ") {
		refPath := filepath.Join(src, ".git", strings.TrimPrefix(headRef, "ref: "))
		if refData, err := os.ReadFile(refPath); err == nil {
			return strings.TrimSpace(string(refData))
		}
		return ""
	}
	return headRef
}

// noteExtractorName extracts the <name> segment from a forward-slash path
// shaped like "extractors/<name>/..." and adds it to the set. Used by the
// init loop to track which extractors had source files this run (for
// touched-set membership and for pruning stale carry-over entries).
func noteExtractorName(relDest string, set map[string]bool) {
	const prefix = "extractors/"
	if !strings.HasPrefix(relDest, prefix) {
		return
	}
	tail := relDest[len(prefix):]
	idx := strings.IndexByte(tail, '/')
	if idx <= 0 {
		return
	}
	set[tail[:idx]] = true
}

// noteExtractorTouched is the touched-set variant of noteExtractorName.
// Kept as a separate identifier to keep grep results focused at call
// sites — the implementation is intentionally identical.
func noteExtractorTouched(relDest string, touched map[string]bool) {
	noteExtractorName(relDest, touched)
}

// extractorManifestName returns (name, true) when relDest is exactly the
// top-level extractor manifest at "extractors/<name>/manifest.toml". A
// nested fixture like "extractors/typescript/fixtures/pkg/manifest.toml"
// returns ("", false) — the DIRTY-skipped detector must not over-match
// fixture files that happen to share the manifest.toml basename.
func extractorManifestName(relDest string) (string, bool) {
	const prefix = "extractors/"
	if !strings.HasPrefix(relDest, prefix) {
		return "", false
	}
	tail := relDest[len(prefix):]
	idx := strings.IndexByte(tail, '/')
	if idx <= 0 {
		return "", false
	}
	if tail[idx+1:] != "manifest.toml" {
		return "", false
	}
	return tail[:idx], true
}

// bootstrapTouchedExtractors parses each requested extractor's manifest
// and runs its declared [runtime].bootstrap argv. Outcomes
// (ok | failed | n-a) are recorded in state.Extractors. Failures do not
// abort the init; the failed status is carried forward and the next
// `code-audit init` re-tries.
//
// Returns ctx.Err() if the context is canceled mid-loop so the caller
// can skip saveState (avoiding bogus "context canceled" failures landing
// in state.json for every remaining extractor).
//
// Bootstrap output is tee'd to stdout so a slow installer (e.g. `npm
// install` taking 30s+ on a fresh extractor) is visible to the user
// instead of looking like a hang.
func bootstrapTouchedExtractors(ctx context.Context, destAbs string, touched map[string]bool, state *InitState, stdout io.Writer) error {
	if len(touched) == 0 {
		return nil
	}
	names := make([]string, 0, len(touched))
	for n := range touched {
		names = append(names, n)
	}
	sort.Strings(names)

	extractorsRoot := filepath.Join(destAbs, "extractors")
	for _, name := range names {
		if err := ctx.Err(); err != nil {
			return err
		}
		extractorDir := filepath.Join(extractorsRoot, name)
		manifestPath := filepath.Join(extractorDir, "manifest.toml")
		now := time.Now().UTC()

		m, err := manifest.Parse(manifestPath)
		if err != nil {
			fmt.Fprintf(stdout, "init: bootstrap %s: parse manifest: %v\n", name, err)
			state.EnsureExtractorsMap()[name] = ExtractorState{
				BootstrapStatus: BootstrapFailed,
				BootstrappedAt:  &now,
				LastError:       err.Error(),
			}
			continue
		}

		if len(m.Runtime.Bootstrap) == 0 {
			state.EnsureExtractorsMap()[name] = ExtractorState{
				BootstrapStatus: BootstrapNA,
				BootstrappedAt:  &now,
			}
			continue
		}

		fmt.Fprintf(stdout, "init: bootstrap %s: running %v\n", name, m.Runtime.Bootstrap)
		if err := runBootstrap(ctx, extractorDir, m, stdout); err != nil {
			fmt.Fprintf(stdout, "init: bootstrap %s: %v\n", name, err)
			if hint := strings.TrimSpace(m.Runtime.SetupHint); hint != "" {
				fmt.Fprintf(stdout, "init: bootstrap %s hint: %s\n", name, hint)
			}
			state.EnsureExtractorsMap()[name] = ExtractorState{
				BootstrapStatus: BootstrapFailed,
				BootstrappedAt:  &now,
				LastError:       err.Error(),
			}
			continue
		}

		fmt.Fprintf(stdout, "init: bootstrap %s: ok\n", name)
		state.EnsureExtractorsMap()[name] = ExtractorState{
			BootstrapStatus: BootstrapOK,
			BootstrappedAt:  &now,
		}
	}
	return nil
}

// bootstrapStderrCap bounds captured stdout/stderr per stream so a noisy
// installer (npm spamming progress bars) can't OOM the binary.
const bootstrapStderrCap = 64 * 1024

// bootstrapNoExitCode is the Exit sentinel for "process never exited
// cleanly" — covers exec lookup failures (ENOENT) and signal-killed
// processes (ctx cancellation, OOM, etc.). A real cmd.Wait() exit code is
// always >= 0.
const bootstrapNoExitCode = -1

// BootstrapError wraps a bootstrap-command failure. Stderr is truncated at
// bootstrapStderrCap. The string form is persisted to state.json as
// LastError — keep it stable and one-line-friendly.
type BootstrapError struct {
	Command []string
	Stderr  []byte
	Stdout  []byte
	Exit    int   // bootstrapNoExitCode (-1) when the process never exited cleanly
	Cause   error // wraps the original cmd.Run error AND any ctx.Err via errors.Join
}

func (e *BootstrapError) Error() string {
	cmd := strings.Join(e.Command, " ")
	exitLabel := fmt.Sprintf("exit %d", e.Exit)
	if e.Exit == bootstrapNoExitCode {
		exitLabel = "no exit code"
	}
	if len(e.Stderr) == 0 {
		return fmt.Sprintf("bootstrap %q failed (%s): %v", cmd, exitLabel, e.Cause)
	}
	return fmt.Sprintf("bootstrap %q failed (%s): %v\nstderr: %s",
		cmd, exitLabel, e.Cause, strings.TrimSpace(string(e.Stderr)))
}

func (e *BootstrapError) Unwrap() error { return e.Cause }

// cappedWriter is an io.Writer that silently drops bytes once `cap` total
// bytes have been buffered. Writes past the cap still report full success
// so the spawned process does not see EPIPE — this is the explicit
// intent, knowingly violating the strict io.Writer convention. Used only
// for capturing exec child stderr/stdout into a bounded buffer; not safe
// to compose with bufio.Writer or other writers that expect partial-write
// signalling.
type cappedWriter struct {
	buf *bytes.Buffer
	cap int
}

// syncWriter serialises writes to an underlying io.Writer. os/exec
// allocates separate goroutines for the child's stdout and stderr pipes;
// if both target the same user-supplied bytes.Buffer (which is not
// goroutine-safe), interleaved writes race and silently drop data.
// Wrapping the shared progress writer here keeps the tee correct.
type syncWriter struct {
	mu sync.Mutex
	w  io.Writer
}

func (s *syncWriter) Write(p []byte) (int, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.w.Write(p)
}

func (c *cappedWriter) Write(p []byte) (int, error) {
	remaining := c.cap - c.buf.Len()
	if remaining <= 0 {
		return len(p), nil
	}
	if len(p) > remaining {
		c.buf.Write(p[:remaining])
		return len(p), nil
	}
	c.buf.Write(p)
	return len(p), nil
}

// runBootstrap runs m.Runtime.Bootstrap as argv with cwd set to extractorDir.
// stdout/stderr are tee'd to `progress` (typically the user's stdout) so a
// slow installer (e.g. `npm install`) is visible in the terminal; pass
// io.Discard or nil to suppress live output. The same streams are also
// captured into bounded buffers (cap = bootstrapStderrCap each) for
// inclusion in any returned *BootstrapError.
//
// Returns nil immediately when Bootstrap is empty (the "n-a" path's
// responsibility lies with the caller, which inspects len(Bootstrap)).
// On failure, returns a *BootstrapError whose Cause wraps the original
// cmd.Run error joined with ctx.Err() when applicable — both are
// reachable via errors.Is / errors.As.
func runBootstrap(ctx context.Context, extractorDir string, m *manifest.Manifest, progress io.Writer) error {
	argv := m.Runtime.Bootstrap
	if len(argv) == 0 {
		return nil
	}
	if progress == nil {
		progress = io.Discard
	}
	// Serialise progress writes: os/exec runs separate goroutines for
	// stdout and stderr, both targeting `progress`. Without the mutex,
	// concurrent Writes to a non-thread-safe Writer (e.g. bytes.Buffer)
	// race and silently drop data.
	syncProgress := &syncWriter{w: progress}
	cmd := exec.CommandContext(ctx, argv[0], argv[1:]...)
	cmd.Dir = extractorDir
	// WaitDelay bounds the post-cancellation drain window. Without it,
	// `sh -c "sleep 30"` can hang cmd.Wait() for the full 30s on Linux
	// even after SIGKILL — the orphan `sleep` grandchild inherits the
	// stdout/stderr pipes, so the os/exec copy goroutines block on
	// Read() until the grandchild exits. With WaitDelay set, cmd.Wait()
	// returns within the delay even if pipes haven't drained.
	cmd.WaitDelay = 2 * time.Second
	var stderrBuf, stdoutBuf bytes.Buffer
	cmd.Stdout = io.MultiWriter(syncProgress, &cappedWriter{buf: &stdoutBuf, cap: bootstrapStderrCap})
	cmd.Stderr = io.MultiWriter(syncProgress, &cappedWriter{buf: &stderrBuf, cap: bootstrapStderrCap})
	runErr := cmd.Run()
	if runErr == nil {
		return nil
	}
	be := &BootstrapError{
		Command: argv,
		Stderr:  stderrBuf.Bytes(),
		Stdout:  stdoutBuf.Bytes(),
		Exit:    bootstrapNoExitCode,
		Cause:   runErr,
	}
	var ee *exec.ExitError
	if errors.As(runErr, &ee) {
		be.Exit = ee.ExitCode()
	}
	// Preserve BOTH the underlying cmd.Run error AND the ctx error when the
	// process was killed by cancellation. errors.Is(err, context.Canceled)
	// still succeeds via the joined chain; the original *exec.ExitError
	// stays reachable via errors.As.
	if ctxErr := ctx.Err(); ctxErr != nil {
		be.Cause = errors.Join(runErr, ctxErr)
	}
	return be
}
