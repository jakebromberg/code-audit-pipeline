package cli

import (
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
	"path/filepath"
	"sort"
	"strings"
	"time"
)

// initSubdirs is the list of source subdirectories `audit init` copies into
// the destination. Per ADR-0006, queries get bundled into the binary too, but
// init still lays them down on disk so contributors can edit and re-run
// without rebuilding.
var initSubdirs = []string{"extractors", "pipeline/queries"}

// initSkipDirs is the per-extractor scratch / vendor directories that must
// never be copied. They balloon the destination and break repeat-init.
var initSkipDirs = map[string]bool{
	"node_modules": true,
	".build":       true,
	".swiftpm":     true,
	"DerivedData":  true,
	"Pods":         true,
	"dist":         true,
	"build":        true,
	"coverage":     true,
}

// stateFile records each copied file's pristine sha256 so subsequent
// invocations can distinguish locally-modified files from clean upgrades.
const stateFile = ".audit-init/state.json"

// InitState is the on-disk shape of stateFile.
type InitState struct {
	AuditVersion    string                     `json:"audit_version"`
	SourceRepoRoot  string                     `json:"source_repo_root"`
	SourceCommitSHA string                     `json:"source_commit_sha,omitempty"`
	AppliedAt       string                     `json:"applied_at"`
	Files           map[string]InitStateFile   `json:"files"`
}

type InitStateFile struct {
	SHA256 string `json:"sha256"`
}

