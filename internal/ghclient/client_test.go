package ghclient

import (
	"context"
	"errors"
	"strings"
	"testing"
)

func TestPRDiffPassesRepoAndNumber(t *testing.T) {
	var calledArgs []string
	var calledDir string
	c := &Client{
		Exec: func(ctx context.Context, dir, name string, args ...string) ([]byte, []byte, error) {
			if name != "gh" {
				t.Fatalf("want gh, got %s", name)
			}
			calledDir = dir
			calledArgs = args
			return []byte("DIFF"), nil, nil
		},
	}
	got, err := c.PRDiff(context.Background(), "/repos/foo", "owner/repo", 42)
	if err != nil {
		t.Fatalf("PRDiff: %v", err)
	}
	if got != "DIFF" {
		t.Errorf("got %q", got)
	}
	if calledDir != "/repos/foo" {
		t.Errorf("dir=%q want /repos/foo", calledDir)
	}
	want := []string{"pr", "diff", "42", "--repo", "owner/repo"}
	if strings.Join(calledArgs, " ") != strings.Join(want, " ") {
		t.Errorf("args=%v want=%v", calledArgs, want)
	}
}

func TestPRDiffSurfacesStderrOnFailure(t *testing.T) {
	c := &Client{
		Exec: func(ctx context.Context, dir, name string, args ...string) ([]byte, []byte, error) {
			return nil, []byte("HTTP 404: Not Found"), errors.New("exit status 1")
		},
	}
	_, err := c.PRDiff(context.Background(), "", "owner/repo", 999)
	if err == nil {
		t.Fatal("want error")
	}
	if !strings.Contains(err.Error(), "HTTP 404") {
		t.Errorf("stderr not surfaced: %v", err)
	}
}

func TestPRDiffSurfacesNotInstalled(t *testing.T) {
	c := &Client{
		Exec: func(ctx context.Context, dir, name string, args ...string) ([]byte, []byte, error) {
			return nil, nil, ErrGHNotInstalled
		},
	}
	_, err := c.PRDiff(context.Background(), "", "owner/repo", 1)
	if !errors.Is(err, ErrGHNotInstalled) {
		t.Errorf("want ErrGHNotInstalled, got %v", err)
	}
}

func TestOpenIssuesPassesRepoAndLimit(t *testing.T) {
	var calledArgs []string
	var calledDir string
	c := &Client{
		Exec: func(ctx context.Context, dir, name string, args ...string) ([]byte, []byte, error) {
			calledDir = dir
			calledArgs = args
			return []byte(`[]`), nil, nil
		},
	}
	got, err := c.OpenIssues(context.Background(), "/repos/foo", "owner/repo", 100)
	if err != nil {
		t.Fatalf("OpenIssues: %v", err)
	}
	if string(got) != "[]" {
		t.Errorf("got %q", got)
	}
	if calledDir != "/repos/foo" {
		t.Errorf("dir=%q want /repos/foo", calledDir)
	}
	joined := strings.Join(calledArgs, " ")
	for _, want := range []string{"issue", "list", "--state", "open", "--limit", "100", "--repo", "owner/repo"} {
		if !strings.Contains(joined, want) {
			t.Errorf("args missing %q: %v", want, calledArgs)
		}
	}
}

func TestMergedPRsPassesRepoAndLimit(t *testing.T) {
	var calledArgs []string
	c := &Client{
		Exec: func(ctx context.Context, dir, name string, args ...string) ([]byte, []byte, error) {
			calledArgs = args
			return []byte(`[]`), nil, nil
		},
	}
	_, err := c.MergedPRs(context.Background(), "", "owner/repo", 50)
	if err != nil {
		t.Fatalf("MergedPRs: %v", err)
	}
	joined := strings.Join(calledArgs, " ")
	for _, want := range []string{"pr", "list", "--state", "merged", "--limit", "50"} {
		if !strings.Contains(joined, want) {
			t.Errorf("args missing %q: %v", want, calledArgs)
		}
	}
}

func TestOpenIssuesSurfacesNotInstalled(t *testing.T) {
	c := &Client{
		Exec: func(ctx context.Context, dir, name string, args ...string) ([]byte, []byte, error) {
			return nil, nil, ErrGHNotInstalled
		},
	}
	_, err := c.OpenIssues(context.Background(), "", "owner/repo", 10)
	if !errors.Is(err, ErrGHNotInstalled) {
		t.Errorf("want ErrGHNotInstalled, got %v", err)
	}
}

func TestRepoNameWithOwnerForwardsDir(t *testing.T) {
	var calledDir string
	c := &Client{
		Exec: func(ctx context.Context, dir, name string, args ...string) ([]byte, []byte, error) {
			calledDir = dir
			return []byte("owner/repo\n"), nil, nil
		},
	}
	got, err := c.RepoNameWithOwner(context.Background(), "/repos/foo")
	if err != nil {
		t.Fatal(err)
	}
	if got != "owner/repo" {
		t.Errorf("got %q", got)
	}
	if calledDir != "/repos/foo" {
		t.Errorf("dir=%q want /repos/foo (the dir argument must reach Exec so gh runs in the right repo)", calledDir)
	}
}
