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
	// Exec runs an external command. nil means use exec.CommandContext.
	Exec func(ctx context.Context, name string, args ...string) ([]byte, []byte, error)
}

// New returns a Client wired to exec.CommandContext.
func New() *Client {
	return &Client{Exec: realExec}
}

func realExec(ctx context.Context, name string, args ...string) ([]byte, []byte, error) {
	if _, err := exec.LookPath(name); err != nil {
		if name == "gh" {
			return nil, nil, ErrGHNotInstalled
		}
		return nil, nil, fmt.Errorf("lookup %q: %w", name, err)
	}
	cmd := exec.CommandContext(ctx, name, args...)
	var stdout, stderr bytes.Buffer
	cmd.Stdout = &stdout
	cmd.Stderr = &stderr
	err := cmd.Run()
	return stdout.Bytes(), stderr.Bytes(), err
}

// PRDiff invokes `gh pr diff <pr> --repo <repo>` and returns the diff text.
// On failure, surfaces `gh`'s stderr verbatim in the returned error.
func (c *Client) PRDiff(ctx context.Context, repo string, pr int) (string, error) {
	args := []string{"pr", "diff", strconv.Itoa(pr)}
	if repo != "" {
		args = append(args, "--repo", repo)
	}
	stdout, stderr, err := c.Exec(ctx, "gh", args...)
	if err != nil {
		if errors.Is(err, ErrGHNotInstalled) {
			return "", err
		}
		return "", fmt.Errorf("gh pr diff %d (repo=%q): %w; stderr: %s",
			pr, repo, err, strings.TrimSpace(string(stderr)))
	}
	return string(stdout), nil
}

// RepoNameWithOwner returns the active repo's `owner/name`, derived from
// `gh repo view --json nameWithOwner -q .nameWithOwner` in the given dir.
// Empty when `gh` isn't installed; the caller surfaces the original
// ErrGHNotInstalled if it cares.
func (c *Client) RepoNameWithOwner(ctx context.Context, dir string) (string, error) {
	if c.Exec == nil {
		return "", fmt.Errorf("ghclient: nil Exec")
	}
	stdout, stderr, err := c.Exec(ctx, "gh", "repo", "view", "--json", "nameWithOwner", "-q", ".nameWithOwner")
	if err != nil {
		if errors.Is(err, ErrGHNotInstalled) {
			return "", err
		}
		return "", fmt.Errorf("gh repo view: %w; stderr: %s", err, strings.TrimSpace(string(stderr)))
	}
	return strings.TrimSpace(string(stdout)), nil
}
