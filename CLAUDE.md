# CLAUDE.md

This file provides guidance to Claude Code when working in this repository.

## Project overview

`claude-docker-sandbox` ships a single bash script — `cc` — that wraps
Claude Code invocations in a [Docker Sandbox](https://docs.docker.com/ai/sandboxes/)
microVM, so unsupervised agents have a bounded blast radius instead of an
unbounded one. See [`README.md`](README.md) for user-facing documentation.

The implementation is intentionally small: one shell script, one config file,
one README. Resist the urge to grow it into a framework.

**Auth flow:** `cc` extracts the Claude Code token from the macOS Keychain
(`security find-generic-password -s 'Claude Code-credentials'`) and injects it
into the sandbox on every invocation via `sbx exec`. Claude inside the sandbox
runs as user `agent` and looks for credentials at
`/home/agent/.claude/.credentials.json`.

## Repository layout

```
.
├── bin/cc                  the wrapper script
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

`cc` runs in three phases on every invocation. When modifying it, keep these
phases distinct — do not interleave parsing with planning or planning with
execution.

1. **Parse.** Walk `$@` once. Any arg starting with `--cc-` is a wrapper flag
   and gets consumed; everything else goes into a `CLAUDE_ARGS` array to be
   forwarded verbatim to `claude` inside the sandbox.
2. **Plan.** Run preflight checks. Read `~/.config/cc/mounts.conf` (create it
   from defaults if missing). Apply `--cc-mount` additions and `--cc-no-mount`
   removals. Strip ancestor mounts. Compute a deterministic sandbox name from
   cwd. Build the final `sbx` argv.
3. **Exec.** If the named sandbox doesn't exist, create it with
   `sbx create claude <primary> <mounts>`. Then inject credentials via
   `sbx exec`. Then create sharing symlinks via `sbx exec`. Finally attach
   with `sbx run <name> -- <claude-args>`, foregrounded with signal forwarding.
   Propagate sbx's exit code.

The `--cc-dry-run`, `--cc-doctor`, and `--cc-no-sandbox` flags short-circuit
the exec phase in different ways; they still run parse and the relevant parts
of plan.

## Key sbx behaviors (verified in live testing)

These were the three first-run unknowns from the original design. All are now
resolved:

1. **Primary workspace path.** sbx remaps the primary workspace to
   `/home/agent/workspace` inside the container. It does NOT preserve the
   absolute host path for the primary mount. Additional mounts (e.g. `~/.aws`)
   DO land at their absolute host paths inside the sandbox.

2. **Nested mounts fail.** When cwd is inside `~/workspace` and both are
   mounted, sbx's container-start hook tries to chown the cwd's parent
   directory (inside the RO parent mount) and fails with "Read-only file
   system". Fix: `strip_cwd_ancestors` removes any mount that is a strict
   ancestor of `$PWD` before passing the list to sbx.

3. **Auth.** Claude inside the sandbox runs as user `agent` with
   `HOME=/home/agent`. It looks for credentials at
   `/home/agent/.claude/.credentials.json`. A bind mount of `~/.claude` at its
   absolute host path doesn't help because sbx has no env var flag to remap
   `$HOME`. Fix: `inject_credentials` extracts the token from the macOS
   Keychain non-interactively and writes it to the correct path via `sbx exec`.

4. **sbx has no env var flag.** `sbx run --help` only supports `--branch`,
   `--memory`, `--name`, `--template`. There is no way to pass env vars via
   sbx. Credentials and other config must be injected via `sbx exec`.

5. **Bypass mode is the default.** sbx's claude image has
   `"defaultMode": "bypassPermissions"` pre-configured in
   `/home/agent/.claude/settings.json`. Do not add any bypass flag as a
   default in `cc`.

6. **Create vs. attach.** Passing workspace paths to an existing sandbox errors
   with "sandbox X already exists and can't be given new workspaces". The
   correct flow: `sbx create claude <primary> <mounts>` once, then
   `sbx run <name>` on every subsequent attach.

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
  other parameter (Docker start timeout, sandbox name hash format, preflight
  check list) is hardcoded. If something new needs to change, think twice
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

When changing `bin/cc`, walk through the full validation matrix before opening
a PR:

1. **Preflight matrix.** Run `cc --cc-doctor` with each dependency
   intentionally broken, confirm the right FAIL lines appear with actionable
   remedies. Restore state.
2. **Core invocation matrix.** From a real project under `~/workspace`,
   exercise `cc`, `cc -c`, `cc --cc-name experiment-1`, `cc --cc-no-sandbox`,
   `cc --cc-dry-run`, `cc --cc-ls`, `cc --cc-rm`.
3. **Mount override matrix.** Confirm `--cc-mount` additions and
   `--cc-no-mount` removals appear correctly in `--cc-dry-run` output.
4. **Worktree sanity.** Run `cc` from a `.worktrees/feat-foo` directory under
   another repo and confirm the primary mount is the worktree path, not the
   main checkout.
5. **Failure spot checks.** Quit Docker Desktop mid-session, Ctrl-C during the
   30 s Docker wait, run from a directory outside `~/workspace`.

Shell lint:

```bash
shellcheck bin/cc
shfmt -d bin/cc
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
against `bin/cc`, `README.md`, `CLAUDE.md`, or `.gitignore`, it probably
doesn't belong in this repo.

**Plugin and skill installation:** plugins and skills must be installed on the
host (`claude` without `cc`), not inside a sandbox. The sandbox mounts
`~/.claude/plugins` and `~/.claude/skills` read-only to prevent a runaway
sandbox from injecting malicious code into host-side executable paths. Any
plugin installed inside a sandbox is lost when the session ends.
