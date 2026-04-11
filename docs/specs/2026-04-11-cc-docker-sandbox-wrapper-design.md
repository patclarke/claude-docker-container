# `cc` — Docker Sandbox Wrapper for Claude Code

**Date:** 2026-04-11
**Status:** Design approved, ready for implementation planning
**Scope:** Machine-wide tooling for a single developer (not enforced on other devs)

## Problem

Running `claude --dangerously-skip-permissions` on a trusted dev machine is a
calculated risk: a coding agent with unsupervised shell access can touch
anything the user can touch. The goal is to move that execution into an
isolated environment — microVM-level isolation via Docker Sandboxes (`sbx`) —
so `--dangerously-skip-permissions` becomes a bounded risk instead of an
unbounded one, while keeping the day-to-day Claude Code workflow essentially
unchanged.

Specifically:

- Host filesystem outside a small allow-list of mounts is invisible to the agent.
- The launch directory (typically a repo or a worktree under `~/workspace`) is
  read-write.
- Everything else under `~/workspace` is readable for cross-project context but
  not writable.
- Claude session history persists across launches and is shared with host
  Claude, so "don't lose context" holds.
- Existing `.worktrees/` git workflow and `~/.claude` plugins/skills keep
  working with zero modification.

## Non-goals

- Enforcing the sandbox workflow on other contributors to any repo.
- Adding a custom Docker image or modifying sbx's default agent image.
- Changing any existing `.worktrees/` git-workflow rule.
- Changing any repo-level config (CLAUDE.md, `.claude/`, hooks, MCP).
- Automated test harness (this is a wrapper script; validation is manual).

## Architecture

One moving part: a bash script at `~/bin/cc`. Everything else is configuration.

```
host (dev machine)
├── ~/bin/cc                       bash wrapper — only code we ship
├── ~/.config/cc/mounts.conf       mount policy, created on first run
├── ~/.zshrc                       one-line PATH addition (idempotent)
└── prerequisites
    ├── Docker Desktop             (already installed)
    ├── sbx CLI                    brew install docker/tap/sbx
    └── sbx login                  one-time
```

When invoked, `cc` executes three phases — **parse**, **plan**, **exec** —
then hands off to `sbx run claude ...`. No persistent wrapper state, no daemon,
no cache.

`claude` (unwrapped) stays on PATH as the always-available escape hatch. No
alias, no shadow. If Docker Desktop, sbx, or the wrapper itself breaks, `claude`
still works.

### Why one script per host and not per repo

Forcing a sandbox workflow on contributors to a shared repo is not enforceable
through a repo checkout — other devs can always ignore it. The honest framing
is: this is personal tooling for the developer's own execution environment,
published so others can opt in if they want.

## Mount model

### Resolution order

At plan time, the wrapper builds the mount list in this order:

1. **Primary mount:** `$PWD` (always, read-write). This becomes sbx's "main
   workspace" and the starting directory for the agent.
2. **Config file:** `~/.config/cc/mounts.conf`, one mount per line, `~`
   expanded, comment lines (`#`) and blanks ignored. Non-existent paths are
   skipped silently.
3. **Invocation adds:** each `--cc-mount <path>[:ro]` flag appends a mount.
4. **Invocation drops:** each `--cc-no-mount <path>` flag removes a matching
   entry by resolved absolute path.
5. **Dedupe:** if the same path appears twice, the later / more specific entry
   wins.
