# Fork notes

Personal fork of [Untrivial-ai/agent-orchestrator](https://github.com/Untrivial-ai/agent-orchestrator).

**What this fork adds: remote workspaces.** A workspace is a machine that runs
its own AO daemon. `local` behaves exactly like upstream; a remote workspace is
an SSH target the Electron supervisor reaches through a loopback port-forward,
so you can sit on a laptop and run every agent on the VM that actually holds
your code, compute and credentials.

Design and rejected alternatives: [`docs/adr/0002-remote-workspaces-over-ssh.md`](docs/adr/0002-remote-workspaces-over-ssh.md).

Offered upstream as [PR #3883](https://github.com/Untrivial-ai/agent-orchestrator/pull/3883)
/ [issue #3853](https://github.com/Untrivial-ai/agent-orchestrator/issues/3853),
both still open. The fork does not wait on them.

## Remotes and branches

| Remote | Use |
|---|---|
| `origin` | this fork — push here |
| `upstream` | Untrivial-ai — fetch only (push URL deliberately set to `DISABLED_use_origin`) |

`main` is **this fork's product line**, not a mirror of upstream. Upstream is
merged into it (see Syncing). Do not expect `main` to fast-forward from
`upstream/main`.

## What the fork actually costs to maintain

Less than it looks. The feature is **almost entirely in `frontend/src`** — no
migration, and none of the generated artifacts are touched. That is a
consequence of the architecture, not luck: the remote side runs an ordinary AO
daemon, so nothing in Go had to learn about SSH.

The one exception is the build-id skew guard (`daemonmeta.BuildID`, reported on
`/healthz`, plus a hidden `ao build-id`). It is in Go because it has to be: the
client and the remote daemon are separate installations that drift, and only the
daemon can say what it was built from. Three small files, none of them
churn-prone. Treat any *further* backend change as a design smell — if the fork
starts teaching the daemon about remoteness, the architecture has slipped back
toward the session-placement design this one replaced.

New files (can never conflict):

```
backend/internal/daemonmeta/meta.go      BuildID (also touches httpd/router.go,
                                         cli/root.go — a few lines each)
frontend/src/shared/workspaces.ts        registry model + resolution order
frontend/src/shared/ssh-command.ts       argv builders
frontend/src/shared/ssh-failure.ts       failure taxonomy
frontend/src/shared/ssh-config.ts        ~/.ssh/config parsing
frontend/src/main/workspace-registry.ts  ~/.ao/workspaces.json
frontend/src/main/remote-workspace.ts    connect / start / tunnel / re-dial
frontend/src/main/ssh-config.ts          config reader
frontend/src/renderer/hooks/useWorkspaces.ts
frontend/src/renderer/components/settings/WorkspacesSection.tsx
```

Upstream files modified — this is the entire conflict surface:

| File | Why | Conflict risk |
|---|---|---|
| `frontend/src/main.ts` | placement in the daemon lifecycle + IPC | **high** — big, churned file |
| `frontend/src/renderer/components/GlobalSettingsForm.tsx` | mounts the section | **high** — already restructured upstream |
| `frontend/src/preload.ts` | `workspaces` bridge | medium |
| `frontend/src/renderer/lib/bridge.ts` | browser fallback stub | medium |
| `frontend/src/renderer/test/setup.ts` | test stub | medium |
| `frontend/src/shared/daemon-status.ts` | `workspaceId` + remote failure codes | low |
| `frontend/src/renderer/i18n/*.json` | 8 locales | **conflicts every sync** — see below |

### Resolving the two that actually conflict

Learned from the first sync (140 upstream commits). `main.ts`, `preload.ts`,
`bridge.ts` and `setup.ts` all auto-merged; only these two needed hands.

**`GlobalSettingsForm.tsx` — take upstream wholesale, re-apply two lines.**
Upstream restructures this file freely (it moved the dialogs out to callbacks,
dropped a section, added a `grouped` prop). Merging line by line just fits the
fork into a shape that no longer exists. Instead:

```bash
git show upstream/main:frontend/src/renderer/components/GlobalSettingsForm.tsx > <that path>
```

then re-add the `WorkspacesSection` import + `useShellMaybe`, the `daemonStatus`
line, and the `<WorkspacesSection daemonStatus={daemonStatus} />` mount. Two
insertions, every time.

**Locale JSONs — union, restricted to `workspaces.*`.** Both sides append new
keys at the tail, so all eight conflict on every sync. The resolution is
upstream's file plus the fork's keys — and **only** keys starting with
`workspaces.`. Other keys present on the fork side but absent upstream are ones
upstream *deleted*; carrying them forward resurrects dead strings (the first
sync would have restored five). A script that blindly unions the two sides gets
this wrong.

**Keep the wire-up thin.** Every line added to an upstream file is a line that
conflicts later; prefer a one-line call into a fork-owned module over inline
logic. That rule is why the list above is short, and it is the main thing to
protect.

## Syncing with upstream

```bash
./scripts/sync-upstream.sh
```

Merges `upstream/main` into the current branch and auto-resolves generated
artifacts by regenerating them rather than hand-merging. Nothing this fork
touches is generated today, so that path should stay quiet — it exists because
upstream conflicts on those files constantly and hand-merging them is always
wrong.

## Upstream's hard rules still apply

They are engineering constraints, not review policy:

- **The daemon binds `127.0.0.1` only** (`backend/internal/config/config.go`).
  SSH is the transport precisely because it needs no new bind — neither daemon's
  bind changes and no listener is added, so unlike the LAN listener (ADR-0001)
  this needs no exception to the rule.
- **A failed or unknown probe is not proof a session is dead** (`AGENTS.md`). A
  dropped tunnel says nothing about the remote daemon, which keeps running; it
  must surface as reconnecting, never as the session dying.
- **All local state under `~/.ao`** — and remote state under the *remote*
  `~/.ao`. Each daemon owns its own.

## Traps found the hard way

All four were found by connecting to a real VM, and none was reachable from a
unit test. Full detail in the ADR; the short version:

1. `ssh` joins its argv into one string and the remote login shell re-splits it.
   Remote scripts **must** be quoted, or `/bin/sh -c command -v ao` silently
   runs the no-op `command` builtin and every probe passes vacuously.
2. `ControlMaster=auto` + `ControlPersist` makes `ssh -N` fork to the background
   and exit 0. The tunnel must run **unmultiplexed in the foreground** so its
   process lifetime is the forward's lifetime.
3. The remote port cannot be assumed. `AO_PORT` is a request; a busy port makes
   the daemon bind elsewhere and record it in `~/.ao/running.json`. Read the
   run-file.
4. Concurrent connects each spawn a tunnel unless de-duplicated. The local
   daemon path's in-flight guard runs *after* the remote branch.

## Toolchain

- **Go 1.26.5** via brew; `backend/go.mod` requires ≥ 1.25.7
- Node 22 local; CI uses 20 for frontend, 24 for the go workflow's node step

### Known pre-existing failures on a clean upstream tree

Not caused by this fork — do not chase them:

- `TestWorkspaceFilesIncludeWorkspaceProjectChildRepoDiffs`
  (`internal/service/session/service_test.go`) depends on git's default branch
  name. Apple's Command Line Tools ship a **system** gitconfig with
  `init.defaultBranch=main`; Linux CI defaults to `master`. Run the suite the
  way CI does:

  ```bash
  GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=init.defaultBranch GIT_CONFIG_VALUE_0=master go test ./...
  ```

- `frontend` `src/landing/**` — several tests fail on a clean tree.
- `internal/adapters/agent/{kilocode,opencode}` are flaky: 3s context deadlines
  that trip under parallel load and pass on rerun.
