//go:build unix

package cli

import (
	"context"
	"errors"
	"fmt"
	"os"
	"syscall"
	"time"
)

// acquireFlock implementation for unix (darwin, linux, freebsd, etc.).
// Polls with 50ms ticks under LOCK_NB so the wait honors ctx.Done()
// without resorting to a goroutine + pipe trick.
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

func releaseFlock(fd *os.File) {
	if fd == nil {
		return
	}
	_ = syscall.Flock(int(fd.Fd()), syscall.LOCK_UN)
	_ = fd.Close()
}