// Init implements `audit init`.
func Init(ctx context.Context, argv []string, stdout io.Writer) int {
	fset := flag.NewFlagSet("init", flag.ContinueOnError)
	destFlag := fset.String("dest", "", "destination (default: $XDG_CONFIG_HOME/audit or ~/.config/audit)")
	fromFlag := fset.String("from", "", "source: a local checked-out code-audit-pipeline repo (required in v1)")
	upgrade := fset.Bool("upgrade", false, "refresh dest from source even when files exist; warns about local mods")
	force := fset.Bool("force", false, "overwrite locally-modified files without prompting (implies --upgrade)")
	dryRun := fset.Bool("dry-run", false, "print what would copy without writing")
	if err := fset.Parse(argv); err != nil {
		return 2
	}
	if *fromFlag == "" {
		fmt.Fprintln(stdout, "audit init: --from <path> is required in v1 (point at a local checkout of code-audit-pipeline)")
		return 2
	}
	if *force {
		*upgrade = true
	}

	src, err := filepath.Abs(*fromFlag)
	if err != nil {
		fmt.Fprintf(stdout, "audit init: --from path: %v\n", err)
		return 2
	}
	if err := validateSource(src); err != nil {
		fmt.Fprintf(stdout, "audit init: %v\n", err)
		return 2
	}

	dest := *destFlag
	if dest == "" {
		dest = defaultDest()
		if dest == "" {
			fmt.Fprintln(stdout, "audit init: cannot resolve default destination; pass --dest")
			return 2
		}
	}
	destAbs, err := filepath.Abs(dest)
	if err != nil {
		fmt.Fprintf(stdout, "audit init: dest path: %v\n", err)
		return 2
	}
	if err := refuseSymlinkLoop(src, destAbs); err != nil {
		fmt.Fprintf(stdout, "audit init: %v\n", err)
		return 2
	}

	prior, _ := loadState(destAbs) // missing-OK: every file then classifies NEW

	plan, err := buildCopyPlan(ctx, src, destAbs)
	if err != nil {
		if errors.Is(err, context.Canceled) || errors.Is(err, context.DeadlineExceeded) {
			fmt.Fprintln(stdout, "audit init: cancelled")
			return 130
		}
		fmt.Fprintf(stdout, "audit init: build plan: %v\n", err)
		return 2
	}

	classified, err := classifyFiles(ctx, plan, destAbs, prior)
	if err != nil {
		if errors.Is(err, context.Canceled) || errors.Is(err, context.DeadlineExceeded) {
			fmt.Fprintln(stdout, "audit init: cancelled")
			return 130
		}
		fmt.Fprintf(stdout, "audit init: classify: %v\n", err)
		return 2
	}

	var (
		copiedNew  int
		upgraded   int
		skippedDirty int
		newState   = InitState{
			AuditVersion:    Version,
			SourceRepoRoot:  src,
			SourceCommitSHA: gitHeadSHA(src),
			AppliedAt:       time.Now().UTC().Format(time.RFC3339),
			Files:           map[string]InitStateFile{},
		}
		dirtyExit bool
	)

	for _, c := range classified {
		if err := ctx.Err(); err != nil {
			fmt.Fprintln(stdout, "audit init: cancelled")
			return 130
		}
		switch c.state {
		case stateNew:
			if !*dryRun {
				if err := copyFile(c.srcAbs, c.dstAbs); err != nil {
					fmt.Fprintf(stdout, "audit init: copy %s: %v\n", c.relDest, err)
					return 1
				}
			}
			newState.Files[c.relDest] = InitStateFile{SHA256: c.srcSHA}
			copiedNew++
			if *dryRun {
				fmt.Fprintf(stdout, "would copy NEW %s\n", c.relDest)
			}
		case stateClean:
			if *upgrade {
				if !*dryRun {
					if err := copyFile(c.srcAbs, c.dstAbs); err != nil {
						fmt.Fprintf(stdout, "audit init: copy %s: %v\n", c.relDest, err)
						return 1
					}
				}
				upgraded++
				if *dryRun {
					fmt.Fprintf(stdout, "would upgrade CLEAN %s\n", c.relDest)
				}
			}
			newState.Files[c.relDest] = InitStateFile{SHA256: c.srcSHA}
		case stateDirty:
			if *force {
				if !*dryRun {
					if err := copyFile(c.srcAbs, c.dstAbs); err != nil {
						fmt.Fprintf(stdout, "audit init: copy %s: %v\n", c.relDest, err)
						return 1
					}
				}
				upgraded++
				if *dryRun {
					fmt.Fprintf(stdout, "would overwrite DIRTY %s\n", c.relDest)
				}
				newState.Files[c.relDest] = InitStateFile{SHA256: c.srcSHA}
			} else {
				skippedDirty++
				dirtyExit = true
				fmt.Fprintf(stdout, "skip DIRTY %s (locally modified; use --force to overwrite)\n", c.relDest)
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

	if !*dryRun {
		if err := saveState(destAbs, &newState); err != nil {
			fmt.Fprintf(stdout, "audit init: save state: %v\n", err)
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
	srcAbs  string
	dstAbs  string
	relDest string // forward-slash, joins-as-state-file-key
	srcSHA  string
	state   fileState
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

// buildCopyPlan walks the source subtrees and produces the list of files to
// consider. Skip patterns mirror initSkipDirs. Honors ctx cancellation so
// Ctrl-C breaks out of a deep walk on a slow filesystem.
func buildCopyPlan(ctx context.Context, src, dst string) ([]fileClassification, error) {
	var plan []fileClassification
	for _, sub := range initSubdirs {
		srcSub := filepath.Join(src, sub)
		err := filepath.WalkDir(srcSub, func(path string, d fs.DirEntry, walkErr error) error {
			if err := ctx.Err(); err != nil {
				return err
			}
			if walkErr != nil {
				return walkErr
			}
			if d.IsDir() {
				if initSkipDirs[d.Name()] || (strings.HasPrefix(d.Name(), ".") && path != srcSub) {
					return fs.SkipDir
				}
				return nil
			}
			rel, err := filepath.Rel(src, path)
			if err != nil {
				return err
			}
			relSlash := filepath.ToSlash(rel)
			plan = append(plan, fileClassification{
				srcAbs:  path,
				dstAbs:  filepath.Join(dst, rel),
				relDest: relSlash,
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

// classifyFiles pre-computes each plan entry's state + source sha. Honors
// ctx cancellation so a SHA pass over many files can be aborted promptly.
func classifyFiles(ctx context.Context, plan []fileClassification, dst string, prior *InitState) ([]fileClassification, error) {
	out := make([]fileClassification, 0, len(plan))
	for _, c := range plan {
		if err := ctx.Err(); err != nil {
			return nil, err
		}
		srcSHA, err := sha256File(c.srcAbs)
		if err != nil {
			return nil, fmt.Errorf("sha %s: %w", c.srcAbs, err)
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

// copyFile writes via tmp-then-rename. Creates the parent directory.
func copyFile(src, dst string) error {
	if err := os.MkdirAll(filepath.Dir(dst), 0o755); err != nil {
		return err
	}
	in, err := os.Open(src)
	if err != nil {
		return err
	}
	defer in.Close()
	tmp := dst + ".tmp"
	out, err := os.OpenFile(tmp, os.O_CREATE|os.O_WRONLY|os.O_TRUNC, 0o644)
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
	return os.Rename(tmp, dst)
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
// the source isn't a git checkout, or git isn't installed). Recorded in the
// state file for forensic value only — never load-bearing.
func gitHeadSHA(src string) string {
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
