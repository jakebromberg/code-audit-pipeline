package cli

import (
	"runtime/debug"
	"testing"
)

func TestResolvedVersion(t *testing.T) {
	origVersion := Version
	origReader := readBuildInfo
	t.Cleanup(func() {
		Version = origVersion
		readBuildInfo = origReader
	})

	cases := []struct {
		name      string
		version   string
		buildInfo *debug.BuildInfo
		buildOK   bool
		want      string
	}{
		{
			name:      "ldflag override wins over BuildInfo",
			version:   "0.3.1",
			buildInfo: &debug.BuildInfo{Main: debug.Module{Version: "v0.3.1"}},
			buildOK:   true,
			want:      "0.3.1",
		},
		{
			name:      "BuildInfo fills in when Version is sentinel",
			version:   "0.1.0-skeleton",
			buildInfo: &debug.BuildInfo{Main: debug.Module{Version: "v0.3.1"}},
			buildOK:   true,
			want:      "v0.3.1",
		},
		{
			name:      "devel BuildInfo falls back to sentinel",
			version:   "0.1.0-skeleton",
			buildInfo: &debug.BuildInfo{Main: debug.Module{Version: "(devel)"}},
			buildOK:   true,
			want:      "0.1.0-skeleton",
		},
		{
			name:      "empty BuildInfo version falls back to sentinel",
			version:   "0.1.0-skeleton",
			buildInfo: &debug.BuildInfo{Main: debug.Module{Version: ""}},
			buildOK:   true,
			want:      "0.1.0-skeleton",
		},
		{
			name:    "no BuildInfo falls back to sentinel",
			version: "0.1.0-skeleton",
			buildOK: false,
			want:    "0.1.0-skeleton",
		},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			Version = tc.version
			readBuildInfo = func() (*debug.BuildInfo, bool) {
				return tc.buildInfo, tc.buildOK
			}
			if got := ResolvedVersion(); got != tc.want {
				t.Errorf("ResolvedVersion() = %q, want %q", got, tc.want)
			}
		})
	}
}
