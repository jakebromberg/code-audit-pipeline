//go:build windows

package cli

import (
	"context"
	"os"
	"time"
)

// acquireFlock and releaseFlock are POSIX-only. The binary doesn't ship
// for Windows (.goreleaser.yaml lists darwin/linux), but the package
// must still compile so `go build ./...` and `go vet ./...` succeed for
// contributors on Windows. Any code path that reaches these stubs
// returns ErrUnsupportedPlatform, which EnsureExtractor surfaces to its
// caller without crashing.

func acquireFlock(ctx context.Context, path string, timeout time.Duration) (*os.File, error) {
	return nil, ErrUnsupportedPlatform
}

func releaseFlock(fd *os.File) {
	// nothing to do — acquireFlock never returned a real fd on this platform.
}
