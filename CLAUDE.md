# CLAUDE.md

This file provides guidance to Claude Code when working in this repository.

## Project overview

`claude-docker-sandbox` ships a single bash script — `cc` — that wraps
Claude Code invocations in a [Docker Sandbox](https://docs.docker.com/ai/sandboxes/)
microVM, so `--dangerously-skip-permissions` can be used with a bounded blast
radius instead of an unbounded one. See [`README.md`](README.md) for
user-facing documentation.

The implementation is intentionally small: one shell script, one config file,
one README. Resist the urge to grow it into a framework.

## Repository layout

```
.
├── bin/cc                  the wrapper script (not yet written)
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
   removals. Compute a deterministic sandbox name from cwd. Build the final
   `sbx run claude` argv.
3. **Exec.** Run `sbx run` foregrounded (not `exec`'d), forwarding signals.
   If sbx exits non-zero with a known mount-overlap error, retry once with the
   sibling-expansion fallback. Otherwise propagate sbx's exit code.

The `--cc-dry-run`, `--cc-doctor`, and `--cc-no-sandbox` flags short-circuit
the exec phase in different ways; they still run parse and the relevant parts
of plan.

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
- It is **not a container orchestrator**. It forwards to `sbx run` and lets
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

## Three first-run unknowns

The design has three places where real sbx behavior needs to be verified on
first run rather than assumed:

1. **sbx arg-passing syntax.** The plausible guess is
   `sbx run claude <mounts> -- <claude-args>`. On first run, if `cc -c`
   doesn't resume a session or `claude` complains about `-c`, inspect
   `sbx run claude --help` and adjust.
2. **Nested mount handling.** `$PWD` (RW) sits inside `~/workspace` (RO).
   Linux bind-mount semantics say the inner mount should shadow the outer on
   its subpath, but sbx's microVM may or may not pass that through. If
   rejected, the script retries once with a sibling-expansion fallback (see
   `bin/cc` plan phase).
3. **`~/.claude` cross-visibility.** The session-persistence story hinges on
   `~/.claude` being a live bind mount and cwd resolving to the same absolute
   path inside the sandbox. Verify by starting a session with host `claude`,
   exiting, running `cc -c`, and confirming the same session resumes.

If any of these break in a way that can't be patched with a one-line fix,
open an issue documenting what sbx actually does.

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
