// Package ghclient is a thin wrapper around `gh` invocations used by the
// find-next-instance subcommand. The CLI is small, so the surface is small.
package ghclient

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"os/exec"
	"strconv"
	"strings"
)

// ErrGHNotInstalled is returned when the `gh` binary is not on PATH.
var ErrGHNotInstalled = errors.New("`gh` not found on PATH — install from https://cli.github.com/")

// Client is a mockable wrapper. Production callers construct via New().
// Tests construct directly with stub Exec.
type Client struct {
	// Exec runs an external command in the given working directory.
	// Empty dir means "inherit the parent process's cwd" (Go's os/exec
	// default). nil Exec means use the real exec.CommandContext.
	Exec func(ctx context.Context, dir, name string, args ...string) ([]byte, []byte, error)
}

// New returns a Client wired to exec.CommandContext.
func New() *Client {
	return &Client{Exec: realExec}
}

func realExec(ctx context.Context, dir, name string, args ...string) ([]byte, []byte, error) {
	if _, err := exec.LookPath(name); err != nil {
		if name == "gh" {
			return nil, nil, ErrGHNotInstalled
		}
		return nil, nil, fmt.Errorf("lookup %q: %w", name, err)
	}
	cmd := exec.CommandContext(ctx, name, args...)
	cmd.Dir = dir
	var stdout, stderr bytes.Buffer
	cmd.Stdout = &stdout
	cmd.Stderr = &stderr
	err := cmd.Run()
	return stdout.Bytes(), stderr.Bytes(), err
}

// PRDiff invokes `gh pr diff <pr> --repo <repo>` and returns the diff text.
// Runs in `dir` so that, when --repo is omitted, gh can resolve the active
// repo from the directory. On failure, surfaces gh's stderr verbatim.
func (c *Client) PRDiff(ctx context.Context, dir, repo string, pr int) (string, error) {
	args := []string{"pr", "diff", strconv.Itoa(pr)}
	if repo != "" {
		args = append(args, "--repo", repo)
	}
	stdout, stderr, err := c.Exec(ctx, dir, "gh", args...)
	if err != nil {
		if errors.Is(err, ErrGHNotInstalled) {
			return "", err
		}
		return "", fmt.Errorf("gh pr diff %d (repo=%q): %w; stderr: %s",
			pr, repo, err, strings.TrimSpace(string(stderr)))
	}
	return string(stdout), nil
}

// OpenIssues runs `gh issue list --state open --repo <repo> --limit <limit>`
// in `dir` and returns the raw JSON payload. Caller decodes. Matches the
// signature of PRDiff so test stubs are uniform.
func (c *Client) OpenIssues(ctx context.Context, dir, repo string, limit int) ([]byte, error) {
	if c.Exec == nil {
		return nil, fmt.Errorf("ghclient: nil Exec")
	}
	args := []string{
		"issue", "list", "--state", "open",
		"--limit", strconv.Itoa(limit),
		"--json", "number,title,labels,createdAt,updatedAt,body",
	}
	if repo != "" {
		args = append(args, "--repo", repo)
	}
	stdout, stderr, err := c.Exec(ctx, dir, "gh", args...)
	if err != nil {
		if errors.Is(err, ErrGHNotInstalled) {
			return nil, err
		}
		return nil, fmt.Errorf("gh issue list (repo=%q): %w; stderr: %s",
			repo, err, strings.TrimSpace(string(stderr)))
	}
	return stdout, nil
}

// MergedPRs runs `gh pr list --state merged --repo <repo> --limit <limit>`
// in `dir` and returns the raw JSON payload. Caller decodes.
func (c *Client) MergedPRs(ctx context.Context, dir, repo string, limit int) ([]byte, error) {
	if c.Exec == nil {
		return nil, fmt.Errorf("ghclient: nil Exec")
	}
	args := []string{
		"pr", "list", "--state", "merged",
		"--limit", strconv.Itoa(limit),
		"--json", "number,title,mergedAt,files,body",
	}
	if repo != "" {
		args = append(args, "--repo", repo)
	}
	stdout, stderr, err := c.Exec(ctx, dir, "gh", args...)
	if err != nil {
		if errors.Is(err, ErrGHNotInstalled) {
			return nil, err
		}
		return nil, fmt.Errorf("gh pr list (repo=%q): %w; stderr: %s",
			repo, err, strings.TrimSpace(string(stderr)))
	}
	return stdout, nil
}

// RepoNameWithOwner returns the active repo's `owner/name`, derived from
// `gh repo view --json nameWithOwner -q .nameWithOwner` in `dir`. Empty
// `dir` means "inherit cwd". Returns ErrGHNotInstalled if gh isn't on PATH.
func (c *Client) RepoNameWithOwner(ctx context.Context, dir string) (string, error) {
	if c.Exec == nil {
		return "", fmt.Errorf("ghclient: nil Exec")
	}
	stdout, stderr, err := c.Exec(ctx, dir, "gh", "repo", "view", "--json", "nameWithOwner", "-q", ".nameWithOwner")
	if err != nil {
		if errors.Is(err, ErrGHNotInstalled) {
			return "", err
		}
		return "", fmt.Errorf("gh repo view: %w; stderr: %s", err, strings.TrimSpace(string(stderr)))
	}
	return strings.TrimSpace(string(stdout)), nil
}
