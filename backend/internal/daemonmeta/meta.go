package daemonmeta

import (
	"runtime/debug"
	"sync"
)

// ServiceName identifies the AO daemon in loopback health/readiness probes.
// The CLI uses it with the reported PID to avoid signaling an unrelated process
// when a stale run-file's PID has been reused.
const ServiceName = "agent-orchestrator-daemon"

var (
	buildIDOnce sync.Once
	buildID     string
)

// BuildID identifies the source this binary was built from, for detecting a
// client and a daemon that have drifted apart.
//
// It exists for remote workspaces: the client talks to a daemon installed
// separately on another machine, and nothing stops the two from being different
// builds. When they are, the client calls routes the daemon has never heard of
// and the user sees a bare 405 from deep inside the UI instead of "that machine
// is running an older AO". Version strings cannot answer this — every
// development build reports the same "dev" — so the VCS revision Go already
// stamps into the binary is used instead.
//
// Returns "" when the revision is unavailable (built outside a repository, or
// with -buildvcs=false). Callers MUST treat an empty value on either side as
// "cannot tell" and skip the comparison: a guard that fires when it has no
// evidence is worse than no guard, because it would refuse healthy setups.
func BuildID() string {
	buildIDOnce.Do(func() {
		info, ok := debug.ReadBuildInfo()
		if !ok {
			return
		}
		var revision, modified string
		for _, setting := range info.Settings {
			switch setting.Key {
			case "vcs.revision":
				revision = setting.Value
			case "vcs.modified":
				modified = setting.Value
			}
		}
		if revision == "" {
			return
		}
		if len(revision) > 12 {
			revision = revision[:12]
		}
		// A dirty tree is not the commit it claims to be. Mark it, so two builds
		// from the same revision with different uncommitted changes are not
		// reported as identical.
		if modified == "true" {
			revision += "-dirty"
		}
		buildID = revision
	})
	return buildID
}
