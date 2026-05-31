package archaeology

import (
	"context"
	"io/fs"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// TestWalkSourceHonorsContextCancellation pins the review finding that
// walkSource ignored context.Context — a long walk could not be
// interrupted by SIGINT or a deadline.
func TestWalkSourceHonorsContextCancellation(t *testing.T) {
	root := t.TempDir()
	for i := 0; i < 100; i++ {
		writeFile(t, filepath.Join(root, "f"+itoa(i)+".go"), "package x\n")
	}
	ctx, cancel := context.WithCancel(context.Background())
	cancel() // already cancelled
	var stats WalkStats
	calls := 0
	err := walkSource(ctx, root, &stats, func(absPath, relPath string, d fs.DirEntry) error {
		calls++
		return nil
	})
	if err == nil {
		t.Errorf("want ctx.Err() returned, got nil")
	}
	if calls > 1 {
		t.Errorf("walk should stop almost immediately, got %d callback invocations", calls)
	}
}

// TestWalkSourceRecordsInaccessibleEntries pins the review finding that
// walkSource silently dropped entries when filepath.WalkDir delivered a
// per-entry error.
func TestWalkSourceRecordsInaccessibleEntries(t *testing.T) {
	if os.Geteuid() == 0 {
		t.Skip("running as root bypasses perm bits")
	}
	root := t.TempDir()
	writeFile(t, filepath.Join(root, "readable.go"), "package x\n")
	noPermDir := filepath.Join(root, "locked")
	if err := os.MkdirAll(noPermDir, 0o755); err != nil {
		t.Fatal(err)
	}
	writeFile(t, filepath.Join(noPermDir, "hidden.go"), "package y\n")
	if err := os.Chmod(noPermDir, 0o000); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.Chmod(noPermDir, 0o755) })

	var stats WalkStats
	err := walkSource(context.Background(), root, &stats, func(absPath, relPath string, d fs.DirEntry) error {
		return nil
	})
	if err != nil {
		t.Fatalf("walkSource: %v", err)
	}
	if stats.EntriesSkipped == 0 {
		t.Errorf("locked directory should have been recorded as skipped, got stats=%+v", stats)
	}
	if stats.FirstSkippedPath == "" {
		t.Errorf("FirstSkippedPath should be populated, got %+v", stats)
	}
}

// TestScanTODOsRecordsScannerTruncation pins the review finding that
// bufio.Scanner's ErrTooLong was swallowed silently. A file with a
// single line longer than the buffer now bumps stats.LinesTruncated.
func TestScanTODOsRecordsScannerTruncation(t *testing.T) {
	root := t.TempDir()
	// 2 MiB single line of non-NUL printable bytes — passes the binary
	// sniff but blows the scanner's 1 MiB max-token buffer.
	long := strings.Repeat("a", 2*1024*1024)
	writeFile(t, filepath.Join(root, "huge.go"), long+"\n// TODO past-the-eol\n")

	var stats WalkStats
	err := walkSource(context.Background(), root, &stats, func(absPath, relPath string, d fs.DirEntry) error {
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}

	// Run ScanTODOs end-to-end on the same root and confirm LinesTruncated.
	_, scanStats, scanErr := ScanTODOs(context.Background(), root, nil, time.Now())
	if scanErr != nil {
		t.Fatal(scanErr)
	}
	if scanStats.LinesTruncated == 0 {
		t.Errorf("scanner truncation should have been recorded: %+v", scanStats)
	}
}

// itoa avoids pulling strconv for this one helper.
func itoa(n int) string {
	if n == 0 {
		return "0"
	}
	var buf [20]byte
	i := len(buf)
	for n > 0 {
		i--
		buf[i] = byte('0' + n%10)
		n /= 10
	}
	return string(buf[i:])
}
