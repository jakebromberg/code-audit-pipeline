package ghclient

import (
	"context"
	"errors"
	"strings"
	"testing"
)

func TestPRDiffPassesRepoAndNumber(t *testing.T) {
	var calledArgs []string
	c := &Client{
		Exec: func(ctx context.Context, name string, args ...string) ([]byte, []byte, error) {
			if name != "gh" {
				t.Fatalf("want gh, got %s", name)
			}
			calledArgs = args
			return []byte("DIFF"), nil, nil
		},
	}
	got, err := c.PRDiff(context.Background(), "owner/repo", 42)
	if err != nil {
		t.Fatalf("PRDiff: %v", err)
	}
	if got != "DIFF" {
		t.Errorf("got %q", got)
	}
	want := []string{"pr", "diff", "42", "--repo", "owner/repo"}
	if strings.Join(calledArgs, " ") != strings.Join(want, " ") {
		t.Errorf("args=%v want=%v", calledArgs, want)
	}
}

func TestPRDiffSurfacesStderrOnFailure(t *testing.T) {
	c := &Client{
		Exec: func(ctx context.Context, name string, args ...string) ([]byte, []byte, error) {
			return nil, []byte("HTTP 404: Not Found"), errors.New("exit status 1")
		},
	}
	_, err := c.PRDiff(context.Background(), "owner/repo", 999)
	if err == nil {
		t.Fatal("want error")
	}
	if !strings.Contains(err.Error(), "HTTP 404") {
		t.Errorf("stderr not surfaced: %v", err)
	}
}

func TestPRDiffSurfacesNotInstalled(t *testing.T) {
	c := &Client{
		Exec: func(ctx context.Context, name string, args ...string) ([]byte, []byte, error) {
			return nil, nil, ErrGHNotInstalled
		},
	}
	_, err := c.PRDiff(context.Background(), "owner/repo", 1)
	if !errors.Is(err, ErrGHNotInstalled) {
		t.Errorf("want ErrGHNotInstalled, got %v", err)
	}
}

func TestRepoNameWithOwner(t *testing.T) {
	c := &Client{
		Exec: func(ctx context.Context, name string, args ...string) ([]byte, []byte, error) {
			return []byte("owner/repo\n"), nil, nil
		},
	}
	got, err := c.RepoNameWithOwner(context.Background(), ".")
	if err != nil {
		t.Fatal(err)
	}
	if got != "owner/repo" {
		t.Errorf("got %q", got)
	}
}
