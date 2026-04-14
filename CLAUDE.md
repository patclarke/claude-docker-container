# CLAUDE.md

This file provides guidance to Claude Code when working in this repository.

## Project overview

`claude-docker-container` ships a single bash script — `cdc` — that wraps
Claude Code invocations in a [Docker Sandbox](https://docs.docker.com/ai/sandboxes/)
microVM, so unsupervised agents have a bounded blast radius instead of an
unbounded one. See [`README.md`](README.md) for user-facing documentation.

The implementation is intentionally small: one shell script, one config file,
one README. Resist the urge to grow it into a framework.

**Auth flow:** `cdc` extracts the Claude Code token from the macOS Keychain
(`security find-generic-password -s 'Claude Code-credentials'`) and injects it
into the sandbox on every invocation via `sbx exec`. Claude inside the sandbox
runs as user `agent` and looks for credentials at
`/home/agent/.claude/.credentials.json`.

## Repository layout

```
.
├── bin/cdc                 the wrapper script
├── README.md               user-facing documentation
├── CLAUDE.md               this file
├── LICENSE                 MIT
└── .gitignore              ignores .worktrees/ and local docs/
```

**`docs/` is gitignored.** It's reserved for local brainstorming and design
scratch files — the design spec that drove the initial implementation lives
there on the author's machine and is deliberately *not* committed to the
public repo. If you need to reference design history, look for it locally; do
not try to reconstruct it from git history.

## How to think about the script

`cdc` runs in three phases on every invocation. When modifying it, keep these
phases distinct — do not interleave parsing with planning or planning with
execution.

1. **Parse.** Walk `$@` once. Any arg starting with `--cdc-` is a wrapper flag
   and gets consumed; everything else goes into a `CLAUDE_ARGS` array to be
   forwarded verbatim to `claude` inside the sandbox.
2. **Plan.** Run preflight checks. Read `~/.config/cdc/mounts.conf` (create it
   from defaults if missing). Apply `--cdc-mount` additions and `--cdc-no-mount`
   removals. Strip ancestor mounts. Compute a deterministic sandbox name from
   cwd. Build the final `sbx` argv.
3. **Exec.** If the named sandbox doesn't exist, create it with
   `sbx create claude <primary> <mounts>`. Then inject credentials via
   `sbx exec -i`, create sharing symlinks via `sbx exec`, and finally attach
   with `sbx exec -it <name> env ... claude <claude-args>` in the foreground
   (not via `exec` — we need to return to cdc after claude exits for cleanup).
   `sbx exec` auto-starts a stopped sandbox (per `sbx exec --help`), so a
   prior cdc session that ended in `sbx stop` re-attaches transparently — no
   explicit start step needed. If the first attach exits 137 (sbx rapid-call
   race — see lesson 5), retry once after a longer wait. After claude exits,
   `cdc` runs `sbx stop` to free the microVM's resources. Pass
   `--cdc-keep-running` to skip the stop. Propagate sbx's exit code.

The `--cdc-dry-run`, `--cdc-doctor`, and `--cdc-no-sandbox` flags short-circuit
the exec phase in different ways; they still run parse and the relevant parts
of plan.

## Lessons from first-run validation

The original design spec had three "unknowns" that live testing resolved:

1. **sbx arg-passing syntax:** `sbx run <sandbox> -- <claude-args>` works, but
   `sbx run` itself misbehaves with our credential + symlink flow and sends
   SIGKILL to claude at startup. cdc uses `sbx exec` as the attach mechanism
   instead, losing some of sbx's agent-launcher niceties but gaining reliable
   exec.

2. **Nested mounts:** sbx accepts overlapping mounts at the parse level but
   its container-start hooks fail when the cwd's parent directory is under an
   RO mount (the hook tries to write a CLAUDE.md one level above cwd and hits
   a read-only filesystem). cdc strips any mount that is an ancestor of the
   current cwd from the resolved mount list as a general rule.

3. **`~/.claude` cross-visibility:** inside the sandbox, `HOME=/home/agent`
   and claude reads its config from `/home/agent/.claude/`. The host's
   `~/.claude` at `/Users/<you>/.claude` is not automatically discovered.
   Solution: mount specific subpaths (`projects`, `plugins`, `skills`) as
   additional workspaces at their absolute host paths, then symlink
   `/home/agent/.claude/{projects,plugins,skills}` to those host paths
   post-create via `sbx exec`. Credentials are injected separately via
   `sbx exec -i` pipe from `security find-generic-password`.

Additional runtime surprises found during implementation:

4. **The primary workspace trap:** sbx mounts the primary workspace at its
   **absolute host path** (same as additional workspaces) via virtiofs, but
   drops the agent into `/home/agent/workspace` — an empty directory in the
   sandbox image that is NOT a mount and NOT a symlink. If you don't
   explicitly set the working directory, claude starts in an empty dir and
   reports "no files found" no matter what is in the host path. Fix:
   `sbx exec -w <host-path>` when attaching so claude starts in the real
   mounted location. This is `bin/cdc`'s `build_sbx_argv` behavior — see
   the `-w "$pwd_abs"` argument. Reported by @wmaykut as issue #6.

5. **sbx rapid-call race:** Running several sbx subcommands back-to-back
   (`create`, `exec` for inject, `exec` for symlinks, final `exec` to
   attach) leaves the sbx daemon in a state where the next interactive
   exec is SIGKILL'd at startup (exit 137). A 1-second `sleep` before the
   final attach usually avoids this, but not always — `run_sandbox` also
   retries the attach once on exit 137 with a longer wait. Worth reporting
   upstream.

6. **`bash -x` leaks secrets:** The first version of `inject_credentials`
   stored the extracted Keychain token in a shell variable, which
   `bash -x` would expand and print to stderr. The current version pipes
   directly from `security` into `sbx exec -i` without an intermediate
   variable.

7. **TERM/COLORTERM env passthrough:** `sbx exec` does not inherit the
   host's terminal environment. Claude inside the sandbox defaults to
   minimal/no-color output unless we explicitly wrap the invocation in
   `env TERM=... COLORTERM=...`.

Key sbx facts that govern the implementation:

- **Primary workspace path:** sbx mounts the primary workspace at its
  absolute host path via virtiofs bind mount, same as additional mounts.
  It does NOT symlink `/home/agent/workspace` to the mount. `cdc` sets the
  initial working directory with `sbx exec -w` to land the agent at the
  real host path.
- **sbx has no env var flag:** `sbx create` only supports `--branch`,
  `--memory`, `--name`, `--template`. Credentials and other config must be
  injected via `sbx exec`.
- **Bypass mode is the default:** sbx's claude image has
  `"defaultMode": "bypassPermissions"` pre-configured in
  `/home/agent/.claude/settings.json`. Do not add any bypass flag as a
  default in `cdc`.
- **Create vs. attach:** Passing workspace paths to an existing sandbox errors
  with "sandbox X already exists and can't be given new workspaces". The
  correct flow: `sbx create claude <primary> <mounts>` once, then
  `sbx exec` on every subsequent attach.
- **Stopped vs. running:** `sbx exec` auto-starts a stopped sandbox before
  running the command (per `sbx exec --help`). cdc relies on this — the
  cdc-side post-exit `sbx stop` is for resource cleanup, and the next attach
  re-starts the sandbox transparently. There is no `sbx start` subcommand.

## Code style

### Bash

- Shebang: `#!/usr/bin/env bash`
- `set -euo pipefail` at the top
- Quote all variable expansions: `"$var"`, not `$var`
- Prefer `[[ … ]]` over `[ … ]` for conditionals
- Functions over repeated inline blocks
- Functions under ~50 lines, ideally under 20
- Nesting no more than 3 levels deep
- Descriptive names — no single-letter variables except loop counters

### General

- Comments explain *why*, not *what*. If the code needs a comment to be
  readable, simplify the code.
- Delete dead code; don't comment it out
- KISS — the simplest solution that works. Abstractions only after the third
  duplication, never preemptively.
- YAGNI — don't add configuration for values that don't change. Don't add
  flags that solve hypothetical problems.

### What this script deliberately is not

- It is **not a config manager**. Only mount paths are configurable; every
  other parameter (sandbox name hash format, preflight check list) is
  hardcoded. If something new needs to change, think twice
  before moving it to config.
- It is **not a container orchestrator**. It forwards to `sbx` and lets
  sbx own sandbox lifecycle.
- It is **not a Claude Code replacement**. It wraps the `claude` binary
  without trying to understand its flags, and `claude` is always available
  unwrapped as an escape hatch.

## Git workflow

### Always use worktrees

Never work directly in the main checkout. Always create a worktree for each
unit of work, even for one-file changes:

```bash
git checkout main && git pull origin main
git worktree add .worktrees/<type>-<short-description> -b <type>/<short-description>
cd .worktrees/<type>-<short-description>
```

Branch prefixes: `feat/`, `fix/`, `chore/`, `docs/`, `refactor/`, `test/`,
`perf/`.

### Branch check before every change

```bash
git fetch origin
git merge-base --is-ancestor origin/main HEAD || git pull origin main
```

### Never push to main, never force push

- Never push directly to `main`. Always open a PR via `gh pr create`.
- Never force push. If a branch is behind `main`, merge `main` into it.

### Commit messages

Conventional format:

- `feat: add user authentication`
- `fix: resolve null pointer in parser`
- `chore: update dependencies`
- `docs: add API documentation`
- `refactor: simplify error handling`

## Testing

There is **no automated test suite.** This is a bash wrapper around a CLI on
a specific developer machine; the validation model is a manual checklist.

When changing `bin/cdc`, walk through the full validation matrix before opening
a PR:

1. **Preflight matrix.** Run `cdc --cdc-doctor` with each dependency
   intentionally broken, confirm the right FAIL lines appear with actionable
   remedies. Restore state.
2. **Core invocation matrix.** From a real project under `~/workspace`,
   exercise `cdc`, `cdc -c`, `cdc --cdc-name experiment-1`, `cdc --cdc-no-sandbox`,
   `cdc --cdc-dry-run`, `cdc --cdc-ls`, `cdc --cdc-rm`.
3. **Mount override matrix.** Confirm `--cdc-mount` additions and
   `--cdc-no-mount` removals appear correctly in `--cdc-dry-run` output.
4. **Worktree sanity.** Run `cdc` from a `.worktrees/feat-foo` directory under
   another repo and confirm the primary mount is the worktree path, not the
   main checkout.
5. **Failure spot checks.** Run from a directory outside `~/workspace`; break
   `sbx` (uninstall or deauthenticate) and confirm its error surfaces cleanly.
   `cdc` itself does not probe for Docker — `sbx` owns its environment.

Shell lint:

```bash
shellcheck bin/cdc
shfmt -d bin/cdc
```

Install if missing: `brew install shellcheck shfmt`.

## Scope discipline

This repo intentionally does one thing. **Do not** add:

- A custom sandbox Dockerfile. sbx's default agent image is sufficient.
- A Python / Node / Go rewrite. Bash is the right tool for a < 300 line
  wrapper around another CLI.
- Cross-host state sync, a daemon, a plugin system, or a TUI. They belong in
  a different project.
- Automated test harnesses. Manual validation is adequate for a wrapper
  script and the overhead of setting up test infrastructure around `sbx`
  would dwarf the script itself.

If a change you're considering doesn't fit in a `feat:` or `fix:` commit
against `bin/cdc`, `README.md`, `CLAUDE.md`, or `.gitignore`, it probably
doesn't belong in this repo.

**Plugin and skill installation:** plugins and skills must be installed on the
host (`claude` without `cdc`), not inside a sandbox. The sandbox mounts
`~/.claude/plugins` and `~/.claude/skills` read-only to prevent a runaway
sandbox from injecting malicious code into host-side executable paths. Any
plugin installed inside a sandbox is lost when the session ends.

- **Do not install plugins or skills from inside a sandbox session.** Plugins
  and skills are mounted read-only from the host at
  `/Users/<you>/.claude/plugins` and `/Users/<you>/.claude/skills`. A plugin
  install from inside the sandbox will either fail or write to a scratch
  location that vanishes when the sandbox is removed. Install plugins from
  a host claude session instead (plain `claude`, not via `cdc`).
