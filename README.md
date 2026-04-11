# claude-docker-sandbox

`cc` — a small bash wrapper that runs [Claude Code](https://claude.com/claude-code)
inside a [Docker Sandbox](https://docs.docker.com/ai/sandboxes/) microVM, so
`--dangerously-skip-permissions` becomes a bounded risk instead of an
unbounded one.

> **Status:** Design approved, implementation in progress. The `cc` script
> itself has not been written yet. See [Roadmap](#roadmap) for what's coming.

## What this solves

Running `claude --dangerously-skip-permissions` on a trusted developer machine
is a calculated but unbounded risk: an agent with unsupervised shell access can
touch anything the user can touch. Docker Sandboxes give each agent its own
microVM with its own filesystem, Docker daemon, and network, so a runaway
agent is contained to what you explicitly mount in.

`cc` is a thin shell wrapper around Docker's `sbx` CLI that:

- Mounts your current working directory **read-write** into the sandbox
- Mounts a configurable allow-list of host paths **read-only** for context
  (e.g. `~/workspace` for cross-project references, `~/Desktop` / `~/Downloads`
  for ad-hoc file sharing)
- Shares `~/.claude` **read-write** so your Claude Code session history persists
  across runs *and* is visible from both host `claude` and sandboxed `cc`
- Shares `~/.aws`, `~/.config/gh`, and `~/.ssh` **read-only** so credentials
  work without letting the agent overwrite them
- Forwards every non-`--cc-*` flag to `claude` inside the sandbox
- Runs preflight checks (sbx installed, Docker running, sbx authenticated,
  `~/.claude` writable) and auto-starts Docker Desktop if it isn't already up

## Prerequisites

- **Docker Desktop** (macOS / Windows / Linux)
- **sbx CLI**
  ```console
  # macOS
  brew install docker/tap/sbx

  # Windows
  winget install -h Docker.sbx

  # Linux (Ubuntu)
  curl -fsSL https://get.docker.com | sudo REPO_ONLY=1 sh
  sudo apt-get install docker-sbx
  sudo usermod -aG kvm $USER
  newgrp kvm
  ```
- One-time login:
  ```console
  sbx login
  ```
- **Claude Code** installed on the host (`cc` still needs a host binary for its
  escape hatch; see [Escape hatch](#escape-hatch))

## Install

> Not yet available. Install instructions will land here once the `cc` script
> ships. Planned form:
>
> ```console
> curl -fsSL https://raw.githubusercontent.com/patclarke/claude-docker-sandbox/main/bin/cc -o ~/bin/cc
> chmod +x ~/bin/cc
> # make sure ~/bin is on PATH
> cc --cc-doctor
> ```

## Usage

### Day-to-day

```bash
cd ~/workspace/my-project
caffeinate -dims cc --remote-control --chrome -c
```

`cc` treats anything that isn't a `--cc-*` flag as a pass-through argument
for `claude` inside the sandbox. Your existing Claude Code muscle memory works
unchanged.

### Common invocations

```bash
# Fresh session in this directory
cc

# Resume the most recent session in this directory
cc -c

# Forward arbitrary Claude Code flags
cc --remote-control --chrome -c

# Two parallel sandboxes in the same directory
cc --cc-name experiment-a -c
cc --cc-name experiment-b -c

# One-off: share a folder outside the default mount list
cc --cc-mount ~/Projects/weird-experiment:ro -c

# One-off: don't let the sandbox see ~/Downloads this session
cc --cc-no-mount ~/Downloads

# Escape hatch — run host claude directly, bypass sbx entirely
cc --cc-no-sandbox -c
# …or just run the real binary
claude -c
```

### Flags

`cc` reserves only flags with a `--cc-*` prefix. Everything else passes
through to `claude` untouched.

| Flag                      | Purpose                                                       |
|---------------------------|---------------------------------------------------------------|
| `--cc-name <label>`       | Named sandbox (for running parallel sessions in the same dir) |
| `--cc-mount <path>[:ro]`  | Add an extra mount for this invocation (repeatable)           |
| `--cc-no-mount <path>`    | Skip a config-file mount for this invocation (repeatable)    |
| `--cc-no-sandbox`         | Escape hatch — exec host `claude` directly                    |
| `--cc-rm [name]`          | Remove the sandbox for cwd (or the named one), with a prompt  |
| `--cc-ls`                 | List active sandboxes                                         |
| `--cc-dry-run`            | Print the resolved `sbx run` command for this cwd, don't exec |
| `--cc-doctor`             | Run preflight checks and show the resolved mount list         |
| `--cc-help`               | Usage                                                         |

## Mount policy

The mount plan is built on every invocation in this order:

1. **Primary mount: `$PWD`** — read-write, always. Becomes sbx's main
   workspace and the starting directory for the agent.
2. **Config file** — `~/.config/cc/mounts.conf`, one mount per line.
3. **`--cc-mount` flags** — appended.
4. **`--cc-no-mount` flags** — removed.
5. **Dedupe** — later / more specific entries win.

### Default `~/.config/cc/mounts.conf`

Written automatically the first time you run `cc`:

```
# Format:  <path>[:ro]
# No suffix = read-write. ":ro" = read-only.
# Non-existent paths are skipped silently at launch.

# Cross-project reference (read-only view of sibling repos)
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

### What each mount is for

| Path                 | Mode | Why                                                   |
|----------------------|------|-------------------------------------------------------|
| `$PWD` (launch dir)  | RW   | The actual work happens here                          |
| `~/workspace`        | RO   | Cross-project context; writes only via launch dir     |
| `~/Desktop`          | RO   | Share a file with the agent without moving it         |
| `~/Downloads`        | RO   | Same, for downloaded artifacts                        |
| `~/.claude`          | RW   | Session persistence; host ↔ sandbox visibility        |
| `~/.aws`             | RO   | Credentials available to code running in the sandbox  |
| `~/.config/gh`       | RO   | `gh` CLI auth                                         |
| `~/.ssh`             | RO   | git over ssh                                          |

### Customizing

Permanent changes: edit `~/.config/cc/mounts.conf`. One line per mount,
`#` for comments, `~` expansion supported, `:ro` suffix for read-only.
Non-existent paths are skipped silently.

```bash
# Add a permanent mount
echo '~/Notes:ro' >> ~/.config/cc/mounts.conf

# Remove a permanent mount — just delete or comment out the line
```

One-off changes: use `--cc-mount` or `--cc-no-mount` on a single invocation.

## Session persistence

Because `~/.claude` is a **live bind mount** (not a copy), any session files
written from inside the sandbox land in your real `~/.claude/projects/…`
directory on the host. Inside the sandbox, `cwd` resolves to the same absolute
host path (`sbx` preserves absolute paths), so `claude -c` finds the same
sessions whether you're running it on the host or through `cc`.

Three properties fall out of this:

1. Conversations **survive** `sbx rm`, OS reboots, or swapping sandbox images
2. A session started with host `claude` is resumable with `cc -c`, and vice
   versa
3. Your Claude Code plugins and skills (`~/.claude/plugins/`) are visible
   inside the sandbox — plugin skills work identically in both environments

## Security model

**What the sandbox can see:** only the paths explicitly mounted. Anything else
on your host filesystem is invisible.

**What the sandbox can modify:** only the `$PWD` you launched from and
`~/.claude`. Everything else in the default mount list is read-only, so a
runaway agent cannot rewrite your credentials, overwrite sibling projects, or
touch your Desktop files.

**What isolates the sandbox from your host:** microVM (hypervisor-level)
isolation via Docker Sandboxes. Each sandbox has its own Linux kernel,
filesystem, Docker daemon, and network namespace. Outbound traffic routes
through an HTTP/HTTPS proxy on your host for credential injection and network
policy.

**What `--dangerously-skip-permissions` buys you** inside this model: the
ability to run unsupervised agents that install packages, run `git` commands,
and execute shell tools without a per-command prompt, while the blast radius
stays bounded by the mount list. It's still a calculated risk — read-only
mounts are exfiltration surfaces, and anything in `$PWD` or `~/.claude` is
writable — but you're now trading "anything on my Mac" for "anything in these
specific directories."

## Preflight checks

`cc` runs the following on every invocation before planning or exec:

1. `sbx` is installed (`command -v sbx`)
2. Docker Desktop is running (`docker info`) — **auto-starts** with a 30 s
   timeout if not
3. `sbx` is authenticated (`sbx ls` probe)
4. `~/.claude` is writable
5. Optional mount paths exist (missing ones are WARN, not FAIL)
6. Host `claude` binary exists (only when `--cc-no-sandbox` is in effect)

Short-circuit: `--cc-no-sandbox` skips checks 1–5 entirely. The whole point of
the escape hatch is "sbx/docker are broken, I need to work anyway."

Run `cc --cc-doctor` anytime to see the full status without launching a
sandbox.

## Escape hatch

If sbx, Docker Desktop, or `cc` itself ever breaks, **`claude` is always still
on your PATH unmodified**. `cc` does not alias or shadow it. Two ways to bail:

```bash
# Run host claude through the cc wrapper (skips all sandbox logic)
cc --cc-no-sandbox -c

# Or just run the real binary directly
claude -c
```

## Roadmap

- [x] Design locked in
- [x] Repo bootstrapped with README + CLAUDE.md
- [ ] `bin/cc` script — parse, plan, preflight, exec phases
- [ ] First-run verification of the three unknowns: sbx arg-passing syntax,
      nested-mount handling, `~/.claude` cross-visibility
- [ ] `cc --cc-doctor` output formatting
- [ ] Manual validation matrix walked through
- [ ] Install instructions + `brew` / `curl` one-liner

## License

[MIT](LICENSE) — Copyright (c) 2026 Pat Clarke