6. **Overlap handling:** see [Overlapping mounts](#overlapping-mounts) below.

### Default `~/.config/cc/mounts.conf`

Written automatically on first run if the file does not exist:

```
# Format:  <path>[:ro]
# No suffix = read-write. ":ro" = read-only.
# Non-existent paths are skipped silently at launch.

# Cross-project reference (read-only view of all sibling repos)
~/workspace:ro

# Ad-hoc file sharing from normal macOS locations
~/Desktop:ro
~/Downloads:ro

# Host config surfaced into the sandbox
~/.claude                 # RW — session persistence + plugins/skills
~/.aws:ro                 # AWS credentials read-only
~/.config/gh:ro           # gh CLI auth read-only
~/.ssh:ro                 # git over ssh read-only
```

### Read/write policy, in one table

| Path                 | Mode | Why                                                    |
|----------------------|------|--------------------------------------------------------|
| `$PWD` (launch dir)  | RW   | The actual work happens here                           |
| `~/workspace`        | RO   | Cross-project context; writes only via launch dir       |
| `~/Desktop`          | RO   | Share a file with the agent without moving it          |
| `~/Downloads`        | RO   | Same, for downloaded artifacts                         |
| `~/.claude`          | RW   | Session persistence; host ↔ sandbox visibility         |
| `~/.aws`             | RO   | Credentials available to code running in sandbox       |
| `~/.config/gh`       | RO   | `gh` CLI auth                                          |
| `~/.ssh`             | RO   | git over ssh                                           |

### Overlapping mounts

`$PWD` is usually under `~/workspace`, which means the mount list nests an RW
mount (cwd) inside an RO mount (`~/workspace`). In Linux bind-mount semantics
this is valid: the inner mount shadows the outer on that subpath. sbx should
pass this through to its microVM's mount namespace.

**First-run verification required.** If sbx rejects the nested form, the
wrapper catches `sbx run` stderr, detects a known overlap error pattern, and
**retries once** with a sibling-expansion fallback:

```
for each dir in ~/workspace/*:
  if dir is not $PWD and not an ancestor/descendant of $PWD:
    mount dir:ro
drop the blanket ~/workspace:ro
```

If the retry also fails, exit with an error and point the user at
`--cc-dry-run`. No third attempt.

### Session persistence

Because `~/.claude` is a live bind mount (not a copy), writes from inside the
sandbox land in the host's real `~/.claude/projects/<url-encoded-cwd>/`
directory. Inside the sandbox, cwd resolves to the same absolute host path
(sbx preserves absolute paths), so `claude -c` inside the sandbox reads the
same session files `claude -c` on the host would read.

This gives three properties:

1. Conversations survive `sbx rm`, OS reboots, or swapping sandbox images —
   none of that data lives *in* the sandbox.
2. A session started on the host can be resumed inside the sandbox, and vice
   versa, with `cc -c`.
3. `~/.claude/plugins/` (skill plugins like superpowers, ui-ux-pro-max, etc.)
   is visible inside the sandbox, so plugin skills work identically.

## Wrapper flags

`cc` reserves flags prefixed `--cc-*`. Everything else is forwarded unchanged
to `claude` inside the sandbox. No `--` separator required.

| Flag                      | Purpose                                                        |
|---------------------------|----------------------------------------------------------------|
| `--cc-name <label>`       | Named sandbox for parallelism (maps to `sbx --name`)           |
| `--cc-mount <path>[:ro]`  | Add a mount for this invocation (repeatable)                   |
| `--cc-no-mount <path>`    | Skip a config-file mount for this invocation (repeatable)      |
| `--cc-no-sandbox`         | Escape hatch: exec host `claude` directly, skip sbx entirely    |
| `--cc-rm [name]`          | Remove the sandbox for cwd (or named), prompts first           |
| `--cc-ls`                 | List active sandboxes                                          |
| `--cc-dry-run`            | Print the resolved `sbx run` command, do not exec              |
| `--cc-doctor`             | Run preflight checks + show resolved mount list                |
| `--cc-help`               | Usage                                                          |

### Typical invocations

```bash
# Day-to-day: resume most recent session in this dir
caffeinate -dims cc --remote-control --chrome -c

# Fresh session in this dir
cc

# Two parallel experiments in the same dir
cc --cc-name experiment-a -c
cc --cc-name experiment-b -c

# One-off: share a folder outside the config
cc --cc-mount ~/Projects/weird-experiment:ro -c

# One-off: don't let the sandbox see ~/Downloads this session
cc --cc-no-mount ~/Downloads

# Escape hatch
cc --cc-no-sandbox -c
# or just
claude -c
```

### Sandbox naming

When `--cc-name` isn't passed, the sandbox name is derived deterministically
from cwd:

```
<cwd-basename>-<first-6-chars-of-sha1(absolute-path)>
```

Example: `~/workspace/autorx-reports` → `autorx-reports-a3f91b`. Running `cc`
again from the same directory produces the same name, so sbx reconnects to the
same sandbox and installed packages, command history, and session files
persist.

## Preflight checks

Run on every invocation, before any planning. Each check has one of three
outcomes: pass silently, auto-remediate and continue, or fail with a concrete
remedy.

| # | Check                     | On fail                                                                                     |
|---|---------------------------|---------------------------------------------------------------------------------------------|
| 1 | `command -v sbx`          | Print brew install command, exit 1                                                          |
| 2 | `docker info`             | Auto-remediate: `open -a Docker`, poll up to **30 s**, then confirm `docker ps` works       |
| 3 | `sbx ls` (auth probe)     | Print "sbx is not authenticated. Run: sbx login", exit 1                                    |
| 4 | `[[ -w ~/.claude ]]`      | Hard error: "~/.claude is not writable. Session history would be lost"                      |
| 5 | Path sanity (per mount)   | Missing optional paths are WARN, not FAIL; only cwd is mandatory                            |
| 6 | `command -v claude`       | Only checked when `--cc-no-sandbox` is set                                                  |

Short-circuit: if `--cc-no-sandbox` is set, skip 1–5 entirely. The whole point
of the escape hatch is "sbx/docker are broken, I need to get work done."

Ordering: preflight runs on **every invocation**, no caching. Overhead is
~150–200 ms, negligible next to sbx boot time, and stale caches cause worse
bugs than they prevent.

### `--cc-doctor` output

```
cc doctor

  OK    ~/bin/cc is on PATH
  OK    sbx installed                (sbx 1.4.2)
  OK    Docker Desktop running       (Docker 28.3.0)
  OK    sbx authenticated
  OK    ~/.claude is writable
  OK    claude installed on host     (escape hatch available)

Mount plan (from ~/.config/cc/mounts.conf):
  RW    ~/.claude
  RO    ~/workspace
  RO    ~/Desktop
  RO    ~/Downloads
  RO    ~/.aws
  RO    ~/.config/gh
  RO    ~/.ssh

All checks passed.
```

Doctor output is cwd-independent — it does not evaluate the primary mount. Use
`--cc-dry-run` inside a specific directory to see the full invocation.

## Error handling

| Surface                    | Strategy                                                                                       |
|----------------------------|------------------------------------------------------------------------------------------------|
| Preflight failures         | Each check prints its own remedy and exits with a specific code                                |
| Mount planning failures    | Missing cwd → exit 1. Nested overlap rejection → one retry with sibling fallback, then exit    |
| Docker Desktop race        | After `docker info` succeeds, also wait for `docker ps` to succeed (proves daemon accepts ops) |
| Interrupted preflight      | Trap SIGINT: print "interrupted during preflight", exit 130                                    |
| Sandbox runtime failures   | sbx owns the error output. Do not translate.                                                   |
| Ctrl-C inside the agent    | Forwarded to sbx child via `trap 'kill -s INT "$sbx_pid"' INT TERM`                            |

Logging: stderr only. No `~/.cache/cc/` log file. The wrapper is a thin shim;
anything worth logging belongs to sbx or claude.

Things the wrapper deliberately does not handle: sbx bugs, claude session
corruption, disk-full inside the VM, network failures inside the sandbox. Each
is owned by a layer below us; letting those errors surface untranslated gives
better debugging than a wrapper layer of translation.

## Implementation phases

The wrapper runs in three phases on every invocation:

### 1. Parse
Walk `$@` once. Any arg starting with `--cc-` is consumed as a wrapper flag;
everything else appends to a `CLAUDE_ARGS` array for forwarding.

### 2. Plan
- Run preflight checks (sections above).
- Read `~/.config/cc/mounts.conf` (create from defaults if missing).
- Apply `--cc-mount` adds and `--cc-no-mount` drops.
- Compute sandbox name.
- Build the final `sbx run claude` argv.

### 3. Exec
- If `--cc-dry-run`: print the argv and exit 0.
- If `--cc-no-sandbox`: `exec claude "${CLAUDE_ARGS[@]}"`.
- Otherwise run `sbx run` foregrounded (not `exec`'d), forwarding SIGINT/SIGTERM
  to the child, capturing exit code. If sbx exits non-zero and its stderr
  matches the known mount-overlap error pattern, retry once with the
  sibling-expansion fallback. On any other non-zero exit, propagate sbx's exit
  code unchanged. On zero exit, return 0.

Why not `exec sbx`? Because the mount-overlap fallback has to see sbx's stderr
and decide whether to retry. That decision has to happen in the wrapper process,
so the wrapper has to stay alive across the sbx call. Signal forwarding is
handled with a standard `trap 'kill -s INT "$sbx_pid"' INT TERM` pattern —
interactive Ctrl-C still reaches claude inside the sandbox.

### sbx argument syntax — one unknown

The exact form for passing CLI args to the agent inside sbx (`sbx run claude
<mounts> -- <claude-args>` or some other shape) isn't fully confirmed in the
docs reviewed during design. The wrapper tries the `--` separator first; if
sbx errors, inspect `sbx run claude --help` on the host and adjust. This is a
one-line fix and does not affect the overall design.

## Validation checklist

No automated tests. Walk through this manually after first install.

### Install
- [ ] `brew install docker/tap/sbx`
- [ ] `sbx login`
- [ ] Drop `~/bin/cc` in place, `chmod +x`
- [ ] `~/bin` on PATH (`which cc` → `~/bin/cc`)
- [ ] First `cc --cc-doctor` run creates `~/.config/cc/mounts.conf`

### Preflight matrix (`cc --cc-doctor`)
- [ ] Clean run → all OK
- [ ] Quit Docker Desktop → FAIL "Docker Desktop running"
- [ ] Rename sbx temporarily → FAIL "sbx installed"
- [ ] `chmod -w ~/.claude` (restore after) → FAIL "~/.claude is writable"
- [ ] `mv ~/.aws ~/.aws.bak` → WARN "~/.aws exists", not FAIL

### Core invocation matrix (from a real repo under `~/workspace`)
- [ ] `cc --cc-dry-run` → prints full mount list with nested cwd + `~/workspace`
- [ ] `cc` → launches sandbox, fresh session
- [ ] `cc -c` → reconnects same sandbox, resumes most recent session
- [ ] `cc --remote-control --chrome -c` → flags pass through, Chrome MCP works
- [ ] `cc --cc-name experiment-1` → new parallel sandbox, same cwd
- [ ] `cc --cc-ls` → lists both sandboxes
- [ ] `cc --cc-no-sandbox -c` → plain host claude, no sbx
- [ ] `cc --cc-rm` → prompts, removes
- [ ] `cc --cc-mount ~/tmp/scratch:ro` → extra mount appears in dry-run
- [ ] `cc --cc-no-mount ~/Downloads` → Downloads missing from dry-run

### Worktree sanity (from a `.worktrees/feat-foo` dir)
- [ ] Primary mount is the worktree path
- [ ] `git status` inside sandbox reports worktree branch
- [ ] `git push` works (via `~/.ssh` or `~/.config/gh`)

### Three first-run unknowns to confirm
1. **sbx arg-passing syntax** — `cc -c` actually resumes a session
2. **Nested mount handling** — nested form works, or sibling fallback triggers
   and Claude sees sibling repos read-only
3. **`~/.claude` cross-visibility** — start a session with host `claude`, exit,
   run `cc -c`, confirm the same session resumes

### Failure-mode spot checks
- [ ] Quit Docker Desktop mid-session → sbx errors, `cc` returns non-zero,
      next invocation auto-starts Docker and recovers
- [ ] Ctrl-C during the 30 s Docker wait → "interrupted during preflight"
- [ ] `cc` from `~/Desktop/scratch` (outside `~/workspace`) → primary mount is
      that dir, `~/workspace:ro` still mounts as a sibling

## README coverage

The README (updated as part of implementation) documents:

1. Prerequisites: Docker Desktop, `brew install docker/tap/sbx`, `sbx login`.
2. Install: drop the script, PATH line, run `cc --cc-doctor`.
3. `~/.config/cc/mounts.conf` location and format.
4. Default mount contents and what each line does.
5. How to add a durable mount (edit the file, one example).
6. How to remove a durable mount (delete or comment out the line).
7. How to temporarily add/skip a mount (`--cc-mount` / `--cc-no-mount`).
8. Security model: RW vs RO, what the sandbox can see, what it can't,
   where `--dangerously-skip-permissions` fits in.
9. Common customizations (e.g. "I keep notes in `~/Notes`, mount them RO";
   "I don't trust `~/Downloads`, drop it from defaults").
10. Escape hatches: `--cc-no-sandbox` and bare `claude`.

## Out of scope for this spec

These are deliberate omissions, not oversights:

- **Custom sandbox image.** sbx's default agent image is sufficient.
- **Per-repo hooks.** No `.claude/settings.json` changes in any repo.
- **Cross-host sync.** This is for one machine.
- **Automated test harness.** Manual validation is adequate for a wrapper
  script.
- **Config for anything but mounts.** Docker start timeout (30s), sandbox name
  hash format, etc. are hardcoded. If any needs to change later, it moves to
  the config file then.
- **Enforcement on other devs.** Doc-only; no one is forced to use `cc`.
